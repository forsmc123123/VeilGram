import Foundation
import Security
import CryptoKit

struct PolusDecoration: Decodable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let colors: [String]
}

struct PolusCatalog: Decodable, Sendable {
    let banners: [PolusDecoration]
}

struct PolusAvatarMedia: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case photo, gif, video

        var contentType: String {
            switch self {
            case .photo: return "image/jpeg"
            case .gif: return "image/gif"
            case .video: return "video/mp4"
            }
        }
    }

    let id: String
    let kind: Kind
}

struct PolusProfile: Codable, Equatable, Sendable {
    var banner: String?
    var media: PolusAvatarMedia?
    var color: String?
    var status: String?
    var member: Bool?
    var received: [String]?
    var balance: Int?

    static let empty = PolusProfile()
}

enum PolusProfileService {
    private struct RemoteCatalog: Decodable {
        let botUsername: String
    }

    private struct Login: Encodable {
        let peer: String
        let code: String
    }

    private struct Session: Decodable {
        let token: String
    }

    private struct GiftOrder: Encodable {
        let recipient: String
        let item: String
        let nonce: String
    }

    private struct GiftReceipt: Decodable {
        let balance: Int
    }

    private struct ErrorBody: Decodable {
        let error: String
    }

    private struct LocalProfile: Codable {
        let profile: PolusProfile
        let unpublished: Bool
    }

