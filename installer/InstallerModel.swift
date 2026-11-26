import Combine
import Foundation
import UIKit

@MainActor
final class InstallerModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var ipa: URL?
    @Published private(set) var ipaName: String?
    @Published private(set) var baseName: String?
    @Published private(set) var patchName: String?
    @Published private(set) var signedIPA: URL?
    @Published private(set) var certificateName: String?
    @Published private(set) var profileName: String?
    @Published private(set) var canStop = false
    @Published private(set) var failed = false
    @Published private(set) var versions: [PatchRelease] = []
    @Published private(set) var selectedRelease = PatchRelease.latest
    @Published private(set) var loadingVersions = false
    @Published private(set) var versionsError: String?
    @Published private(set) var storedPassword: String?
    @Published var status: String?

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VeilGramInstaller", isDirectory: true)
    private var base: URL?
    private var patch: URL?
    private var certificate: Data?
    private var profile: Data?
    private var signed: SignedBuild?
    private var server: LocalInstallerServer?
    private var timer: Task<Void, Never>?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var transferred = false

    init() {
        try? FileManager.default.removeItem(at: directory)
        if let stored = SigningVault.load() {
            certificate = stored.certificate
            certificateName = stored.certificateName
            profile = stored.profile
            profileName = stored.profileName
            storedPassword = stored.password
        }
    }

    var hasSigning: Bool { certificate != nil && profile != nil }
    var hasLocalPair: Bool { base != nil && patch != nil }

    func rememberSigning(password: String) throws {
        guard let certificate, let certificateName, let profile, let profileName else { return }
        try SigningVault.save(StoredSigning(certificate: certificate, certificateName: certificateName,
                                            profile: profile, profileName: profileName, password: password))
        storedPassword = password
        status = "Данные подписи сохранены на этом iPhone."
        failed = false
    }

    func forgetSigning() throws {
        try SigningVault.remove()
        storedPassword = nil
        certificate = nil
        profile = nil
        certificateName = nil
        profileName = nil
        status = "Данные подписи удалены."
        failed = false
    }

    func report(_ error: Error) {
        status = Self.describe(error)
        failed = true
    }

    func refreshVersions(server: String) async {
        guard !loadingVersions else { return }
        loadingVersions = true
        versionsError = nil
        defer { loadingVersions = false }
        do {
            let endpoint = try TelegramPatch.endpoint(server, path: "/patcher/versions.json")
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            guard response.url == endpoint, let http = response as? HTTPURLResponse else {
                throw InstallerFailure.message("Сервер версий вернул неверный ответ.")
            }
            if http.statusCode == 404 {
                versions = [.latest]
                return
            }
            guard http.statusCode == 200, data.count <= 64000 else {
                throw InstallerFailure.message("Список версий недоступен.")
            }
            let decoded = try JSONDecoder().decode([PatchRelease].self, from: data)
            var identifiers = Set<String>()
            versions = Array(decoded.filter { $0.valid && identifiers.insert($0.id).inserted }.prefix(7))
            if versions.isEmpty { versionsError = "На сервере пока нет сборок VeilGram." }
            if let selected = versions.first(where: { $0.id == selectedRelease.id }) { selectedRelease = selected }
        } catch {
            versions = []
            versionsError = Self.describe(error)
        }
    }

    func selectRelease(_ release: PatchRelease) {
        guard !busy, release.valid else { return }
        if release.id != selectedRelease.id { clearOutput() }
        selectedRelease = release
    }

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

    func importPatchInput(_ source: URL, base isBase: Bool) {
        guard !busy else { return }
        let suffix = isBase ? "ipa" : "zip"
        guard source.pathExtension.lowercased() == suffix else {
            status = "Выбери файл .\(suffix)."
            return
        }
        let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        run("Копируем файл…") {
            try await Task.detached(priority: .userInitiated) {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
            }.value
            if isBase {
                if let base = self.base { try? FileManager.default.removeItem(at: base) }
                self.base = target
                self.baseName = source.lastPathComponent
            } else {
                if let patch = self.patch { try? FileManager.default.removeItem(at: patch) }
                self.patch = target
                self.patchName = source.lastPathComponent
            }
            self.clearOutput()
            self.status = "Файл готов."
        }
    }

    func preparePatch(server: String, download: Bool) {
        guard !busy else { return }
        run(download ? "Проверяем пару Telegram и VeilGram…" : "Встраиваем мод в Telegram…") {
            try await self.makePatch(server: server, download: download)
        }
    }

    private func makePatch(server: String, download: Bool) async throws {
        var downloaded: [URL] = []
        defer { for file in downloaded { try? FileManager.default.removeItem(at: file) } }
        let base: URL
        let patch: URL
        if download {
            let prefix = selectedRelease.prefix
            let endpoint = try TelegramPatch.endpoint(server, path: prefix + "/latest.json")
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            guard data.count <= 65536, response.url == endpoint, (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw InstallerFailure.message("Сервер пока не отдаёт эту сборку VeilGram.")
            }
            let catalog = try JSONDecoder().decode(TelegramPatch.Catalog.self, from: data)
            status = "Скачиваем Telegram…"
            base = try await fetchPatchAsset(catalog.base, filename: "Telegram.ipa", prefix: prefix, server: server)
            downloaded.append(base)
            status = "Скачиваем пакет VeilGram…"
            patch = try await fetchPatchAsset(catalog.patch, filename: "VeilGram-patch.zip", prefix: prefix, server: server)
            downloaded.append(patch)
        } else {
            guard let selectedBase = self.base, let selectedPatch = self.patch else {
                throw InstallerFailure.message("Выбери IPA Telegram и пакет VeilGram.")
            }
            base = selectedBase
            patch = selectedPatch
        }
        status = "Встраиваем мод в Telegram…"
        let output = try Self.newInput(in: directory)
        do {
            try await Task.detached(priority: .userInitiated) {
                try TelegramPatch.apply(base: base, patch: patch, output: output)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
            throw error
        }
        useIPA(output, name: "VeilGram-unsigned.ipa")
    }

    private func fetchPatchAsset(_ asset: TelegramPatch.Asset, filename: String, prefix: String, server: String) async throws -> URL {
        guard asset.path == "/patcher/" + filename, asset.size > 0, asset.size <= 2_000_000_000,
              asset.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw InstallerFailure.message("Сервер вернул неверное описание файла.")
        }
        let url = try TelegramPatch.endpoint(server, path: prefix + "/" + filename)
        let (file, response) = try await URLSession.shared.download(from: url)
        do {
            guard response.url == url, (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw InstallerFailure.message("Сервер не отдал файл для патчера.")
            }
            try await Task.detached(priority: .userInitiated) { try TelegramPatch.verify(file, asset: asset) }.value
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func sign(password: String, bundleID: String, manifestURL: String, download: Bool,
              appearance: PatchAppearance, install: Bool = true) {
        guard !busy, let certificate, let profile else { return }
        let work = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        run("Проверяем файлы подписи…") {
            if self.ipa == nil { try await self.makePatch(server: manifestURL, download: download) }
            guard let ipa = self.ipa else { throw InstallerFailure.message("Сборка IPA не найдена.") }
            self.status = "Проверяем файлы подписи…"
            let newBuild: SignedBuild
            do {
                newBuild = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try await InstallerPackage.sign(
                        ipa: ipa, certificate: certificate, profile: profile, password: password,
                        requestedBundleID: bundleID, directory: work, appearance: appearance
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
            if !install {
                self.status = "Подписанный IPA готов к экспорту."
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
        failed = false
        Task {
            let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }
            do { try await operation() }
            catch {
                let message = Self.describe(error)
                if server != nil { finishTransfer(message) }
                else { status = message }
                failed = true
            }
            if server == nil { busy = false }
        }
    }

    private nonisolated static func newInput(in directory: URL) throws -> URL {
        let input = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        return input.appendingPathComponent("VeilGram-unsigned.ipa")
    }

    func clearOutput() {
        if let ipa { try? FileManager.default.removeItem(at: ipa.deletingLastPathComponent()) }
        ipa = nil
        ipaName = nil
        clearSigned()
    }

    private static func describe(_ error: Error) -> String {
        if let network = error as? URLError {
            switch network.code {
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                let host = network.failingURL?.host ?? "сервер VeilGram"
                return "iPhone не доверяет HTTPS-сертификату «\(host)». Укажи сервер с доверенным сертификатом или собери IPA из файлов."
            default: break
            }
        }
        return error.localizedDescription
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
        if components.path.isEmpty || components.path == "/" { components.path = "/install/manifest.plist" }
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

struct PatchRelease: Decodable, Identifiable {
    let id: String
    let version: String
    let build: String
    let telegramVersion: String
    let notes: String

    static let latest = PatchRelease(id: "latest", version: "Последняя сборка", build: "", telegramVersion: "", notes: "")
    var valid: Bool { id == "latest" || id.range(of: #"^[0-9]{1,12}$"#, options: .regularExpression) != nil }
    var prefix: String { id == "latest" ? "/patcher" : "/patcher/versions/\(id)" }
}
