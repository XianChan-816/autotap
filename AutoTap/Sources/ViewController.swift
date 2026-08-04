//
//  ViewController.swift
//  AutoTap
//
//  界面功能：
//  - X / Y 坐标输入（归一化 0~1，相对所选屏幕方向）
//  - 点击间隔（毫秒）输入
//  - 屏幕方向选择（竖屏 / 横屏Home右 / 横屏Home左）
//  - 触摸取点：点击画布直接填入坐标并显示标记
//  - 长按"开始点击"按钮触发，松手停止；连续模式锁死到按音量键或回 App 停止
//

import UIKit

final class ViewController: UIViewController {

    // MARK: - 状态
    private var points: [TapPoint] = [TapPoint(x: 0.5, y: 0.5)]
    private var currentOrientation: ScreenOrientation = .portrait
    private var continuousMode = false
    private var previewView: UIView?

    // MARK: - UI 组件
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let canvas = UIView()
    private let canvasLabel = UILabel()

    private let xField = UITextField()
    private let yField = UITextField()
    private let intervalField = UITextField()
    private let orientationControl = UISegmentedControl(items: ScreenOrientation.allCases.map { $0.title })
    private let continuousSwitch = UISwitch()
    private let statusLabel = UILabel()
    private let countLabel = UILabel()
    private let triggerButton = UIButton(type: .custom)
    private let hintLabel = UILabel()

    private let addPointButton = UIButton(type: .system)
    private let clearPointsButton = UIButton(type: .system)
    private let pointsLabel = UILabel()

