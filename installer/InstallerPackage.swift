import Foundation

enum InstallerFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(text): return text
        }
    }
}

struct SignedBuild: Sendable {
    let ipa: URL
    let bundleID: String
    let version: String
}

enum InstallerPackage {
    static func sign(
        ipa: URL, certificate: Data, profile: Data, password: String, requestedBundleID: String, directory: URL,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> SignedBuild {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = directory.appendingPathComponent("Work", isDirectory: true)
        try files.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: work) }
        let p12 = work.appendingPathComponent("identity.p12")
        let provision = work.appendingPathComponent("profile.mobileprovision")
        try certificate.write(to: p12, options: [.atomic, .completeFileProtection])
        try profile.write(to: provision, options: [.atomic, .completeFileProtection])

        var profileLength = 0
        guard let profilePointer = VGCopyProfile(provision.path, &profileLength) else {
            throw InstallerFailure.message("Не удалось прочитать профиль подписи.")
        }
        let profileData = Data(bytes: profilePointer, count: profileLength)
        VGFree(profilePointer)
        let profileInfo = try plist(profileData)
        guard let expiry = profileInfo["ExpirationDate"] as? Date, expiry > Date(),
              let entitlements = profileInfo["Entitlements"] as? [String: Any],
              let applicationID = entitlements["application-identifier"] as? String,
              let separator = applicationID.firstIndex(of: "."),
              profileInfo["ProvisionsAllDevices"] as? Bool == true ||
              ((profileInfo["ProvisionedDevices"] as? [String])?.isEmpty == false) else {
            throw InstallerFailure.message("Нужен действующий профиль для установки на устройства.")
        }

        await progress("Распаковываем VeilGram…")
        let extracted = work.appendingPathComponent("Archive", isDirectory: true)
        try files.createDirectory(at: extracted, withIntermediateDirectories: false)
        guard VGUnpackIPA(ipa.path, extracted.path) == 1 else {
            throw InstallerFailure.message("Не удалось распаковать IPA. Выбери сборку VeilGram.")
        }
        let payload = extracted.appendingPathComponent("Payload", isDirectory: true)
        let app = payload.appendingPathComponent("Telegram.app", isDirectory: true)
        let info = try plist(Data(contentsOf: app.appendingPathComponent("Info.plist")))
        guard info["CFBundleDisplayName"] as? String == "VeilGram",
              info["CFBundleExecutable"] as? String == "Telegram",
              let originalID = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleVersion"] as? String else {
            throw InstallerFailure.message("Выбранный IPA не является сборкой VeilGram.")
        }
        let profileID = String(applicationID[applicationID.index(after: separator)...])
        let preferredID = requestedBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = preferredID.isEmpty ? originalID : preferredID
        let allowed = profileID == "*" || profileID == bundleID ||
            (profileID.hasSuffix(".*") && bundleID.hasPrefix(String(profileID.dropLast())))
        guard allowed, bundleID.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#,
                                      options: .regularExpression) != nil, bundleID.count <= 155 else {
            throw InstallerFailure.message("Профиль разрешает \(profileID). Укажи подходящий Bundle ID или выбери другой профиль.")
        }
        let signedID = String(applicationID[...separator]) + bundleID
        var signingRights: [String: Any] = ["application-identifier": signedID]
        if let team = entitlements["com.apple.developer.team-identifier"] as? String {
            signingRights["com.apple.developer.team-identifier"] = team
        }
        if let debugging = entitlements["get-task-allow"] as? Bool {
            signingRights["get-task-allow"] = debugging
        }
        if let groups = entitlements["keychain-access-groups"] as? [String],
           groups.contains(where: { $0 == signedID || ($0.hasSuffix("*") && signedID.hasPrefix(String($0.dropLast()))) }) {
            signingRights["keychain-access-groups"] = [signedID]
        }
        let rights = work.appendingPathComponent("Entitlements.plist")
        let rightsData = try PropertyListSerialization.data(fromPropertyList: signingRights, format: .xml, options: 0)
        try rightsData.write(to: rights)

        await progress("Подписываем VeilGram…")
        switch VGSignApp(app.path, p12.path, provision.path, rights.path, password, bundleID) {
        case 0: break
        case 1: throw InstallerFailure.message("Проверь сертификат .p12, пароль и профиль подписи.")
        case 3: throw InstallerFailure.message("Сертификат просрочен или не указан в профиле подписи.")
        default: throw InstallerFailure.message("Не удалось подписать файлы VeilGram.")
        }

        await progress("Упаковываем подписанный IPA…")
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("Telegram").path)
        let package = work.appendingPathComponent("Package", isDirectory: true)
        try files.createDirectory(at: package, withIntermediateDirectories: false)
        try files.moveItem(at: payload, to: package.appendingPathComponent("Payload", isDirectory: true))
        let output = directory.appendingPathComponent("VeilGram-signed.ipa")
        guard VGPackIPA(package.path, output.path) == 1 else {
            throw InstallerFailure.message("Не удалось упаковать IPA. Проверь свободное место на iPhone.")
        }
        return SignedBuild(ipa: output, bundleID: bundleID, version: version)
    }

    private static func plist(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw InstallerFailure.message("Не удалось прочитать данные приложения или профиля.")
        }
        return value
    }
}
