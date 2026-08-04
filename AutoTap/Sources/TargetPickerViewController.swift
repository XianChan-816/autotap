//
//  TargetPickerViewController.swift
//  AutoTap
//
//  目标 App 选择界面：列出已安装 App，多选连点目标。
//  选中项保存到共享配置 FloatingTap.plist 的 Targets 列表，
//  FloatingTap tweak 检测前台 App 命中列表时才显示悬浮球。
//

import UIKit

final class TargetPickerViewController: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let statusLabel = UILabel()
    private var allApps: [TargetAppManager.AppInfo] = []
    private var selectedIDs: Set<String> = []
    private let searchController = UISearchController(searchResultsController: nil)
    private var filteredApps: [TargetAppManager.AppInfo] = []

    private var shownApps: [TargetAppManager.AppInfo] {
        let isSearching = searchController.isActive && (searchController.searchBar.text?.isEmpty == false)
        return isSearching ? filteredApps : allApps
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "选择目标 App"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(doneTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "刷新",
                                                           style: .plain,
                                                           target: self,
                                                           action: #selector(refreshTapped))
        view.backgroundColor = .systemBackground

        selectedIDs = Set(TargetAppManager.loadTargets())

        // 搜索
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        view.addSubview(tableView)

        // 顶部诊断状态条（排查 tweak 是否加载 / 枚举是否成功）
        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.backgroundColor = UIColor(white: 0.95, alpha: 1)
        statusLabel.text = "诊断中…"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        loadApps()
    }

    private func loadApps() {
        TargetAppManager.invalidateCache()  // 每次打开都重新读取（tweak 清单可能已更新）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diag = TargetAppManager.tweakDiagnostic()
            let apps = TargetAppManager.installedApps()
            DispatchQueue.main.async {
                self?.allApps = apps
                self?.statusLabel.text = diag.message
                self?.tableView.reloadData()
                if apps.isEmpty {
                    self?.toast(diag.message)
                }
            }
        }
    }

    @objc private func refreshTapped() {
        loadApps()
    }

    private func toast(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        if let pop = alert.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { alert.dismiss(animated: true) }
    }

    @objc private func doneTapped() {
        TargetAppManager.saveTargets(Array(selectedIDs).sorted())
        dismiss(animated: true) {
            NotificationCenter.default.post(name: .targetsDidChange, object: nil)
        }
    }
}

// MARK: - Table

extension TargetPickerViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        shownApps.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let info = shownApps[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = info.name
        config.secondaryText = info.bundleID
        cell.contentConfiguration = config
        cell.accessoryType = selectedIDs.contains(info.bundleID) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let info = shownApps[indexPath.row]
        if selectedIDs.contains(info.bundleID) {
            selectedIDs.remove(info.bundleID)
        } else {
            selectedIDs.insert(info.bundleID)
        }
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}

// MARK: - 搜索

extension TargetPickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        guard let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else {
            filteredApps = []
            tableView.reloadData()
            return
        }
        filteredApps = allApps.filter {
            $0.name.localizedCaseInsensitiveContains(text) ||
            $0.bundleID.localizedCaseInsensitiveContains(text)
        }
        tableView.reloadData()
    }
}

extension Notification.Name {
    static let targetsDidChange = Notification.Name("AutoTap.targetsDidChange")
}