    private var longPress: UILongPressGestureRecognizer!

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "AutoTap"
        setupUI()
        setupCallbacks()
        setupLongPress()
        syncUI()
        loadSavedConfig()
        // 启动即尝试连接 HID（提前暴露权限问题）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = HIDBridge.shared.connect()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreviewDot()
    }

    // MARK: - UI 搭建

    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        // ---- 取点画布 ----
        canvas.backgroundColor = UIColor.secondarySystemBackground
        canvas.layer.cornerRadius = 12
        canvas.clipsToBounds = true
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.isUserInteractionEnabled = true
        let tapOnCanvas = UITapGestureRecognizer(target: self, action: #selector(canvasTapped(_:)))
        canvas.addGestureRecognizer(tapOnCanvas)

        canvasLabel.text = "点击此处取点（显示 0~1 归一化坐标）"
        canvasLabel.textColor = .secondaryLabel
        canvasLabel.font = .systemFont(ofSize: 13)
        canvasLabel.textAlignment = .center
        canvasLabel.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(canvasLabel)

        // 预览点
        previewView = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        previewView?.backgroundColor = .systemRed
        previewView?.layer.cornerRadius = 10
        previewView?.layer.borderColor = UIColor.white.cgColor
        previewView?.layer.borderWidth = 2
        previewView?.isHidden = true
        if let previewView { canvas.addSubview(previewView) }

        // ---- 输入区 ----
        let xLabel = makeLabel("X (0~1)")
        let yLabel = makeLabel("Y (0~1)")
        let intervalLabel = makeLabel("间隔(ms)")
        configureField(xField, placeholder: "0.5")
        configureField(yField, placeholder: "0.5")
        configureField(intervalField, placeholder: "200", keyboard: .numberPad)
        xField.text = "0.5"
        yField.text = "0.5"
        intervalField.text = "200"

        let inputRow = UIStackView(arrangedSubviews: [
            makeFieldContainer(label: xLabel, field: xField),
            makeFieldContainer(label: yLabel, field: yField),
            makeFieldContainer(label: intervalLabel, field: intervalField)
        ])
        inputRow.axis = .horizontal
        inputRow.spacing = 10
        inputRow.distribution = .fillEqually

        // 方向选择
        orientationControl.selectedSegmentIndex = ScreenOrientation.portrait.rawValue
        orientationControl.translatesAutoresizingMaskIntoConstraints = false

        // 坐标点管理
        pointsLabel.text = "点击点：1"
        pointsLabel.font = .systemFont(ofSize: 14, weight: .medium)
        pointsLabel.textColor = .label
        addPointButton.setTitle("＋ 添加当前输入点", for: .normal)
        clearPointsButton.setTitle("清空点位", for: .normal)
        clearPointsButton.setTitleColor(.systemRed, for: .normal)

        let pointsRow = UIStackView(arrangedSubviews: [pointsLabel, addPointButton, clearPointsButton])
        pointsRow.axis = .horizontal
        pointsRow.spacing = 12

        // 连续模式
        let continuousLabel = makeLabel("连续模式（后台运行，音量键急停）")
        continuousLabel.font = .systemFont(ofSize: 14)
        continuousSwitch.onTintColor = .systemBlue
        let continuousRow = UIStackView(arrangedSubviews: [continuousLabel, continuousSwitch])
        continuousRow.axis = .horizontal
        continuousRow.spacing = 8
        continuousRow.alignment = .center

        // 状态
        statusLabel.text = "未运行"
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statusLabel.textColor = .systemGray
        countLabel.text = "点击次数：0"
        countLabel.textAlignment = .center
        countLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        countLabel.textColor = .secondaryLabel

        // 长按触发按钮
        triggerButton.setTitle("长按开始点击", for: .normal)
        triggerButton.setTitleColor(.white, for: .normal)
        triggerButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        triggerButton.backgroundColor = .systemGreen
        triggerButton.layer.cornerRadius = 16
        triggerButton.translatesAutoresizingMaskIntoConstraints = false
        triggerButton.heightAnchor.constraint(equalToConstant: 64).isActive = true

        hintLabel.text = "按住开始，松手停止。连续模式下松手不停止，切到目标 App 后按音量键停止。"
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabel
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center

        // ---- 组装 ----
        let stack = UIStackView(arrangedSubviews: [
            canvas,
            inputRow,
            makeSectionTitle("屏幕方向"),
            orientationControl,
            makeSectionTitle("点击点位"),
            pointsRow,
            makeSectionTitle("运行方式"),
            continuousRow,
            statusLabel,
            countLabel,
            triggerButton,
            hintLabel
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            canvas.heightAnchor.constraint(equalTo: canvas.widthAnchor, multiplier: 1.6),
            canvasLabel.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            canvasLabel.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])
    }

    private func makeLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        return l
    }

    private func makeFieldContainer(label: UILabel, field: UITextField) -> UIStackView {
        let s = UIStackView(arrangedSubviews: [label, field])
        s.axis = .vertical
        s.spacing = 4
        return s
    }

    private func configureField(_ f: UITextField, placeholder: String, keyboard: UIKeyboardType = .decimalPad) {
        f.placeholder = placeholder
        f.keyboardType = keyboard
        f.borderStyle = .roundedRect
        f.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        f.textAlignment = .center
        f.delegate = self
        f.translatesAutoresizingMaskIntoConstraints = false
        f.heightAnchor.constraint(equalToConstant: 40).isActive = true
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 14, weight: .semibold)
        l.textColor = .label
        return l
    }

    // MARK: - 交互

    private func setupLongPress() {
        longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressTriggered(_:)))
        longPress.minimumPressDuration = 0.4
        triggerButton.addGestureRecognizer(longPress)
    }

    @objc private func longPressTriggered(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            if validateAndStart() {
                UIView.animate(withDuration: 0.15) {
                    self.triggerButton.backgroundColor = .systemRed
                    self.triggerButton.setTitle( self.continuousMode ? "运行中（音量键停止）" : "运行中…按住", for: .normal)
                }
            }
        case .ended, .cancelled, .failed:
            // 连续模式下松手不停止
            if ClickerEngine.shared.state == .running && !continuousMode {
                ClickerEngine.shared.stop()
            }
            updateButtonUI()
        default:
            break
        }
    }

    @objc private func canvasTapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: canvas)
        let w = canvas.bounds.width
        let h = canvas.bounds.height
        guard w > 0, h > 0 else { return }

        let nx = CGFloat(p.x) / w
        let ny = CGFloat(p.y) / h
        xField.text = String(format: "%.3f", Double(nx))
        yField.text = String(format: "%.3f", Double(ny))
        // 替换第一个点
        if points.count == 1 {
            points[0] = TapPoint(x: nx, y: ny)
        }
        updatePreviewDot()
        updatePointsLabel()
    }

    @objc private func addPointTapped() {
        guard let (x, y) = readXY() else {
            toast("请输入合法的 X/Y（0~1）")
            return
        }
        points.append(TapPoint(x: x, y: y))
        updatePointsLabel()
        updatePreviewDot()
    }

    @objc private func clearPointsTapped() {
        points = [TapPoint(x: 0.5, y: 0.5)]
        xField.text = "0.5"
        yField.text = "0.5"
        updatePointsLabel()
        updatePreviewDot()
    }

    @objc private func orientationChanged() {
        currentOrientation = ScreenOrientation(rawValue: orientationControl.selectedSegmentIndex) ?? .portrait
        updatePreviewDot()
        saveConfig()
    }

    @objc private func continuousToggled() {
        continuousMode = continuousSwitch.isOn
        saveConfig()
        updateButtonUI()
    }

    // MARK: - 启动校验

    private func readXY() -> (CGFloat, CGFloat)? {
        guard let xs = xField.text?.trimmingCharacters(in: .whitespaces), let x = Double(xs),
              let ys = yField.text?.trimmingCharacters(in: .whitespaces), let y = Double(ys),
              x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return (CGFloat(x), CGFloat(y))
    }

    private func readInterval() -> Int {
        guard let s = intervalField.text?.trimmingCharacters(in: .whitespaces),
              let ms = Int(s) else { return 200 }
        return max(1, min(ms, 60_000))
    }

    private func validateAndStart() -> Bool {
        guard !points.isEmpty else {
            toast("请先添加点击点")
            return false
        }
        guard HIDBridge.shared.connect() else {
            toast("HID 连接失败：缺少 entitlement 或未在 TrollStore/越狱环境运行")
            return false
        }
        // 换算为原生坐标
        let native = points.map {
            ClickerEngine.nativeNormalized(x: $0.x, y: $0.y, orientation: currentOrientation)
        }
        let taps = native.map { TapPoint(x: $0.nx, y: $0.ny) }

        view.endEditing(true)
        ClickerEngine.shared.start(points: taps, intervalMs: readInterval())

        if continuousMode {
            KeepAlive.shared.startVolumeMonitor { [weak self] in
                guard let self else { return }
                if ClickerEngine.shared.state == .running {
                    ClickerEngine.shared.stop()
                    self.updateButtonUI()
                    self.toast("音量键急停")
                }
            }
        }
        return true
    }

    // MARK: - 状态同步

    private func setupCallbacks() {
        addPointButton.addTarget(self, action: #selector(addPointTapped), for: .touchUpInside)
        clearPointsButton.addTarget(self, action: #selector(clearPointsTapped), for: .touchUpInside)
        orientationControl.addTarget(self, action: #selector(orientationChanged), for: .valueChanged)
        continuousSwitch.addTarget(self, action: #selector(continuousToggled), for: .valueChanged)

        ClickerEngine.shared.callbacks.onStateChanged = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle:
                self.statusLabel.text = "未运行"
                self.statusLabel.textColor = .systemGray
            case .running:
                self.statusLabel.text = "运行中"
                self.statusLabel.textColor = .systemGreen
            }
            self.updateButtonUI()
            self.updateCount()
        }
        ClickerEngine.shared.callbacks.onTick = { [weak self] _ in
            self?.updateCount()
        }
    }

    private func updateCount() {
        countLabel.text = "点击次数：\(ClickerEngine.shared.tapCount)"
    }

    private func updateButtonUI() {
        let running = ClickerEngine.shared.state == .running
        triggerButton.backgroundColor = running ? .systemRed : .systemGreen
        triggerButton.setTitle(running ? (continuousMode ? "运行中（音量键停止）" : "运行中…按住") : "长按开始点击", for: .normal)
    }

    private func updatePreviewDot() {
        guard let previewView else { return }
        let w = canvas.bounds.width
        let h = canvas.bounds.height
        guard w > 0, h > 0 else { return }

        // 画布始终以当前方向展示，取第一个点
        guard let first = points.first else {
            previewView.isHidden = true
            return
        }
        previewView.isHidden = false
        previewView.center = CGPoint(x: first.x * w, y: first.y * h)
    }

    private func updatePointsLabel() {
        pointsLabel.text = "点击点：\(points.count)"
    }

    private func syncUI() {
        orientationControl.selectedSegmentIndex = currentOrientation.rawValue
        continuousSwitch.isOn = continuousMode
        updatePointsLabel()
        updatePreviewDot()
    }

    private func toast(_ msg: String) {
        let alert = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    // MARK: - 配置持久化（轻量 UserDefaults）

    private func saveConfig() {
        UserDefaults.standard.set(xField.text ?? "", forKey: "cfg.x")
        UserDefaults.standard.set(yField.text ?? "", forKey: "cfg.y")
        UserDefaults.standard.set(intervalField.text ?? "", forKey: "cfg.interval")
        UserDefaults.standard.set(currentOrientation.rawValue, forKey: "cfg.orientation")
        UserDefaults.standard.set(continuousMode, forKey: "cfg.continuous")
    }

    private func loadSavedConfig() {
        let d = UserDefaults.standard
        if let x = d.string(forKey: "cfg.x"), !x.isEmpty { xField.text = x }
        if let y = d.string(forKey: "cfg.y"), !y.isEmpty { yField.text = y }
        if let i = d.string(forKey: "cfg.interval"), !i.isEmpty { intervalField.text = i }
        currentOrientation = ScreenOrientation(rawValue: d.integer(forKey: "cfg.orientation")) ?? .portrait
        continuousMode = d.bool(forKey: "cfg.continuous")
        syncUI()
    }
}

// MARK: - 输入框

extension ViewController: UITextFieldDelegate {
    func textFieldDidEndEditing(_ textField: UITextField) {
        saveConfig()
        if textField == xField || textField == yField {
            if let (x, y) = readXY() {
                points[0] = TapPoint(x: x, y: y)
                updatePreviewDot()
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
