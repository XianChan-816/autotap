//
//  ClickCircleView.swift
//  AutoTap
//
//  可交互点击圆圈：
//  - 拖动 → 调整点击位置（同步归一化坐标）
//  - 捏合 / 滑块 → 调节圆圈大小（仅视觉辅助，点击点为圆心）
//  - 长按 → 触发点击；松开 → 停止（连续模式下由音量键停止）
//

import UIKit

final class ClickCircleView: UIView {

    /// 归一化位置 (0~1)，圆心即点击位置
    private(set) var normalizedX: CGFloat = 0.5
    private(set) var normalizedY: CGFloat = 0.5

    /// 视觉直径（pt）
    var diameter: CGFloat = 56 {
        didSet { updateAppearance() }
    }

    /// 触发（点击中）状态：高亮为红色
    var isActive = false {
        didSet { updateAppearance() }
    }

    // 回调
    var onPositionChanged: ((CGFloat, CGFloat) -> Void)?     // 拖动：归一化 x, y
    var onLongPressBegan: (() -> Void)?
    var onLongPressEnded: (() -> Void)?
    var onPinchChanged: ((CGFloat) -> Void)?                // 新直径

    private let ring = UIView()
    private let dot = UIView()
    private var panAnchor: CGPoint = .zero

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        addSubview(ring)
        addSubview(dot)
        setupGestures()
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 手势

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        addGestureRecognizer(pan)

        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        long.minimumPressDuration = 0.4
        addGestureRecognizer(long)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        addGestureRecognizer(pinch)
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        guard let container = superview else { return }
        switch g.state {
        case .began:
            panAnchor = g.location(in: container)
        case .changed:
            let p = g.location(in: container)
            let dx = p.x - panAnchor.x
            let dy = p.y - panAnchor.y
            panAnchor = p
            var c = center
            c.x += dx
            c.y += dy
            // 限制在容器内（圆心不出界）
            let r = diameter / 2
            let minX = r, maxX = max(r, container.bounds.width - r)
            let minY = r, maxY = max(r, container.bounds.height - r)
            c.x = min(max(c.x, minX), maxX)
            c.y = min(max(c.y, minY), maxY)
            center = c
            syncNormalized(container)
        default:
            break
        }
    }

    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            onLongPressBegan?()
        case .ended, .cancelled, .failed:
            onLongPressEnded?()
        default:
            break
        }
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .changed {
            let newD = min(max(diameter * g.scale, 24), 160)
            diameter = newD
            g.scale = 1
            onPinchChanged?(newD)
        }
    }

    // MARK: - 坐标

    private func syncNormalized(_ container: UIView) {
        let w = container.bounds.width
        let h = container.bounds.height
        guard w > 0, h > 0 else { return }
        normalizedX = min(max(center.x / w, 0), 1)
        normalizedY = min(max(center.y / h, 0), 1)
        onPositionChanged?(normalizedX, normalizedY)
    }

    /// 外部按归一化坐标设置位置（容器尺寸须已确定）
    func setNormalizedPosition(x: CGFloat, y: CGFloat, in container: UIView) {
        let w = container.bounds.width
        let h = container.bounds.height
        guard w > 0, h > 0 else { return }
        normalizedX = min(max(x, 0), 1)
        normalizedY = min(max(y, 0), 1)
        center = CGPoint(x: normalizedX * w, y: normalizedY * h)
    }

    // MARK: - 外观

    private func updateAppearance() {
        let d = diameter
        bounds = CGRect(x: 0, y: 0, width: d, height: d)
        layer.cornerRadius = d / 2

        ring.frame = bounds
        ring.layer.cornerRadius = d / 2
        ring.layer.borderWidth = 2.5
        ring.layer.borderColor = (isActive ? UIColor.systemRed : UIColor.systemBlue).cgColor
        ring.backgroundColor = (isActive
            ? UIColor.systemRed
            : UIColor.systemBlue).withAlphaComponent(isActive ? 0.40 : 0.15)

        let dotSize: CGFloat = 10
        dot.frame = CGRect(x: (d - dotSize) / 2, y: (d - dotSize) / 2, width: dotSize, height: dotSize)
        dot.layer.cornerRadius = dotSize / 2
        dot.backgroundColor = isActive ? .white : .systemBlue

        // 十字准星（圆心即点击点）
        layer.sublayers?
            .filter { $0.name == "clickCircle.cross" }
            .forEach { $0.removeFromSuperlayer() }
        let cross = CAShapeLayer()
        cross.name = "clickCircle.cross"
        cross.strokeColor = (isActive ? UIColor.systemRed : UIColor.systemBlue).cgColor
        cross.lineWidth = 1
        cross.frame = bounds
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: d / 2))
        path.addLine(to: CGPoint(x: d, y: d / 2))
        path.move(to: CGPoint(x: d / 2, y: 0))
        path.addLine(to: CGPoint(x: d / 2, y: d))
        cross.path = path.cgPath
        layer.addSublayer(cross)
    }
}
