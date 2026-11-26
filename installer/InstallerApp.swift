import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct VeilGramInstaller: App {
    var body: some Scene {
        WindowGroup { InstallerView() }
    }
}

@MainActor
private struct InstallerView: View {
    private enum ImportKind {
        case base, patch, certificate, profile
    }

    @StateObject private var model = InstallerModel()
    @AppStorage("manifestURL") private var manifestURL = Bundle.main.object(
        forInfoDictionaryKey: "VeilGramManifestURL"
    ) as? String ?? ""
    @State private var importKind: ImportKind = .base
    @State private var importing = false
    @State private var password = ""
    @State private var bundleID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Telegram и мод VeilGram") {
                    Button("Скачать Telegram и мод") { model.preparePatch(server: manifestURL, download: true) }
                    Button(model.baseName ?? "Выбрать базовый IPA Telegram") { pick(.base) }
                    Button(model.patchName ?? "Выбрать пакет VeilGram") { pick(.patch) }
                    if model.baseName != nil && model.patchName != nil {
                        Button("Встроить мод в Telegram") { model.preparePatch(server: manifestURL, download: false) }
                    }
                    if let name = model.ipaName {
                        Label(name, systemImage: "shippingbox")
                    }
                }
                .disabled(model.busy)

                Section("Подпись приложения") {
                    Button(model.certificateName ?? "Выбрать сертификат .p12") { pick(.certificate) }
                    Button(model.profileName ?? "Выбрать профиль .mobileprovision") { pick(.profile) }
                    SecureField("Пароль сертификата", text: $password)
                    TextField("Другой Bundle ID, если требуется", text: $bundleID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .disabled(model.busy)

                Section("Установка") {
                    TextField("HTTPS-адрес API или манифеста", text: $manifestURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.busy)
                    Button("Подписать и установить") {
                        model.sign(password: password, bundleID: bundleID, manifestURL: manifestURL)
                        password = ""
                    }
                    .disabled(!model.canSign)
                    if let signedIPA = model.signedIPA {
                        ShareLink(item: signedIPA) {
                            Label("Экспортировать подписанный IPA", systemImage: "square.and.arrow.up")
                        }
                        .disabled(model.busy)
                        Button("Установить подписанный IPA") { model.install(manifestURL: manifestURL) }
                            .disabled(model.busy)
                    }
                    if !model.busy, let ipa = model.ipa {
                        ShareLink(item: ipa) {
                            Label("Передать IPA в другой установщик", systemImage: "arrow.up.right.square")
                        }
                    }
                }
                if let status = model.status {
                    Section {
                        HStack {
                            if model.busy { ProgressView() }
                            Text(status)
                        }
                        if model.canStop { Button("Завершить передачу", role: .cancel) { model.stopServing() } }
                    }
                }
            }
            .navigationTitle("VeilGram Installer")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                do {
                    let url = try result.get()
                    switch importKind {
                    case .base: model.importPatchInput(url, base: true)
                    case .patch: model.importPatchInput(url, base: false)
                    case .certificate: try model.importCredential(url, certificate: true)
                    case .profile: try model.importCredential(url, certificate: false)
                    }
                } catch {
                    model.status = error.localizedDescription
                }
            }
        }
    }

    private func pick(_ kind: ImportKind) {
        importKind = kind
        importing = true
    }
}
