import UIKit

private func polusColor(_ hex: String) -> UIColor {
    guard let value = UInt32(hex, radix: 16) else { return .systemIndigo }
    return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
}

private final class PolusGradientCard: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    init(decoration: PolusDecoration, radius: CGFloat) {
        super.init(frame: .zero)
        self.layer.cornerRadius = radius
        self.clipsToBounds = true
        guard let gradient = self.layer as? CAGradientLayer else { return }
        gradient.colors = decoration.colors.map { polusColor($0).cgColor }
        gradient.startPoint = CGPoint(x: 0, y: 0.2)
        gradient.endPoint = CGPoint(x: 1, y: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

final class PolusProfilePanel: UIView {
    private let stack = UIStackView()
    private(set) var preferredHeight: CGFloat = 0
    var edit: (() -> Void)?

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

    func update(profile: PolusProfile, canEdit: Bool) {
        for item in self.stack.arrangedSubviews {
            self.stack.removeArrangedSubview(item)
            item.removeFromSuperview()
        }
        self.preferredHeight = 0

        let catalog = PolusProfileService.catalog
        if let banner = catalog.banners.first(where: { $0.id == profile.banner }) {
            let card = PolusGradientCard(decoration: banner, radius: 17)
            let text = UIStackView()
            text.axis = .vertical
            text.spacing = 4
            let caption = UILabel()
            caption.text = "VEILGRAM · БАННЕР ПРОФИЛЯ"
            caption.font = .systemFont(ofSize: 10, weight: .semibold)
            caption.textColor = .white.withAlphaComponent(0.86)
            let title = UILabel()
            title.text = banner.title
            title.font = .systemFont(ofSize: 20, weight: .bold)
            title.textColor = .white
            text.addArrangedSubview(caption)
            text.addArrangedSubview(title)
            text.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(text)
            let symbol = UILabel()
            symbol.text = banner.symbol
            symbol.font = .systemFont(ofSize: 62, weight: .light)
            symbol.textColor = .white.withAlphaComponent(0.72)
            symbol.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(symbol)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                text.centerYAnchor.constraint(equalTo: card.centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: symbol.leadingAnchor, constant: -4),
                symbol.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                symbol.centerYAnchor.constraint(equalTo: card.centerYAnchor)
            ])
            card.isAccessibilityElement = true
            card.accessibilityLabel = "Баннер VeilGram. \(banner.title)"
            self.append(card, height: 84)
        }

        let gifts = profile.gifts.compactMap { id in catalog.gifts.first(where: { $0.id == id }) }
        if !gifts.isEmpty {
            let row = UIStackView()
            row.spacing = 6
            row.distribution = .fillEqually
            row.accessibilityLabel = "Визуальные подарки VeilGram"
            for gift in gifts {
                let card = PolusGradientCard(decoration: gift, radius: 12)
                let symbol = UILabel()
                symbol.text = gift.symbol
                symbol.font = .systemFont(ofSize: 26)
                symbol.textAlignment = .center
                symbol.translatesAutoresizingMaskIntoConstraints = false
                card.addSubview(symbol)
                NSLayoutConstraint.activate([
                    symbol.centerXAnchor.constraint(equalTo: card.centerXAnchor),
                    symbol.centerYAnchor.constraint(equalTo: card.centerYAnchor)
                ])
                card.isAccessibilityElement = true
                card.accessibilityLabel = "Визуальный подарок. \(gift.title)"
                row.addArrangedSubview(card)
            }
            for _ in gifts.count..<max(3, gifts.count) { row.addArrangedSubview(UIView()) }
            self.append(row, height: 47)
        }

        if canEdit {
            var config = UIButton.Configuration.tinted()
            config.title = "Оформление VeilGram"
            config.image = UIImage(systemName: "paintbrush.pointed")
            config.imagePadding = 8
            let button = UIButton(configuration: config)
            button.addTarget(self, action: #selector(self.editPressed), for: .touchUpInside)
            self.append(button, height: 44)
        }
    }

    private func append(_ view: UIView, height: CGFloat) {
        if !self.stack.arrangedSubviews.isEmpty { self.preferredHeight += self.stack.spacing }
        self.stack.addArrangedSubview(view)
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        self.preferredHeight += height
    }

    @objc private func editPressed() { self.edit?() }
}

final class PolusProfileEditor: UITableViewController {
    private let account: String
    private var profile: PolusProfile
    private let didSave: (PolusProfile) -> Void
    private var busy = false
    private var hasEditedSelection = false
    private let catalog = PolusProfileService.catalog

