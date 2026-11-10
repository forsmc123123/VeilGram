import Foundation
import CryptoKit
import Security
import UIKit

@MainActor
enum PolusHostedProfiles {
    private struct Session: Codable {
        let url: URL
        let token: String
    }

    private struct Catalog: Decodable { let botUsername: String }
    private struct Access: Decodable { let token: String }
    private struct Code: Encodable { let peer: String; let code: String }
    private struct Password: Encodable { let password: String }
    struct ArchivedMessage: Decodable {
        let chat: String
        let timestamp: Int32
        let text: String
    }
    struct ArchiveConnection: Decodable {
        let state: String
        let qr: String?
    }
    private enum Failure: LocalizedError {
        case invalidAddress, invalidResponse, authentication, storage

        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "Введи HTTPS-адрес сервера VeilGram."
            case .invalidResponse: return "Сервер VeilGram не принял запрос."
            case .authentication: return "Код истёк или не подходит. Запроси новый код у бота."
            case .storage: return "Не удалось сохранить подключение в связке ключей iPhone."
            }
        }
    }

    private final class HostedTransport: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let pinnedURL = URL(string: PolusBuildConfig.hostedURL),
                  pinnedURL.host == space.host, (pinnedURL.port ?? 443) == space.port,
                  !PolusBuildConfig.hostedCertificateHash.isEmpty else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            guard let trust = space.serverTrust,
                  let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
                    .map({ String(format: "%02x", $0) }).joined() == PolusBuildConfig.hostedCertificateHash,
                  SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private static let network = URLSession(configuration: .ephemeral, delegate: HostedTransport(), delegateQueue: nil)
    private static var publications: [String: Task<Void, Error>] = [:]

    static func address(account: String) -> URL? { self.session(account: account)?.url }

    static func address(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: value), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let url = parts.url else { throw Failure.invalidAddress }
        return url
    }

    static func bot(at url: URL) async throws -> URL {
        let data = try await self.request(url: url, path: "v1/catalog")
        let bot = try JSONDecoder().decode(Catalog.self, from: data).botUsername
        guard bot.range(of: "^[A-Za-z0-9_]{5,32}$", options: .regularExpression) != nil,
              let link = URL(string: "https://t.me/\(bot)") else { throw Failure.invalidResponse }
        return link
    }

    static func connect(account: String, url: URL, code: String) async throws {
        let encoded = try JSONEncoder().encode(Code(peer: account, code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()))
        let data = try await self.request(url: url, path: "v1/session", method: "POST", body: encoded, contentType: "application/json")
        let access = try JSONDecoder().decode(Access.self, from: data)
        guard access.token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw Failure.invalidResponse
        }
        let credentials = try JSONEncoder().encode(Session(url: url, token: access.token))
        let key = self.key(account: account)
        let updated = SecItemUpdate(key as CFDictionary, [kSecValueData as String: credentials] as CFDictionary)
        if updated == errSecItemNotFound {
            var item = key
            item[kSecValueData as String] = credentials
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.storage }
        } else if updated != errSecSuccess {
            throw Failure.storage
        }
    }

    static func disconnect(account: String) {
        SecItemDelete(self.key(account: account) as CFDictionary)
    }

    static func publish(account: String) async throws {
        guard let session = self.session(account: account) else { return }
        var profile = PolusProfileService.localProfile(account)
        profile.received = PolusProfileService.showcase(account)
        let packet = try PolusProfileService.packet(profile: profile, gift: nil, account: account)
        let previous = self.publications[account]
        let task = Task {
            if let previous { _ = try? await previous.value }
            guard self.session(account: account)?.token == session.token else { return }
            _ = try await self.request(url: session.url, path: "v1/appearance/me", method: "PUT", token: session.token,
                                       body: packet, contentType: "application/octet-stream")
        }
        self.publications[account] = task
        try await task.value
    }

    static func load(account: String, peer: String) async -> PolusProfile? {
        guard let session = self.session(account: account),
              let data = try? await self.request(url: session.url, path: "v1/appearance/\(peer)", token: session.token) else { return nil }
        return PolusProfileService.readPacket(data, account: account, peer: peer)?.profile
    }

    static func archive(account: String) async throws -> [ArchivedMessage] {
        guard let session = self.session(account: account) else { return [] }
        let data = try await self.request(url: session.url, path: "v1/deleted", token: session.token)
        return try JSONDecoder().decode([ArchivedMessage].self, from: data)
    }

    static func archiveConnection(account: String, method: String = "GET", password: String? = nil) async throws -> ArchiveConnection {
        guard let session = self.session(account: account) else { throw Failure.invalidAddress }
        let data: Data
        if let password {
            data = try await self.request(url: session.url, path: "v1/deleted/password", method: "POST", token: session.token,
                                          body: JSONEncoder().encode(Password(password: password)), contentType: "application/json")
        } else {
            data = try await self.request(url: session.url, path: "v1/deleted/connection", method: method, token: session.token)
        }
        return try JSONDecoder().decode(ArchiveConnection.self, from: data)
    }

    private static func key(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "VeilGramHostedProfiles",
            kSecAttrAccount as String: account
        ]
    }

    private static func session(account: String) -> Session? {
        var query = self.key(account: account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private static func request(url: URL, path: String, method: String = "GET", token: String? = nil,
                                body: Data? = nil, contentType: String? = nil) async throws -> Data {
        var request = URLRequest(url: url.appendingPathComponent(path), timeoutInterval: 15)
        request.httpMethod = method
        request.httpBody = body
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await self.network.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.invalidResponse }
        if status == 401 { throw Failure.authentication }
        guard status == 200, data.count <= PolusProfileService.packetLimit else { throw Failure.invalidResponse }
        return data
    }
}

