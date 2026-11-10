import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AccountContext

final class PolusProfilePanel: UIView {
    private let stack = UIStackView()
    private(set) var preferredHeight: CGFloat = 0
    var action: (() -> Void)?
    var share: (() -> Void)?
    var archive: (() -> Void)?
    var hosting: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.stack.axis = .vertical
        self.stack.spacing = 8
        self.addSubview(self.stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.stack.frame = self.bounds
    }

    func update(context: AccountContext, profile: PolusProfile, canEdit: Bool, canGift: Bool) {
        for item in self.stack.arrangedSubviews {
            self.stack.removeArrangedSubview(item)
            item.removeFromSuperview()
        }
        self.preferredHeight = 0
        if let status = profile.status, !status.isEmpty {
            let label = UILabel()
            label.text = status
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            self.append(label, height: 24)
        }
        if canEdit {
            var config = UIButton.Configuration.tinted()
            config.title = "Оформление VeilGram"
            config.image = UIImage(systemName: "paintbrush.pointed")
            config.imagePadding = 8
            let button = UIButton(configuration: config)
            button.addTarget(self, action: #selector(self.performAction), for: .touchUpInside)
            self.append(button, height: 44)
        }
        if self.archive != nil {
            var config = UIButton.Configuration.gray()
            config.title = "Удалённые сообщения"
            config.image = UIImage(systemName: "archivebox")
            config.imagePadding = 8
            let button = UIButton(configuration: config)
            button.addTarget(self, action: #selector(self.openArchive), for: .touchUpInside)
            self.append(button, height: 44)
        }
        if self.hosting != nil {
            var config = UIButton.Configuration.gray()
            config.title = "Сервер VeilGram"
            config.image = UIImage(systemName: "server.rack")
            config.imagePadding = 8
            let button = UIButton(configuration: config)
            button.addTarget(self, action: #selector(self.openHosting), for: .touchUpInside)
            self.append(button, height: 44)
        }
        if canGift {
            var config = UIButton.Configuration.gray()
            config.title = "Отправить свой профиль VeilGram"
            config.image = UIImage(systemName: "paperplane")
            config.imagePadding = 8
            let button = UIButton(configuration: config)
            button.addTarget(self, action: #selector(self.shareProfile), for: .touchUpInside)
            self.append(button, height: 44)
        }
    }

    private func append(_ view: UIView, height: CGFloat) {
        if !self.stack.arrangedSubviews.isEmpty { self.preferredHeight += self.stack.spacing }
        self.stack.addArrangedSubview(view)
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        self.preferredHeight += height
    }

    @objc private func performAction() { self.action?() }
    @objc private func shareProfile() { self.share?() }
    @objc private func openArchive() { self.archive?() }
    @objc private func openHosting() { self.hosting?() }
}

final class PolusProfileEditor: UITableViewController, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    private let account: String
    private let balance: Int
    private var profile: PolusProfile
    private let didSave: (PolusProfile) -> Void
    private var busy = false
    private let bannerPreview = PolusProfileBanner(frame: .zero)
    private let previewContainer = UIView()
    private let previewAvatar = UIImageView(image: UIImage(systemName: "person.crop.circle.fill"))
    private let banners = PolusProfileService.catalog.banners
    private let colors: [(title: String, hex: String?)] = [
        ("По умолчанию", nil), ("Сирень", "C4A7FF"), ("Небо", "78C8FF"),
        ("Мята", "7EE3C4"), ("Роза", "FF9CC4"), ("Золото", "FFCD78")
    ]

    init(account: String, profile: PolusProfile, balance: Int, didSave: @escaping (PolusProfile) -> Void) {
        self.account = account
        self.profile = profile
        self.balance = balance
        self.didSave = didSave
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Оформление VeilGram"
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Отмена", style: .plain, target: self, action: #selector(self.close))
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Сохранить", style: .done, target: self, action: #selector(self.save))
        self.previewContainer.backgroundColor = .secondarySystemGroupedBackground
        self.previewContainer.layer.cornerRadius = 18
        self.previewContainer.clipsToBounds = true
        self.previewContainer.accessibilityLabel = "Предпросмотр баннера за аватаркой"
        self.previewContainer.isAccessibilityElement = true
        self.previewAvatar.contentMode = .scaleAspectFit
        self.previewAvatar.tintColor = .white
        self.previewAvatar.backgroundColor = UIColor(white: 0.18, alpha: 1)
        self.previewAvatar.layer.cornerRadius = 28
        self.previewAvatar.clipsToBounds = true
        self.previewContainer.addSubview(self.bannerPreview)
        self.previewContainer.addSubview(self.previewAvatar)
        self.tableView.tableHeaderView = self.previewContainer
        self.updateBannerPreview()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = self.tableView.bounds.width
        guard width > 0, self.previewContainer.bounds.size != CGSize(width: width, height: 156) else { return }
        self.previewContainer.frame = CGRect(x: 0, y: 0, width: width, height: 156)
        self.bannerPreview.frame = self.previewContainer.bounds
        self.previewAvatar.frame = CGRect(x: floor((width - 56) / 2), y: 50, width: 56, height: 56)
        self.tableView.tableHeaderView = self.previewContainer
    }

    private func updateBannerPreview() {
        self.bannerPreview.apply(self.profile, account: self.account, peer: self.account)
        self.bannerPreview.setVisible(self.profile.banner != nil || self.profile.media != nil)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return self.banners.count + 3
        case 1: return self.colors.count + 1
        default: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Баннер за аватаркой"
        case 1: return "Цвет имени и статус"
        default: return "Визуальные звёзды"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return "Фото, GIF и видео можно выбрать из медиатеки или «Файлов». Для длинного видео будут использованы первые 12 секунд."
        case 2: return "Баланс хранится на этом iPhone. Открой профиль человека, чтобы поделиться оформлением или отправить визуальный подарок в его личный чат."
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            cell.textLabel?.text = "Без баннера"
            cell.accessoryType = self.profile.banner == nil && self.profile.media == nil ? .checkmark : .none
        case (0, 1):
            cell.textLabel?.text = "Выбрать фото или видео"
            cell.accessoryType = self.profile.media != nil && self.profile.media?.kind != .gif ? .checkmark : .none
        case (0, 2):
            cell.textLabel?.text = "Выбрать файл · фото, GIF, видео"
            cell.accessoryType = self.profile.media?.kind == .gif ? .checkmark : .disclosureIndicator
        case (0, let row):
            let banner = self.banners[row - 3]
            cell.textLabel?.text = "\(banner.symbol)  \(banner.title)"
            cell.accessoryType = self.profile.banner == banner.id ? .checkmark : .none
        case (1, 0):
            cell.textLabel?.text = "Статус VeilGram"
            cell.detailTextLabel?.text = self.profile.status
            cell.accessoryType = .disclosureIndicator
        case (1, let row):
            let color = self.colors[row - 1]
            cell.textLabel?.text = color.title
            cell.imageView?.image = color.hex.map { _ in UIImage(systemName: "circle.fill") } ?? nil
            cell.imageView?.tintColor = color.hex.map(polusColor)
            cell.accessoryType = self.profile.color == color.hex ? .checkmark : .none
        default:
            cell.selectionStyle = .none
            cell.textLabel?.text = "\(self.balance) ✦ VeilGram"
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !self.busy else { return }
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            self.profile.banner = nil
            self.profile.media = nil
        case (0, 1):
            var configuration = PHPickerConfiguration()
            configuration.filter = .any(of: [.images, .videos])
            configuration.preferredAssetRepresentationMode = .current
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            self.present(picker, animated: true)
            return
        case (0, 2):
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.gif, .image, .movie, .video], asCopy: true)
            picker.delegate = self
            self.present(picker, animated: true)
            return
        case (0, let row):
            self.profile.banner = self.banners[row - 3].id
            self.profile.media = nil
        case (1, 0):
            self.textInput(title: "Статус VeilGram", value: self.profile.status) { text in
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard clean.unicodeScalars.count <= 32, clean.rangeOfCharacter(from: .controlCharacters) == nil else {
                    self.showMessage("Статус должен помещаться в одну строку до 32 символов.")
                    return
                }
                self.profile.status = clean.isEmpty ? nil : clean
                self.tableView.reloadData()
            }
            return
        case (1, let row):
            self.profile.color = self.colors[row - 1].hex
        default:
            return
        }
        self.updateBannerPreview()
        self.tableView.reloadData()
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let provider = results.first?.itemProvider
        picker.dismiss(animated: true) { [weak self] in
            guard let self, let provider else { return }
            self.perform {
                let (temporary, type) = try await self.loadPhotoAsset(provider)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try await self.importFrame(temporary, type: type)
            }
        }
    }