    init(account: String, profile: PolusProfile, didSave: @escaping (PolusProfile) -> Void) {
        self.account = account
        self.profile = profile
        self.didSave = didSave
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Оформление VeilGram"
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Отмена", style: .plain, target: self, action: #selector(self.close))
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Сохранить", style: .done, target: self, action: #selector(self.save))
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "decoration")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return self.catalog.banners.count + 1
        case 1: return self.catalog.gifts.count
        default: return PolusProfileService.canSync && !PolusProfileService.isLinked(self.account) ? 2 : 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Баннер"
        case 1: return "Визуальные подарки · \(self.profile.gifts.count) из 6"
        default: return PolusProfileService.canSync ? "Общий профиль" : nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 2 else { return nil }
        if PolusProfileService.isLinked(self.account) {
            return "После сохранения оформление увидят подключённые пользователи VeilGram."
        }
        if PolusProfileService.canSync {
            return "Чтобы поделиться оформлением, нажмите «Запустить» в боте с этого Telegram-аккаунта, затем введите код и сохраните профиль. До подключения оформление хранится на этом iPhone."
        }
        return "Оформление хранится на этом iPhone. Для общего профиля нужен сервер VeilGram."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "decoration", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        if indexPath.section == 0 {
            let banner = indexPath.row == 0 ? nil : self.catalog.banners[indexPath.row - 1]
            content.text = banner.map { "\($0.symbol)  \($0.title)" } ?? "Без баннера"
            cell.accessoryType = self.profile.banner == banner?.id ? .checkmark : .none
        } else if indexPath.section == 1 {
            let gift = self.catalog.gifts[indexPath.row]
            content.text = "\(gift.symbol)  \(gift.title)"
            cell.accessoryType = self.profile.gifts.contains(gift.id) ? .checkmark : .none
        } else {
            content.text = indexPath.row == 0 ? "Открыть бота" : "Ввести код"
            content.textProperties.color = self.view.tintColor
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !self.busy else { return }
        if indexPath.section == 0 {
            self.profile.banner = indexPath.row == 0 ? nil : self.catalog.banners[indexPath.row - 1].id
        } else if indexPath.section == 1 {
            let id = self.catalog.gifts[indexPath.row].id
            if let index = self.profile.gifts.firstIndex(of: id) {
                self.profile.gifts.remove(at: index)
            } else if self.profile.gifts.count < 6 {
                self.profile.gifts.append(id)
            } else {
                self.showMessage("В профиле помещается до шести подарков.")
                return
            }
        } else {
            if indexPath.row == 0 { self.openBot() } else { self.enterCode() }
            return
        }
        self.hasEditedSelection = true
        tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
    }

    private func openBot() {
        self.perform {
            let url = try await PolusProfileService.botURL()
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private func enterCode() {
        let alert = UIAlertController(title: "Код из бота", message: "Введите восемь символов из сообщения бота.", preferredStyle: .alert)
        alert.addTextField { field in
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
            field.keyboardType = .asciiCapable
            field.textContentType = .oneTimeCode
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Подключить", style: .default) { [weak self, weak alert] _ in
            guard let self, let code = alert?.textFields?.first?.text else { return }
            self.perform {
                try await PolusProfileService.link(self.account, code: code)
                if !self.hasEditedSelection {
                    let profile = try? await PolusProfileService.load(account: self.account, peer: self.account)
                    self.profile = profile ?? self.profile
                }
                self.tableView.reloadData()
            }
        })
        self.present(alert, animated: true)
    }

    @objc private func save() {
        self.perform {
            let profile = try await PolusProfileService.save(account: self.account, profile: self.profile)
            self.didSave(profile)
            self.dismiss(animated: true, completion: nil)
        }
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
