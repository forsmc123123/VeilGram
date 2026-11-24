import Combine
import CryptoKit
import Foundation
import UIKit

@MainActor
final class InstallerModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var ipa: URL?
    @Published private(set) var ipaName: String?
    @Published private(set) var signedIPA: URL?
    @Published private(set) var certificateName: String?
    @Published private(set) var profileName: String?
    @Published private(set) var canStop = false
    @Published var status: String?

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VeilGramInstaller", isDirectory: true)
    private var certificate: Data?
    private var profile: Data?
    private var signed: SignedBuild?
    private var server: LocalInstallerServer?
    private var timer: Task<Void, Never>?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var transferred = false

    init() {
        try? FileManager.default.removeItem(at: directory)
    }

    var canSign: Bool { !busy && ipa != nil && certificate != nil && profile != nil }

    func importCredential(_ source: URL, certificate isCertificate: Bool) throws {
        guard !busy else { return }
        let expectedExtension = isCertificate ? "p12" : "mobileprovision"
        guard source.pathExtension.lowercased() == expectedExtension else {
            throw InstallerFailure.message("Выбери файл .\(expectedExtension).")
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 2 * 1024 * 1024 else {
            throw InstallerFailure.message("Файл подписи пустой или слишком большой.")
        }
        let data = try Data(contentsOf: source)
        if isCertificate {
            certificate = data
            certificateName = source.lastPathComponent
        } else {
            profile = data
            profileName = source.lastPathComponent
        }
        status = nil
    }

    func importIPA(_ source: URL) {
        guard !busy else { return }
        guard source.pathExtension.lowercased() == "ipa" else {
            status = "Выбери файл .ipa."
            return
        }
        let directory = self.directory
        run("Копируем IPA…") {
            let staged = try await Task.detached(priority: .userInitiated) {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let target = try Self.newInput(in: directory)
                do {
                    try FileManager.default.copyItem(at: source, to: target)
                    return target
                } catch {
                    try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
                    throw error
                }
            }.value
            self.useIPA(staged, name: source.lastPathComponent)
        }
    }

    func downloadRelease() {
        guard !busy else { return }
        run("Ищем последний релиз VeilGram…") {
            let asset = try await ReleaseAsset.latest()
            self.status = "Загружаем VeilGram…"
            let (temporary, response) = try await URLSession.shared.download(from: asset.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize == asset.size else {
                throw InstallerFailure.message("Не удалось скачать IPA целиком.")
            }
            self.status = "Проверяем SHA-256…"
            try await Task.detached(priority: .userInitiated) {
                let file = try FileHandle(forReadingFrom: temporary)
                defer { try? file.close() }
                var hash = SHA256()
                while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                    hash.update(data: bytes)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard "sha256:\(digest)" == asset.digest else {
                    throw InstallerFailure.message("Контрольная сумма скачанного IPA не совпала.")
                }
            }.value
            let target = try Self.newInput(in: self.directory)
            do {
                try FileManager.default.moveItem(at: temporary, to: target)
            } catch {
                try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
                throw error
            }
            self.useIPA(target, name: asset.name)
        }
    }

    func sign(password: String, bundleID: String, manifestURL: String) {
        guard canSign, let ipa, let certificate, let profile else { return }
        let work = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        run("Проверяем файлы подписи…") {
            let newBuild: SignedBuild
            do {
                newBuild = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try await InstallerPackage.sign(
                        ipa: ipa, certificate: certificate, profile: profile, password: password,
                        requestedBundleID: bundleID, directory: work
                    ) { [weak self] stage in
                        await self?.show(stage)
                    }
                }.value
            } catch {
                try? FileManager.default.removeItem(at: work)
                throw error
            }
            self.clearSigned()
            self.signed = newBuild
            self.signedIPA = newBuild.ipa
            if manifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.status = "IPA подписан. Укажи адрес манифеста для установки или экспортируй файл."
                return
            }
            try await self.handoff(newBuild, manifestURL: manifestURL)
        }
    }

    func install(manifestURL: String) {
        guard !busy, let signed else { return }
        run("Проверяем манифест установки…") {
            try await self.handoff(signed, manifestURL: manifestURL)
        }
    }

    func stopServing() {
        guard server != nil else { return }
        finishTransfer(transferred ? "IPA передан iOS. Проверь установку на экране «Домой»." :
            "Передача завершена. Подписанный IPA можно установить повторно или экспортировать.")
    }

    private func show(_ stage: String) { status = stage }

    private func run(_ initialStatus: String, operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        status = initialStatus
        Task {
            let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }
            do { try await operation() }
            catch {
                if server != nil { finishTransfer(error.localizedDescription) }
                else { status = error.localizedDescription }
            }
            if server == nil { busy = false }
        }
    }

    private nonisolated static func newInput(in directory: URL) throws -> URL {
        let input = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        return input.appendingPathComponent("VeilGram-unsigned.ipa")
    }

    private func useIPA(_ staged: URL, name: String) {
        if let ipa { try? FileManager.default.removeItem(at: ipa.deletingLastPathComponent()) }
        clearSigned()
        ipa = staged
        ipaName = name
        status = "IPA готов к подписи."
    }

    private func clearSigned() {
        if let signed { try? FileManager.default.removeItem(at: signed.ipa.deletingLastPathComponent()) }
        signed = nil
        signedIPA = nil
    }

    private func handoff(_ build: SignedBuild, manifestURL: String) async throws {
        status = "Проверяем манифест установки…"
        guard var components = URLComponents(string: manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", components.host != nil,
              components.user == nil, components.password == nil else {
            throw InstallerFailure.message("Укажи HTTPS-адрес манифеста установки.")
        }
        let token = UUID().uuidString.lowercased()
        components.fragment = nil
        components.queryItems = [
            URLQueryItem(name: "bundle", value: build.bundleID),
            URLQueryItem(name: "version", value: build.version),
            URLQueryItem(name: "token", value: token)
        ]
        guard let manifest = components.url else {
            throw InstallerFailure.message("Неверный адрес манифеста.")
        }
        let path = "/\(token)/VeilGram.ipa"
        let (data, response) = try await URLSession.shared.data(from: manifest)
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https",
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = root["items"] as? [[String: Any]], items.count == 1,
              let metadata = items[0]["metadata"] as? [String: String],
              metadata["bundle-identifier"] == build.bundleID,
              metadata["bundle-version"] == build.version,
              let assets = items[0]["assets"] as? [[String: String]], assets.count == 1,
              assets[0]["kind"] == "software-package",
              assets[0]["url"] == "http://127.0.0.1:\(LocalInstallerServer.port)\(path)" else {
            throw InstallerFailure.message("Хостинг вернул манифест для другого файла или приложения.")
        }
        var handoff = URLComponents()
        handoff.scheme = "itms-services"
        handoff.host = ""
        // URLComponents leaves some query characters unescaped. Encode the nested URL as one value.
        handoff.percentEncodedQuery = "action=download-manifest&url=" +
            (manifest.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        guard let link = handoff.url else {
            throw InstallerFailure.message("Не удалось создать ссылку установки.")
        }

        transferred = false
        let listener = try LocalInstallerServer(file: build.ipa, path: path) { [weak self] event in
            Task { @MainActor in
                guard let self, self.server?.path == path else { return }
                switch event {
                case .download:
                    self.status = "Передаём IPA установщику iOS…"
                case .transferred:
                    self.transferred = true
                    self.status = "IPA передан iOS. Проверь установку на экране «Домой»."
                }
            }
        }
        server = listener
        try await listener.start()
        background = UIApplication.shared.beginBackgroundTask(withName: "VeilGram install") { [weak self] in
            Task { @MainActor in self?.stopServing() }
        }
        canStop = true
        status = "Подтверди установку в iOS."
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
            self?.stopServing()
        }
        guard await UIApplication.shared.open(link) else {
            throw InstallerFailure.message("iOS не открыла установку. Подписанный IPA доступен для экспорта.")
        }
    }

    private func finishTransfer(_ message: String) {
        server?.stop()
        server = nil
        timer?.cancel()
        timer = nil
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        canStop = false
        busy = false
        status = message
    }
}

private struct ReleaseAsset: Decodable, Sendable {
    private struct Release: Decodable { let assets: [ReleaseAsset] }

    let name: String
    let size: Int
    let digest: String?
    let url: URL

    private enum CodingKeys: String, CodingKey {
        case name, size, digest
        case url = "browser_download_url"
    }

    static func latest() async throws -> ReleaseAsset {
        let repository = Bundle.main.object(forInfoDictionaryKey: "VeilGramReleaseRepository") as? String
            ?? "forsmc123123/VeilGram"
        guard let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw InstallerFailure.message("Неверный адрес репозитория релизов.")
        }
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let asset = release.assets.first(where: { $0.name == "VeilGram-unsigned.ipa" }),
              asset.size > 0, asset.size <= 2_000_000_000, asset.url.scheme == "https",
              asset.url.host == "github.com",
              asset.url.path.lowercased().hasPrefix("/\(repository.lowercased())/releases/download/"),
              asset.digest?.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw InstallerFailure.message("В последнем публичном релизе нет проверяемого IPA. Можно выбрать IPA из Файлов.")
        }
        return asset
    }
}