    private func loadPhotoAsset(_ provider: NSItemProvider) async throws -> (URL, UTType) {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let movies = types.filter { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        var candidates: [UTType]
        if types.contains(.gif) {
            candidates = [.gif]
        } else if !movies.isEmpty {
            candidates = movies
        } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            candidates = [.movie]
        } else {
            candidates = types.filter { $0.conforms(to: .image) }
            if candidates.isEmpty && provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                candidates = [.image]
            }
        }
        guard !candidates.isEmpty else { throw PolusFrameImport.ImportError.unsupported }
        for type in candidates {
            if let file = try await self.copyPhotoAsset(provider, type: type) {
                return (file, type)
            }
            if type.conforms(to: .image) {
                let data: Data? = await withCheckedContinuation { continuation in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { bytes, _ in
                        continuation.resume(returning: bytes)
                    }
                }
                if let data, !data.isEmpty {
                    guard data.count <= PolusFrameImport.inputLimit else { throw PolusFrameImport.ImportError.sourceTooLarge }
                    let url = Self.photoAssetTemporaryURL(type: type, sourceExtension: "")
                    try data.write(to: url, options: .atomic)
                    return (url, type)
                }
            }
        }
        throw PolusFrameImport.ImportError.unreadable
    }

    private func copyPhotoAsset(_ provider: NSItemProvider, type: UTType) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let temporary = Self.photoAssetTemporaryURL(type: type, sourceExtension: url.pathExtension)
                do {
                    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size > PolusFrameImport.inputLimit {
                        throw PolusFrameImport.ImportError.sourceTooLarge
                    }
                    try FileManager.default.copyItem(at: url, to: temporary)
                    continuation.resume(returning: temporary)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func photoAssetTemporaryURL(type: UTType, sourceExtension: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ext = sourceExtension.isEmpty ? type.preferredFilenameExtension ?? "" : sourceExtension
        return ext.isEmpty ? url : url.appendingPathExtension(ext)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        self.perform {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try await self.importFrame(url)
        }
    }

    private func importFrame(_ url: URL, type: UTType? = nil) async throws {
        self.profile.media = try await PolusFrameImport.prepare(url, type: type, account: self.account)
        self.profile.banner = nil
        self.updateBannerPreview()
        self.tableView.reloadData()
    }

    private func textInput(title: String, value: String?, completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = value
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Готово", style: .default) { [weak alert] _ in
            completion(alert?.textFields?.first?.text ?? "")
        })
        self.present(alert, animated: true)
    }

    @objc private func save() {
        guard !self.busy else { return }
        PolusProfileService.save(account: self.account, profile: self.profile)
        self.didSave(self.profile)
        self.dismiss(animated: true)
    }

    @objc private func close() { self.dismiss(animated: true) }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !self.busy else { return }
        self.busy = true
        self.navigationItem.leftBarButtonItem?.isEnabled = false
        self.navigationItem.rightBarButtonItem?.isEnabled = false
        self.isModalInPresentation = true
        Task { @MainActor in
            defer {
                self.busy = false
                self.navigationItem.leftBarButtonItem?.isEnabled = true
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                self.isModalInPresentation = false
            }
            do { try await action() } catch {
                self.tableView.reloadData()
                self.showMessage(error.localizedDescription)
            }
        }
    }

    private func showMessage(_ message: String) {
        let alert = UIAlertController(title: "VeilGram", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ОК", style: .default))
        self.present(alert, animated: true)
    }
}