    private enum ServiceError: LocalizedError {
        case unavailable
        case invalidCode
        case authorizationExpired
        case cannotStoreSession
        case invalidMedia
        case insufficientStars
        case recipientNotLinked

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Сервис оформления сейчас недоступен. Попробуйте ещё раз."
            case .invalidCode: return "Код не подошёл. Получите новый код в боте с этого Telegram-аккаунта."
            case .authorizationExpired: return "Срок подключения истёк. Подключите профиль заново."
            case .cannotStoreSession: return "Не удалось сохранить подключение на iPhone."
            case .invalidMedia: return "Не удалось открыть рамку. Выберите фото, GIF или видео размером до 8 МБ."
            case .insufficientStars: return "Не хватает визуальных звёзд VeilGram."
            case .recipientNotLinked: return "Получатель ещё не подключил профиль VeilGram."
            }
        }
    }

    private static let originKey = "polus.profile.origin"
    private static var origin: URL? { URL(string: self.originText).flatMap { $0.scheme == "https" ? $0 : nil } }
    static var originText: String { UserDefaults.standard.string(forKey: self.originKey) ?? PolusBuildConfig.profileOrigin }
    static let catalog = (try? JSONDecoder().decode(PolusCatalog.self, from: Data(PolusBuildConfig.catalogJSON.utf8))) ?? PolusCatalog(banners: [])
    static var canSync: Bool { self.origin != nil }
    static let mediaLimit = 8 * 1024 * 1024

    @MainActor
    static func configureOrigin(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: self.originKey)
            return true
        }
        guard let parts = URLComponents(string: trimmed), parts.scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return false }
        UserDefaults.standard.set(trimmed, forKey: self.originKey)
        return true
    }

    private static func localKey(_ account: String) -> String { "polus.profile.\(account)" }

    private static func localRecord(_ account: String) -> LocalProfile? {
        guard let data = UserDefaults.standard.data(forKey: self.localKey(account)) else { return nil }
        return try? JSONDecoder().decode(LocalProfile.self, from: data)
    }

    static func localProfile(_ account: String) -> PolusProfile {
        self.localRecord(account)?.profile ?? .empty
    }

    private static func saveLocal(_ account: String, profile: PolusProfile, unpublished: Bool) {
        let data = try? JSONEncoder().encode(LocalProfile(profile: profile, unpublished: unpublished))
        UserDefaults.standard.set(data, forKey: self.localKey(account))
    }

    private static func tokenQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "polus.profiles.\(self.origin?.absoluteString ?? "")",
         kSecAttrAccount as String: account]
    }

    private static func token(_ account: String) -> String? {
        var query = self.tokenQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func isLinked(_ account: String) -> Bool {
        self.canSync && self.token(account) != nil
    }

    private static func bytes(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        guard let origin = self.origin, self.canSync else { throw ServiceError.unavailable }
        let url = path.split(separator: "/").reduce(origin) { $0.appendingPathComponent(String($1)) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.unavailable
        }
        guard let httpResponse = response as? HTTPURLResponse else { throw ServiceError.unavailable }
        if httpResponse.statusCode == 401 {
            throw token == nil ? ServiceError.invalidCode : ServiceError.authorizationExpired
        }
        if httpResponse.statusCode == 409, let error = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            if error.error == "insufficient_stars" { throw ServiceError.insufficientStars }
            if error.error == "recipient_not_linked" { throw ServiceError.recipientNotLinked }
        }
        guard httpResponse.statusCode == 200 else {
            throw ServiceError.unavailable
        }
        return data
    }

    private static func request<Response: Decodable>(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil, contentType: String = "application/json") async throws -> Response {
        let data = try await self.bytes(path, method: method, token: token, body: body, contentType: contentType)
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw ServiceError.unavailable }
        return decoded
    }

    static func botURL() async throws -> URL {
        let result: RemoteCatalog = try await self.request("v1/catalog")
        guard result.botUsername.range(of: "^[A-Za-z0-9_]{5,32}$", options: .regularExpression) != nil,
              let url = URL(string: "https://t.me/\(result.botUsername)") else { throw ServiceError.unavailable }
        return url
    }

    @MainActor
    static func link(_ account: String, code: String) async throws {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedCode.range(of: "^[A-F0-9]{8}$", options: .regularExpression) != nil else { throw ServiceError.invalidCode }
        let body = try JSONEncoder().encode(Login(peer: account, code: normalizedCode))
        let result: Session = try await self.request("v1/session", method: "POST", body: body)
        let query = self.tokenQuery(account)
        let attributes = [kSecValueData as String: Data(result.token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(result.token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ServiceError.cannotStoreSession }
        } else if status != errSecSuccess {
            throw ServiceError.cannotStoreSession
        }
    }

    @MainActor
    static func load(account: String, peer: String) async throws -> PolusProfile {
        let ownProfile = account == peer
        guard self.canSync, let token = self.token(account) else {
            return ownProfile ? self.localProfile(account) : .empty
        }
        do {
            var profile: PolusProfile = try await self.request("v2/profiles/\(peer)", token: token)
            if ownProfile, let local = self.localRecord(account), local.unpublished {
                profile.banner = local.profile.banner
                profile.media = local.profile.media
                profile.color = local.profile.color
                profile.status = local.profile.status
            } else if ownProfile {
                self.saveLocal(account, profile: profile, unpublished: false)
            }
            return profile
        } catch ServiceError.authorizationExpired {
            self.removeExpiredToken(token, account: account)
            throw ServiceError.authorizationExpired
        }
    }

    @MainActor
    static func save(account: String, profile: PolusProfile) async throws -> PolusProfile {
        guard self.canSync, let token = self.token(account) else {
            var local = profile
            local.member = nil
            local.balance = nil
            local.received = nil
            self.saveLocal(account, profile: local, unpublished: true)
            return local
        }
        do {
            if let media = profile.media {
                let data = try await self.mediaData(account: account, peer: account, media: media)
                let uploaded: PolusAvatarMedia = try await self.request("v2/me/media/\(media.kind.rawValue)", method: "POST", token: token, body: data, contentType: media.kind.contentType)
                guard uploaded == media else { throw ServiceError.invalidMedia }
            }
            let body = try JSONEncoder().encode(PolusProfile(banner: profile.banner, media: profile.media, color: profile.color, status: profile.status))
            let saved: PolusProfile = try await self.request("v2/me", method: "PUT", token: token, body: body)
            self.saveLocal(account, profile: saved, unpublished: false)
            return saved
        } catch ServiceError.authorizationExpired {
            self.removeExpiredToken(token, account: account)
            throw ServiceError.authorizationExpired
        }
    }

    @MainActor
    static func sendGift(account: String, recipient: String, item: String, nonce: UUID) async throws -> Int {
        guard let token = self.token(account) else { throw ServiceError.authorizationExpired }
        do {
            let body = try JSONEncoder().encode(GiftOrder(recipient: recipient, item: item, nonce: nonce.uuidString.lowercased()))
            let receipt: GiftReceipt = try await self.request("v2/gifts", method: "POST", token: token, body: body)
            return receipt.balance
        } catch ServiceError.authorizationExpired {
            self.removeExpiredToken(token, account: account)
            throw ServiceError.authorizationExpired
        }
    }

    private static func mediaId(_ data: Data, kind: PolusAvatarMedia.Kind) -> String {
        var hash = SHA256()
        hash.update(data: Data(kind.rawValue.utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func mediaPath(_ account: String, media: PolusAvatarMedia) throws -> URL {
        guard account.range(of: "^[1-9][0-9]{0,15}$", options: .regularExpression) != nil,
              media.id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ServiceError.invalidMedia }
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VeilGramAvatar", isDirectory: true).appendingPathComponent(account, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(media.id)
    }

    static func storeMedia(_ data: Data, kind: PolusAvatarMedia.Kind, account: String) throws -> PolusAvatarMedia {
        guard !data.isEmpty, data.count <= self.mediaLimit else { throw ServiceError.invalidMedia }
        let media = PolusAvatarMedia(id: self.mediaId(data, kind: kind), kind: kind)
        try data.write(to: self.mediaPath(account, media: media), options: .atomic)
        return media
    }

    static func mediaData(account: String, peer: String, media: PolusAvatarMedia) async throws -> Data {
        if account == peer, let data = try? Data(contentsOf: self.mediaPath(account, media: media)) {
            return data
        }
        guard let token = self.token(account) else { throw ServiceError.authorizationExpired }
        let data = try await self.bytes("v2/media/\(peer)/\(media.id)", token: token)
        guard data.count <= self.mediaLimit, self.mediaId(data, kind: media.kind) == media.id else { throw ServiceError.invalidMedia }
        if account == peer {
            try data.write(to: self.mediaPath(account, media: media), options: .atomic)
        }
        return data
    }

    private static func removeExpiredToken(_ token: String, account: String) {
        if self.token(account) == token {
            SecItemDelete(self.tokenQuery(account) as CFDictionary)
        }
    }
}

public enum VeilGramChatDecoration {
    @MainActor
    public static func load(account: String, peer: String) async -> (member: Bool, color: UInt32?) {
        guard let profile = try? await PolusProfileService.load(account: account, peer: peer) else { return (false, nil) }
        return (profile.member == true, profile.color.flatMap { UInt32($0, radix: 16) })
    }
}
