import PhotosUI
import SwiftUI
import UIKit
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
    private enum Tab: String, CaseIterable {
        case patch = "Патч", versions = "Версии", signing = "Подпись", settings = "Настройки"

        var icon: String {
            switch self {
            case .patch: return "wand.and.stars"
            case .versions: return "square.stack"
            case .signing: return "key"
            case .settings: return "gearshape"
            }
        }
    }

    private enum ImportKind { case base, patch }

    private enum SigningFile: String, Identifiable {
        case certificate, profile

        var id: String { rawValue }

        var contentTypes: [UTType] {
            switch self {
            case .certificate:
                return [.pkcs12]
            case .profile:
                return [UTType(filenameExtension: "mobileprovision") ?? .data]
            }
        }
    }

    @StateObject private var model = InstallerModel()
    @AppStorage("manifestURL") private var manifestURL = Bundle.main.object(
        forInfoDictionaryKey: "VeilGramManifestURL"
    ) as? String ?? ""
    @AppStorage("patchBundleID") private var bundleID = ""
    @AppStorage("patchDisplayName") private var displayName = ""
    @State private var tab: Tab = .patch
    @State private var fromFiles = false
    @State private var importKind: ImportKind = .base
    @State private var importing = false
    @State private var signingFile: SigningFile?
    @State private var password = ""
    @State private var icon: PhotosPickerItem?
    @State private var appearance = PatchAppearance()
    @State private var forgetConfirmation = false

    private let background = Color(red: 0.07, green: 0.05, blue: 0.11)
    private let surface = Color(red: 0.12, green: 0.09, blue: 0.18)
    private let ink = Color(red: 0.79, green: 0.72, blue: 0.99)
    private let muted = Color(red: 0.73, green: 0.68, blue: 0.82)
    private let line = Color.white.opacity(0.09)
    private let warning = Color(red: 1, green: 0.75, blue: 0.60)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header.id("header")
                    content
                    if let status = model.status { operation(status).id("operation") }
                }
                .frame(maxWidth: 600)
                .padding(.horizontal, 19)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: tab) { _ in proxy.scrollTo("header", anchor: .top) }
            .onChange(of: model.failed) { failed in
                if failed, tab == .patch {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("operation", anchor: .bottom) }
                }
            }
        }
        .background(background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { navigation }
        .preferredColorScheme(.dark)
        .tint(ink)
        .onAppear { if password.isEmpty { password = model.storedPassword ?? "" } }
        .task(id: tab) {
            if tab == .versions { await model.refreshVersions(server: manifestURL) }
        }
        .onChange(of: icon) { selection in
            guard let selection else { return }
            Task {
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else {
                        throw InstallerFailure.message("Не удалось загрузить изображение.")
                    }
                    guard icon == selection, !model.busy else { return }
                    try appearance.selectIcon(data)
                } catch { model.report(error) }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do {
                let url = try result.get()
                switch importKind {
                case .base: model.importPatchInput(url, base: true)
                case .patch: model.importPatchInput(url, base: false)
                }
            } catch { model.report(error) }
        }
        .sheet(item: $signingFile) { input in
            SigningFilePicker(contentTypes: input.contentTypes) { url in
                signingFile = nil
                guard let url else { return }
                do { try model.importCredential(url, certificate: input == .certificate) }
                catch { model.report(error) }
            }
        }
        .alert("Установить VeilGram?", isPresented: $model.confirmingProfileInstall, presenting: model.signedBundleID) { id in
            Button("Установить") { model.install(manifestURL: manifestURL, confirmedBundleID: id) }
            Button("Отмена", role: .cancel) {}
        } message: { id in
            Text("Профиль выбрал Bundle ID \(id). Если на iPhone уже есть приложение с таким ID, iOS может его заменить.")
        }
        .confirmationDialog("Удалить сохранённую подпись?", isPresented: $forgetConfirmation, titleVisibility: .visible) {
            Button("Удалить данные подписи", role: .destructive) {
                do {
                    try model.forgetSigning()
                    password = ""
                } catch { model.report(error) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 13) {
            brandIcon
            VStack(alignment: .leading, spacing: 3) {
                Text("VeilGram").font(.system(.largeTitle, design: .rounded, weight: .heavy))
                Text("Патчер для Telegram").font(.subheadline).foregroundStyle(muted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var brandIcon: some View {
        Group {
            if let file = Bundle.main.path(forResource: "VeilGramBrand", ofType: "png"),
               let picture = UIImage(contentsOfFile: file) {
                Image(uiImage: picture).resizable().scaledToFill()
            } else {
                Image(systemName: "wand.and.stars").font(.title2).foregroundStyle(ink)
            }
        }
        .frame(width: 53, height: 53)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(line))
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .patch: patchScreen
        case .versions: versionsScreen
        case .signing: signingScreen
        case .settings: settingsScreen
        }
    }

    private var patchScreen: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 13) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 51, height: 51)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityHidden(true)
                Text(fromFiles ? "Сборка из файлов" : model.selectedRelease.version)
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text(fromFiles ? "Базовый Telegram IPA и пакет VeilGram" :
                        (model.selectedRelease.telegramVersion.isEmpty ? "Telegram + пакет VeilGram" : "Telegram \(model.selectedRelease.telegramVersion)"))
                    .font(.subheadline)
                    .foregroundStyle(muted)
                if let name = model.ipaName {
                    Label(name, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(21)
            .background {
                RoundedRectangle(cornerRadius: 26)
                    .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.15, blue: 0.40), surface],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(alignment: .trailing) {
                        ZStack {
                            Circle().strokeBorder(ink.opacity(0.12), lineWidth: 1).frame(width: 150, height: 150)
                            Circle().strokeBorder(ink.opacity(0.10), lineWidth: 1).frame(width: 118, height: 118)
                            Circle().fill(ink.opacity(0.05)).frame(width: 86, height: 86)
                        }
                        .offset(x: 40, y: -30)
                        .accessibilityHidden(true)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 26))
            }
            panel("Источник") {
                Picker("Источник", selection: $fromFiles) {
                    Text("Сервер").tag(false)
                    Text("Файлы").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: fromFiles) { _ in model.clearOutput() }
                if fromFiles {
                    rowButton("Базовый Telegram IPA", icon: "shippingbox", detail: model.baseName) { pick(.base) }
                    rowButton("Пакет VeilGram", icon: "puzzlepiece.extension", detail: model.patchName) { pick(.patch) }
                } else {
                    rowButton("Выбрать версию", icon: "square.stack", detail: model.selectedRelease.version) { tab = .versions }
                }
            }
            .disabled(model.busy)

            Button {
                if model.hasSigning {
                    model.sign(password: password, bundleID: bundleID, manifestURL: manifestURL,
                               download: !fromFiles, appearance: currentAppearance)
                } else {
                    tab = .signing
                }
            } label: {
                Label(model.hasSigning ? "Собрать и установить" : "Настроить подпись",
                      systemImage: model.hasSigning ? "arrow.down.app" : "key")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(FilledPatchButton(ink: ink))
            .disabled(model.busy || (model.hasSigning && !canBuild))

            if let ipa = model.ipa {
                ShareLink(item: ipa) { actionLabel("Экспортировать IPA без подписи", icon: "square.and.arrow.up") }
                    .buttonStyle(.plain).disabled(model.busy)
            } else {
                Button {
                    model.preparePatch(server: manifestURL, download: !fromFiles)
                } label: { actionLabel("Собрать IPA без подписи", icon: "shippingbox") }
                    .buttonStyle(.plain).disabled(model.busy || !canBuild)
            }
            if let signed = model.signedIPA {
                ShareLink(item: signed) { actionLabel("Экспортировать подписанный IPA", icon: "square.and.arrow.up") }
                    .buttonStyle(.plain).disabled(model.busy)
                rowButton("Повторить системную установку", icon: "arrow.clockwise") { model.install(manifestURL: manifestURL) }
                    .disabled(model.busy)
            } else if model.hasSigning {
                rowButton("Подписать IPA для экспорта", icon: "signature") {
                    model.sign(password: password, bundleID: bundleID, manifestURL: manifestURL,
                               download: !fromFiles, appearance: currentAppearance, install: false)
                }
                .disabled(model.busy || !canBuild)
            }
        }
    }

    private var canBuild: Bool { !fromFiles || model.hasLocalPair || model.ipa != nil }

    private var currentAppearance: PatchAppearance {
        var result = appearance
        result.name = displayName
        return result
    }

    private var versionsScreen: some View {
        VStack(alignment: .leading, spacing: 15) {
            panel("Версии VeilGram") {
                if model.loadingVersions {
                    HStack(spacing: 10) { ProgressView(); Text("Загружаем версии…") }.foregroundStyle(muted)
                }
                if let error = model.versionsError {
                    Text(error).font(.subheadline).foregroundStyle(warning)
                    rowButton("Настройки сервера", icon: "network") { tab = .settings }
                }
                ForEach(model.versions) { version in
                    Button {
                        fromFiles = false
                        model.selectRelease(version)
                        tab = .patch
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            tile(version.id == model.selectedRelease.id ? "checkmark" : "shippingbox")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(version.version).font(.headline).foregroundStyle(.white)
                                let detail = [version.build.isEmpty ? "" : "Сборка \(version.build)",
                                              version.telegramVersion.isEmpty ? "" : "Telegram \(version.telegramVersion)"]
                                    .filter { !$0.isEmpty }.joined(separator: " · ")
                                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(muted) }
                                if !version.notes.isEmpty { Text(version.notes).font(.subheadline).foregroundStyle(muted) }
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(model.busy)
                }
                rowButton("Обновить список", icon: "arrow.clockwise") {
                    Task { await model.refreshVersions(server: manifestURL) }
                }
                .disabled(model.loadingVersions)
            }
        }
    }

    private var signingScreen: some View {
        VStack(alignment: .leading, spacing: 15) {
            panel("Сертификат и профиль") {
                rowButton("Сертификат .p12", icon: "key", detail: model.certificateName) { signingFile = .certificate }
                rowButton("Профиль .mobileprovision", icon: "checkmark.shield", detail: model.profileName) { signingFile = .profile }
                SecureField("Пароль сертификата", text: $password).modifier(FieldStyle())
            }
            panel("Связка ключей") {
                Text("Сертификат, профиль и пароль можно сохранить на этом iPhone.").font(.subheadline).foregroundStyle(muted)
                rowButton("Запомнить подпись", icon: "lock") {
                    do { try model.rememberSigning(password: password) } catch { model.report(error) }
                }
                .disabled(!model.hasSigning)
                if model.storedPassword != nil {
                    rowButton("Удалить данные подписи", icon: "trash") { forgetConfirmation = true }
                }
            }
        }
        .disabled(model.busy)
    }

    private var settingsScreen: some View {
        VStack(alignment: .leading, spacing: 15) {
            panel("Сервер VeilGram") {
                TextField("https://veilgram.example", text: $manifestURL)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().modifier(FieldStyle())
                    .accessibilityLabel("HTTPS-адрес API или манифеста")
                Text("Для скачивания IPA и системной установки используется доверенный HTTPS.")
                    .font(.subheadline).foregroundStyle(muted)
            }
            panel("Оформление подписанного IPA") {
                TextField("Название приложения", text: $displayName).modifier(FieldStyle())
                TextField("Bundle ID", text: $bundleID).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().modifier(FieldStyle())
                PhotosPicker(selection: $icon, matching: .images) {
                    actionLabel(appearance.icon180 == nil ? "Выбрать свою иконку" : "Заменить свою иконку", icon: "photo")
                }
                .buttonStyle(.plain)
                if appearance.icon180 != nil {
                    rowButton("Вернуть иконку VeilGram", icon: "arrow.uturn.backward") {
                        icon = nil
                        appearance.icon120 = nil
                        appearance.icon180 = nil
                    }
                }
            }
        }
        .disabled(model.busy)
    }

    private func operation(_ status: String) -> some View {
        panel(model.failed ? "Сборка остановилась" : "Состояние") {
            HStack(alignment: .top, spacing: 10) {
                if model.busy { ProgressView().tint(ink).accessibilityHidden(true) }
                else { Image(systemName: model.failed ? "exclamationmark.circle" : "info.circle").accessibilityHidden(true) }
                Text(status).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(model.failed ? warning : muted)
            if model.canStop {
                rowButton("Завершить передачу", icon: "stop.circle") { model.stopServing() }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var navigation: some View {
        HStack(spacing: 3) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon).font(.system(size: 19, weight: .semibold)).accessibilityHidden(true)
                        Text(item.rawValue).font(.caption2.weight(.semibold)).lineLimit(1)
                    }
                    .foregroundStyle(tab == item ? ink : muted)
                    .frame(maxWidth: .infinity, minHeight: 53)
                    .background(tab == item ? ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 15))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(surface)
        .overlay(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
    }

    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(line).allowsHitTesting(false))
    }

    private func tile(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
            .frame(width: 36, height: 36).background(ink.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private func actionLabel(_ title: String, icon: String, detail: String? = nil) -> some View {
        HStack(spacing: 10) {
            tile(icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if let detail { Text(detail).font(.caption).foregroundStyle(muted).lineLimit(2) }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(muted).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func rowButton(_ title: String, icon: String, detail: String? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, icon: icon, detail: detail) }.buttonStyle(.plain)
    }

    private func pick(_ kind: ImportKind) {
        importKind = kind
        importing = true
    }
}

private struct SigningFilePicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onSelection: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelection: (URL?) -> Void

        init(onSelection: @escaping (URL?) -> Void) {
            self.onSelection = onSelection
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onSelection(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onSelection(nil)
        }
    }
}

private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 13).frame(minHeight: 49)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct FilledPatchButton: ButtonStyle {
    let ink: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(red: 0.12, green: 0.06, blue: 0.19))
            .background(ink.opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.43),
                        in: RoundedRectangle(cornerRadius: 15))
    }
}
