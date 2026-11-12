import Foundation
import CryptoKit
import Security
import UIKit

@MainActor
enum PolusHostedProfiles {
    private struct Session: Codable, Hashable {
        let url: URL
        let token: String
    }

    private struct ProfileRequest: Hashable {
        let session: Session
        let account: String
        let peer: String
    }

    private struct ServerError: Decodable { let error: String }
    private struct Password: Encodable { let password: String }
    private struct RegistrationPeer: Encodable { let peer: String }
    private struct RegistrationPoll: Encodable { let poll: String }
    private struct RegistrationChallenge: Decodable {
        let username: String
        let recipient: String
        let proof: String
        let poll: String
    }
    private struct RegistrationResult: Decodable {
        let pending: Bool?
        let token: String?
        let created: Bool?
    }
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
        case invalidAddress, invalidResponse, authentication, missingEndpoint

        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "Сервер VeilGram отключён."
            case .invalidResponse, .missingEndpoint: return "Сервер VeilGram не принял запрос."
            case .authentication: return "Подключение к серверу VeilGram истекло."
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
    private static var profileDownloads: [ProfileRequest: Task<PolusProfile?, Never>] = [:]
    private static var registrationAttempts: [String: TimeInterval] = [:]

    static func address(account: String) -> URL? { self.session(account: account)?.url }

    static func disconnect(account: String) {
        UserDefaults.standard.set(true, forKey: self.registrationPreference(account: account))
        SecItemDelete(self.key(account: account) as CFDictionary)
    }

    private static func registrationPreference(account: String) -> String {
        "veilgram.hostRegistrationDisabled.\(account)"
    }

    static func register(account: String, send: (String, String, String) async -> Bool) async {
        let now = ProcessInfo.processInfo.systemUptime
        guard let url = URL(string: PolusBuildConfig.hostedURL), url.scheme == "https",
              self.session(account: account) == nil,
              !UserDefaults.standard.bool(forKey: self.registrationPreference(account: account)),
              self.registrationAttempts[account].map({ now - $0 >= 120 }) ?? true else { return }
        self.registrationAttempts[account] = now
        do {
            let start = try await self.registrationRequest(url: url, route: "start", value: RegistrationPeer(peer: account))
            let challenge = try JSONDecoder().decode(RegistrationChallenge.self, from: start)
            guard challenge.recipient != account,
                  challenge.recipient.range(of: "^[1-9][0-9]{0,15}$", options: .regularExpression) != nil,
                  challenge.username.range(of: "^[A-Za-z0-9_]{5,32}$", options: .regularExpression) != nil,
                  challenge.proof.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
                  challenge.poll.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
                  !Task.isCancelled,
                  await send(challenge.username, challenge.recipient, "VEILGRAM-REGISTER " + challenge.proof) else { return }
            for attempt in 0..<20 {
                if attempt > 0 { try await Task.sleep(nanoseconds: 3_000_000_000) }
                guard !Task.isCancelled else { return }
                let response = try await self.registrationRequest(url: url, route: "complete", value: RegistrationPoll(poll: challenge.poll))
                let result = try JSONDecoder().decode(RegistrationResult.self, from: response)
                if result.pending == true { continue }
                guard let token = result.token, token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
                      !Task.isCancelled, !UserDefaults.standard.bool(forKey: self.registrationPreference(account: account))
                else { return }
                var item = self.key(account: account)
                item[kSecValueData as String] = try JSONEncoder().encode(Session(url: url, token: token))
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                if SecItemAdd(item as CFDictionary, nil) == errSecSuccess, result.created == true {
                    try await self.publish(account: account)
                }
                return
            }
        } catch {
            // Retry when VeilGram next enters the foreground.
        }
    }

    private static func registrationRequest<T: Encodable>(url: URL, route: String, value: T) async throws -> Data {
        try await self.request(url: url, path: "v1/registration/\(route)", method: "POST",
                               body: JSONEncoder().encode(value), contentType: "application/json")
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
        guard let session = self.session(account: account) else { return nil }
        let key = ProfileRequest(session: session, account: account, peer: peer)
        if let download = self.profileDownloads[key] {
            let result = await download.value
            return self.session(account: account) == session ? result : nil
        }
        let download = Task<PolusProfile?, Never> {
            do {
                let data = try await self.request(url: session.url, path: "v1/appearance/\(peer)/metadata", token: session.token)
                return PolusProfileService.readHostedMetadata(data)
            } catch Failure.missingEndpoint {
                guard let data = try? await self.request(url: session.url, path: "v1/appearance/\(peer)", token: session.token) else { return nil }
                return await Task.detached { PolusProfileService.readPacket(data, account: account, peer: peer)?.profile }.value
            } catch {
                return nil
            }
        }
        self.profileDownloads[key] = download
        let result = await download.value
        self.profileDownloads[key] = nil
        return self.session(account: account) == session ? result : nil
    }

    static func needsMedia(account: String, peer: String, media: PolusAvatarMedia) -> Bool {
        guard let url = try? PolusProfileService.mediaURL(account: account, peer: peer, media: media) else { return true }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    static func fetchMedia(account: String, peer: String, media: PolusAvatarMedia) async -> Bool {
        guard let session = self.session(account: account),
              let data = try? await self.request(url: session.url, path: "v1/appearance/\(peer)/media/\(media.id)", token: session.token),
              self.session(account: account) == session else { return false }
        return await Task.detached { (try? PolusProfileService.storeHostedMedia(data, account: account, peer: peer, media: media)) != nil }.value
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
        if status == 404, (try? JSONDecoder().decode(ServerError.self, from: data).error) == "not_found" { throw Failure.missingEndpoint }
        guard status == 200, data.count <= PolusProfileService.packetLimit else { throw Failure.invalidResponse }
        return data
    }
}

final class PolusHostingScreen: UITableViewController {
    private let account: String

    init(account: String) {
        self.account = account
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Сервер VeilGram"
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(self.close))
    }

    @objc private func close() { self.dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        PolusHostedProfiles.address(account: self.account) == nil ? 0 : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let url = PolusHostedProfiles.address(account: self.account) else { return "Сервер отключён." }
        return "Оформление синхронизируется с сервером \(url.host ?? url.absoluteString)."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = "Отключить сервер"
        cell.textLabel?.textColor = .systemRed
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        PolusHostedProfiles.disconnect(account: self.account)
        self.close()
    }
}
