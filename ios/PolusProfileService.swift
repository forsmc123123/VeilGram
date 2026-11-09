import Foundation
import Security

struct PolusDecoration: Decodable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let colors: [String]
}

struct PolusCatalog: Decodable, Sendable {
    let banners: [PolusDecoration]
    let gifts: [PolusDecoration]
}

struct PolusProfile: Codable, Sendable {
    var banner: String?
    var gifts: [String]

    static let empty = PolusProfile(banner: nil, gifts: [])

    enum CodingKeys: String, CodingKey {
        case banner, gifts
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.banner, forKey: .banner)
        try container.encode(self.gifts, forKey: .gifts)
    }
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

    private struct LocalProfile: Codable {
        let profile: PolusProfile
        let unpublished: Bool
    }

    private enum ServiceError: LocalizedError {
        case unavailable
        case invalidCode
        case authorizationExpired
        case cannotStoreSession

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Сервис оформления сейчас недоступен. Попробуйте ещё раз."
            case .invalidCode: return "Код не подошёл. Получите новый код в боте с этого Telegram-аккаунта."
            case .authorizationExpired: return "Срок подключения истёк. Подключите профиль заново."
            case .cannotStoreSession: return "Не удалось сохранить подключение на iPhone."
            }
        }
    }

    private static let origin = URL(string: PolusBuildConfig.profileOrigin)
    static let catalog = (try? JSONDecoder().decode(PolusCatalog.self, from: Data(PolusBuildConfig.catalogJSON.utf8))) ?? PolusCatalog(banners: [], gifts: [])
    static var canSync: Bool { self.origin?.scheme == "https" }

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

    private static func request<Response: Decodable>(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil) async throws -> Response {
        guard let origin = self.origin, self.canSync else { throw ServiceError.unavailable }
        let url = path.split(separator: "/").reduce(origin) { $0.appendingPathComponent(String($1)) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        guard httpResponse.statusCode == 200, let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ServiceError.unavailable
        }
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
        if ownProfile, let local = self.localRecord(account), local.unpublished {
            return local.profile
        }
        guard self.canSync, let token = self.token(account) else {
            return ownProfile ? self.localProfile(account) : .empty
        }
        do {
            let profile: PolusProfile = try await self.request("v1/profiles/\(peer)", token: token)
            if ownProfile, self.localRecord(account)?.unpublished != true {
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
            self.saveLocal(account, profile: profile, unpublished: true)
            return profile
        }
        let body = try JSONEncoder().encode(profile)
        do {
            let saved: PolusProfile = try await self.request("v1/me", method: "PUT", token: token, body: body)
            self.saveLocal(account, profile: saved, unpublished: false)
            return saved
        } catch ServiceError.authorizationExpired {
            self.removeExpiredToken(token, account: account)
            throw ServiceError.authorizationExpired
        }
    }

    private static func removeExpiredToken(_ token: String, account: String) {
        if self.token(account) == token {
            SecItemDelete(self.tokenQuery(account) as CFDictionary)
        }
    }
}