final class PolusHostingScreen: UITableViewController {
    private let account: String
    private let serverField = UITextField()
    private let codeField = UITextField()
    private var busy = false

    init(account: String) {
        self.account = account
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Сервер VeilGram"
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(self.close))
        self.serverField.placeholder = "https://адрес-сервера"
        self.serverField.keyboardType = .URL
        self.serverField.text = PolusHostedProfiles.address(account: self.account)?.absoluteString ?? PolusBuildConfig.hostedURL
        self.codeField.placeholder = "Код из бота"
        self.codeField.autocapitalizationType = .allCharacters
        self.codeField.textContentType = .oneTimeCode
        for field in [self.serverField, self.codeField] {
            field.autocorrectionType = .no
        }
    }

    @objc private func close() { self.dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        PolusHostedProfiles.address(account: self.account) == nil ? 4 : 2
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let url = PolusHostedProfiles.address(account: self.account) {
            return "Подключён сервер \(url.host ?? url.absoluteString)."
        }
        return "Сервер хранит баннер, цвет, статус и витрину профиля. Открой бота, отправь /code и введи полученный код."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if PolusHostedProfiles.address(account: self.account) != nil {
            cell.textLabel?.text = indexPath.row == 0 ? "Опубликовать оформление" : "Отключить сервер"
            cell.textLabel?.textColor = indexPath.row == 0 ? .systemBlue : .systemRed
        } else if indexPath.row == 0 || indexPath.row == 2 {
            let field = indexPath.row == 0 ? self.serverField : self.codeField
            cell.contentView.addSubview(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            let margins = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: margins.centerYAnchor)
            ])
            cell.selectionStyle = .none
        } else {
            cell.textLabel?.text = indexPath.row == 1 ? "Открыть бота" : "Подключить"
            cell.textLabel?.textColor = .systemBlue
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !self.busy else { return }
        if PolusHostedProfiles.address(account: self.account) != nil, indexPath.row == 1 {
            PolusHostedProfiles.disconnect(account: self.account)
            tableView.reloadData()
            return
        }
        guard PolusHostedProfiles.address(account: self.account) != nil || indexPath.row == 1 || indexPath.row == 3 else { return }
        self.busy = true
        Task { @MainActor in
            defer { self.busy = false }
            do {
                if PolusHostedProfiles.address(account: self.account) != nil {
                    try await PolusHostedProfiles.publish(account: self.account)
                    self.show("Оформление опубликовано.")
                    return
                }
                let url = try PolusHostedProfiles.address(self.serverField.text ?? "")
                if indexPath.row == 1 {
                    let link = try await PolusHostedProfiles.bot(at: url)
                    UIApplication.shared.open(link)
                } else {
                    try await PolusHostedProfiles.connect(account: self.account, url: url, code: self.codeField.text ?? "")
                    self.codeField.text = nil
                    self.tableView.reloadData()
                    try await PolusHostedProfiles.publish(account: self.account)
                    self.show("Сервер подключён, оформление опубликовано.")
                }
            } catch {
                self.show(error.localizedDescription)
            }
        }
    }

    private func show(_ message: String) {
        let alert = UIAlertController(title: "Сервер VeilGram", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ОК", style: .default))
        self.present(alert, animated: true)
    }
}
