import Foundation
import CoreImage
import UIKit
import AccountContext
import SwiftSignalKit
import TelegramCore

final class PolusDeletedArchiveScreen: UITableViewController {
    private struct Record: Hashable {
        let chat: String
        let timestamp: Int32
        let text: String
    }

    private let context: AccountContext
    private let load = MetaDisposable()
    private var records: [Record] = []
    private var request: Task<Void, Never>?
    private var account: String { String(self.context.account.peerId.id._internalGetInt64Value()) }

    init(context: AccountContext) {
        self.context = context
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit {
        self.load.dispose()
        self.request?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Удалённые сообщения"
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(self.close))
        if PolusHostedProfiles.address(account: self.account) != nil {
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Запись 24/7", style: .plain, target: self, action: #selector(self.openConnection))
        }
        self.refreshControl = UIRefreshControl()
        self.refreshControl?.addTarget(self, action: #selector(self.reloadArchive), for: .valueChanged)
        self.reloadArchive()
    }

    @objc private func reloadArchive() {
        self.request?.cancel()
        self.load.set((self.context.account.postbox.transaction { transaction in
            PolusDeletedArchive.records(transaction: transaction)
        } |> deliverOnMainQueue).start(next: { [weak self] records in
            guard let self else { return }
            let local = records.map { Record(chat: $0.chat, timestamp: $0.timestamp, text: $0.text) }
            self.records = local
            self.tableView.reloadData()
            let account = self.account
            self.request = Task { @MainActor [weak self] in
                let hosted = try? await PolusHostedProfiles.archive(account: account)
                guard let self, !Task.isCancelled else { return }
                let existing = Set(local)
                let remote = (hosted ?? []).map { Record(chat: $0.chat, timestamp: $0.timestamp, text: $0.text) }
                self.records = (local + remote.filter { !existing.contains($0) }).sorted { $0.timestamp > $1.timestamp }
                self.refreshControl?.endRefreshing()
                self.tableView.reloadData()
            }
        }))
    }

    @objc private func close() { self.dismiss(animated: true) }
    @objc private func openConnection() {
        self.navigationController?.pushViewController(PolusArchiveConnectionScreen(account: self.account), animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(1, self.records.count)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard !self.records.isEmpty else {
            cell.textLabel?.text = "Архив пока пуст"
            cell.selectionStyle = .none
            return cell
        }
        let record = self.records[indexPath.row]
        let date = Date(timeIntervalSince1970: TimeInterval(record.timestamp))
        let time = DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        cell.textLabel?.text = "\(record.chat) · \(time)"
        cell.detailTextLabel?.text = record.text
        cell.detailTextLabel?.numberOfLines = 3
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !self.records.isEmpty else { return }
        let record = self.records[indexPath.row]
        let detail = UIViewController()
        detail.title = record.chat
        let content = UITextView()
        content.font = .preferredFont(forTextStyle: .body)
        content.adjustsFontForContentSizeCategory = true
        content.isEditable = false
        content.text = record.text
        content.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        detail.view = content
        self.navigationController?.pushViewController(detail, animated: true)
    }
}

private final class PolusArchiveConnectionScreen: UIViewController {
    private let account: String
    private let label = UILabel()
    private let image = UIImageView()
    private let action = UIButton(type: .system)
    private var state = "disconnected"
    private var poll: Task<Void, Never>?
    private var busy = false

    init(account: String) {
        self.account = account
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Запись 24/7"
        self.view.backgroundColor = .systemBackground
        self.label.numberOfLines = 0
        self.label.textAlignment = .center
        self.image.contentMode = .scaleAspectFit
        self.image.heightAnchor.constraint(equalToConstant: 210).isActive = true
        self.action.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [self.label, self.image, self.action])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(stack)
        let margins = self.view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 20)
        ])
        self.show(state: "disconnected", qr: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.poll?.cancel()
        self.poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.poll?.cancel()
    }

    private func refresh() async {
        guard !self.busy else { return }
        if let result = try? await PolusHostedProfiles.archiveConnection(account: self.account), !Task.isCancelled, !self.busy {
            self.show(state: result.state, qr: result.qr)
        }
    }

    private func show(state: String, qr: String?) {
        self.state = state
        self.image.isHidden = true
        self.image.image = nil
        switch state {
        case "qr":
            self.label.text = "Открой Telegram → Настройки → Устройства → Подключить устройство и отсканируй этот QR с другого экрана."
            if let qr, let filter = CIFilter(name: "CIQRCodeGenerator") {
                filter.setValue(Data(qr.utf8), forKey: "inputMessage")
                if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) {
                    self.image.image = UIImage(ciImage: output)
                    self.image.isHidden = false
                }
            }
            self.action.setTitle("Отменить", for: .normal)
        case "pairing":
            self.label.text = "Сервер запрашивает QR у Telegram."
            self.action.setTitle("Отменить", for: .normal)
        case "password":
            self.label.text = "Telegram просит пароль двухэтапной проверки. Сервер передаст его Telegram для входа."
            self.action.setTitle("Ввести пароль", for: .normal)
        case "connected":
            self.label.text = "Сервер подключён к Telegram и сохраняет новые входящие сообщения для архива."
            self.action.setTitle("Отключить запись", for: .normal)
        default:
            self.label.text = "При подключении на сервере появится отдельный сеанс Telegram с доступом к чатам аккаунта. Сервер сохраняет текст новых входящих сообщений, чтобы показывать его после удаления. Подключай только сервер, которому доверяешь."
            self.action.setTitle("Подключить запись", for: .normal)
        }
    }

    @objc private func pressed() {
        guard !self.busy else { return }
        if self.state == "password" {
            let alert = UIAlertController(title: "Двухэтапная проверка", message: nil, preferredStyle: .alert)
            alert.addTextField { $0.isSecureTextEntry = true }
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            alert.addAction(UIAlertAction(title: "Войти", style: .default) { [weak self, weak alert] _ in
                guard let password = alert?.textFields?.first?.text, !password.isEmpty else { return }
                self?.change(password: password)
            })
            self.present(alert, animated: true)
        } else {
            self.change(method: self.state == "disconnected" ? "POST" : "DELETE")
        }
    }

    private func change(method: String = "GET", password: String? = nil) {
        self.busy = true
        self.action.isEnabled = false
        Task { @MainActor in
            defer {
                self.busy = false
                self.action.isEnabled = true
            }
            do {
                let result = try await PolusHostedProfiles.archiveConnection(account: self.account, method: method, password: password)
                self.show(state: result.state, qr: result.qr)
            } catch {
                let alert = UIAlertController(title: "Запись 24/7", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "ОК", style: .default))
                self.present(alert, animated: true)
            }
        }
    }
}
