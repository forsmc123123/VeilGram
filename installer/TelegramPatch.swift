import CryptoKit
import Foundation

enum TelegramPatch {
    private struct Manifest: Decodable {
        let format: Int
        let baseSHA256: String
        let remove: [String]
    }

    struct Asset: Decodable, Sendable {
        let path: String
        let size: Int
        let sha256: String
    }

    struct Catalog: Decodable {
        let base: Asset
        let patch: Asset
    }

    static func apply(base: URL, patch: URL, output: URL) throws {
        let manager = FileManager.default
        let work = output.deletingLastPathComponent().appendingPathComponent("PatchWork", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: work) }
        let original = work.appendingPathComponent("Base", isDirectory: true)
        let overlay = work.appendingPathComponent("Overlay", isDirectory: true)
        guard VGUnpackIPA(patch.path, overlay.path) == 1 else {
            throw InstallerFailure.message("Не удалось распаковать пакет мода.")
        }
        let changes = app(in: overlay)
        let descriptor = changes.appendingPathComponent(".veilgram-patch.json")
        guard let size = try descriptor.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000 else {
            throw InstallerFailure.message("Неверный размер описания пакета.")
        }
        let data = try Data(contentsOf: descriptor)
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.format == 1, manifest.remove.allSatisfy(safe), try sha256(base) == manifest.baseSHA256 else {
            throw InstallerFailure.message("Пакет VeilGram не соответствует этому IPA Telegram.")
        }
        try manager.removeItem(at: descriptor)
        guard VGUnpackIPA(base.path, original.path) == 1 else {
            throw InstallerFailure.message("Не удалось распаковать базовый IPA Telegram.")
        }
        let telegram = app(in: original)
        let before = try info(telegram)
        guard before["CFBundleIdentifier"] as? String == "ph.telegra.Telegraph",
              before["CFBundleExecutable"] as? String == "Telegram" else {
            throw InstallerFailure.message("Выбери базовый IPA Telegram.")
        }
        for name in manifest.remove {
            let item = telegram.appendingPathComponent(name)
            if manager.fileExists(atPath: item.path) { try manager.removeItem(at: item) }
        }
        try merge(changes, into: telegram, manager: manager)
        let after = try info(telegram)
        guard after["CFBundleDisplayName"] as? String == "VeilGram",
              after["CFBundleExecutable"] as? String == "Telegram" else {
            throw InstallerFailure.message("Пакет не преобразовал Telegram в VeilGram.")
        }
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: telegram.appendingPathComponent("Telegram").path)
        let packed = work.appendingPathComponent("Package", isDirectory: true)
        try manager.createDirectory(at: packed, withIntermediateDirectories: false)
        try manager.moveItem(at: telegram.deletingLastPathComponent(),
                             to: packed.appendingPathComponent("Payload", isDirectory: true))
        guard VGPackIPA(packed.path, output.path) == 1 else {
            throw InstallerFailure.message("Не удалось собрать IPA VeilGram. Проверь свободное место.")
        }
    }

    static func endpoint(_ configured: String, path: String) throws -> URL {
        guard var origin = URLComponents(string: configured.trimmingCharacters(in: .whitespacesAndNewlines)),
              origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil,
              ["", "/", "/install/manifest.plist"].contains(origin.path) else {
            throw InstallerFailure.message("Укажи HTTPS-адрес сервера патчера.")
        }
        origin.path = path
        guard let url = origin.url else { throw InstallerFailure.message("Неверный адрес сервера патчера.") }
        return url
    }

    static func verify(_ file: URL, asset: Asset) throws {
        guard asset.size > 0, asset.size <= 2_000_000_000,
              try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == asset.size,
              try sha256(file) == asset.sha256 else {
            throw InstallerFailure.message("Размер или SHA-256 скачанного файла не совпадает.")
        }
    }

    private static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { digest.update(data: block) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func safe(_ path: String) -> Bool {
        !path.contains(":") && !path.contains("\\") && !path.unicodeScalars.contains { $0.value < 32 } &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func app(in root: URL) -> URL {
        root.appendingPathComponent("Payload", isDirectory: true).appendingPathComponent("Telegram.app", isDirectory: true)
    }

    private static func info(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw InstallerFailure.message("Не удалось прочитать Info.plist приложения.")
        }
        return info
    }

    private static func merge(_ source: URL, into destination: URL, manager: FileManager) throws {
        for item in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let folder = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: folder)
            var targetIsDirectory: ObjCBool = false
            let exists = manager.fileExists(atPath: target.path, isDirectory: &targetIsDirectory)
            if exists && (!folder || !targetIsDirectory.boolValue) { try manager.removeItem(at: target) }
            if folder {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                try merge(item, into: target, manager: manager)
            } else {
                try manager.moveItem(at: item, to: target)
            }
        }
    }
}
