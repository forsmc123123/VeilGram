import Foundation
import Security

struct StoredSigning: Codable {
    var certificate: Data
    var certificateName: String
    var profile: Data
    var profileName: String
    var password: String
}

enum SigningVault {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "org.polus.veilgram.installer",
        kSecAttrAccount as String: "on-device-signing"
    ]

    static func load() -> StoredSigning? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? PropertyListDecoder().decode(StoredSigning.self, from: data)
    }

    static func save(_ value: StoredSigning) throws {
        let data = try PropertyListEncoder().encode(value)
        let fields = [kSecValueData as String: data]
        var status = SecItemUpdate(item as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            var record = item
            record[kSecValueData as String] = data
            record[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(record as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw InstallerFailure.message("Не удалось сохранить данные в Связке ключей (\(status)).")
        }
    }

    static func remove() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw InstallerFailure.message("Не удалось удалить данные из Связки ключей (\(status)).")
        }
    }
}
