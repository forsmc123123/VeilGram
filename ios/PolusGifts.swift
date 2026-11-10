import UIKit
import AccountContext
import ComponentFlow
import GiftItemComponent
import SwiftSignalKit
import TelegramCore

extension StarGift {
    var polusID: String {
        switch self {
        case let .generic(gift): return "gift:\(gift.id)"
        case let .unique(gift): return "nft:\(gift.slug)"
        }
    }

    var polusTitle: String {
        switch self {
        case let .generic(gift):
            let emoji = gift.file.attributes.compactMap { attribute -> String? in
                if case let .Sticker(displayText, _, _) = attribute { return displayText }
                return nil
            }.first ?? ""
            return gift.title ?? (emoji.isEmpty ? "Подарок Telegram" : emoji)
        case let .unique(gift): return "\(gift.title) #\(gift.number)"
        }
    }

    var polusCost: Int {
        if case .unique = self { return 100 }
        return 25
    }
}

final class PolusGiftShelf: UIView {
    private let context: AccountContext
    private let title = UILabel()
    private let action = UIButton(type: .system)
    private var tiles: [UIButton] = []
    private var items: [String] = []
    var onAction: (() -> Void)?
    var onGift: ((String) -> Void)?

    init(context: AccountContext, isOwn: Bool) {
        self.context = context
        super.init(frame: .zero)
        self.title.text = "Витрина VeilGram"
        self.title.font = .preferredFont(forTextStyle: .headline)
        self.title.textColor = .label
        self.addSubview(self.title)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = isOwn ? "Добавить NFT" : "Подарить визуально"
        configuration.image = UIImage(systemName: isOwn ? "plus" : "gift")
        configuration.imagePadding = 6
        self.action.configuration = configuration
        self.action.addTarget(self, action: #selector(self.performAction), for: .touchUpInside)
        self.addSubview(self.action)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(items: [String]) {
        guard items != self.items else { return }
        self.items = items
        self.tiles.forEach { $0.removeFromSuperview() }
        self.tiles = items.map { item in
            let button = UIButton(type: .custom)
            let tile = PolusGiftTile(context: self.context, item: item)
            tile.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            tile.frame = button.bounds
            tile.isAccessibilityElement = false
            button.addSubview(tile)
            let badge = UILabel()
            badge.text = "Визуальный"
            badge.font = .systemFont(ofSize: 10, weight: .semibold)
            badge.textColor = .white
            badge.backgroundColor = UIColor.black.withAlphaComponent(0.70)
            badge.textAlignment = .center
            badge.layer.cornerRadius = 8
            badge.clipsToBounds = true
            badge.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                badge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -5),
                badge.widthAnchor.constraint(equalToConstant: 76),
                badge.heightAnchor.constraint(equalToConstant: 16)
            ])
            button.accessibilityLabel = "Визуальный подарок VeilGram"
            button.addAction(UIAction { [weak self] _ in self?.onGift?(item) }, for: .touchUpInside)
            self.addSubview(button)
            return button
        }
        self.setNeedsLayout()
    }

    private func side(_ width: CGFloat) -> CGFloat { max(0, min(128, floor((width - 16) / 3))) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let rows = (self.tiles.count + 2) / 3
        return CGSize(width: size.width, height: 72 + CGFloat(rows) * (self.side(size.width) + 8))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.title.frame = CGRect(x: 0, y: 0, width: self.bounds.width, height: 22)
        self.action.frame = CGRect(x: 0, y: 28, width: self.bounds.width, height: 36)
        let side = self.side(self.bounds.width)
        let x = max(0, floor((self.bounds.width - side * 3 - 16) / 2))
        for (index, tile) in self.tiles.enumerated() {
            tile.frame = CGRect(x: x + CGFloat(index % 3) * (side + 8),
                y: 72 + CGFloat(index / 3) * (side + 8), width: side, height: side)
        }
    }

    @objc private func performAction() { self.onAction?() }
}

final class PolusGiftTile: UIView {
    private let context: AccountContext
    private let itemView = ComponentView<Empty>()
    private let load = MetaDisposable()
    private var gift: StarGift?
    private let placeholder = UIImageView(image: UIImage(systemName: "gift.fill"))

    init(context: AccountContext, item: String) {
        self.context = context
        super.init(frame: .zero)
        self.isAccessibilityElement = true
        self.accessibilityLabel = "Визуальный подарок VeilGram"
        self.isUserInteractionEnabled = false
        self.backgroundColor = .tertiarySystemFill
        self.layer.cornerRadius = 12
        self.clipsToBounds = true
        self.placeholder.tintColor = .secondaryLabel
        self.placeholder.contentMode = .scaleAspectFit
        self.addSubview(self.placeholder)
        if item.hasPrefix("nft:") {
            self.load.set((context.engine.payments.getUniqueStarGift(slug: String(item.dropFirst(4))) |> deliverOnMainQueue)
                .start(next: { [weak self] gift in self?.setGift(.unique(gift)) }))
        } else {
            self.load.set((context.engine.payments.cachedStarGifts() |> deliverOnMainQueue)
                .start(next: { [weak self] catalog in
                    if let gift = catalog?.first(where: { $0.polusID == item }) { self?.setGift(gift) }
                }))
        }
    }

    init(context: AccountContext, gift: StarGift) {
        self.context = context
        super.init(frame: .zero)
        self.isUserInteractionEnabled = false
        self.setGift(gift)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func setGift(_ gift: StarGift) {
        self.gift = gift
        self.accessibilityLabel = "Визуальный подарок VeilGram, \(gift.polusTitle)"
        self.placeholder.isHidden = true
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.placeholder.frame = self.bounds.insetBy(dx: self.bounds.width * 0.27, dy: self.bounds.height * 0.27)
        guard let gift = self.gift, self.bounds.width > 0, self.bounds.height > 0 else { return }
        let presentation = self.context.sharedContext.currentPresentationData.with { $0 }
        let subject: GiftItemComponent.Subject
        switch gift {
        case let .generic(value): subject = .starGift(gift: value, price: "")
        case let .unique(value): subject = .uniqueGift(gift: value, price: nil)
        }
        let size = self.itemView.update(
            transition: .immediate,
            component: AnyComponent(GiftItemComponent(context: self.context, theme: presentation.theme, strings: presentation.strings,
                subject: subject, mode: .profile, cornerRadius: 12, allowAnimations: !UIAccessibility.isReduceMotionEnabled)),
            environment: {},
            containerSize: self.bounds.size
        )
        if let view = self.itemView.view {
            if view.superview == nil { self.addSubview(view) }
            view.frame = CGRect(origin: .zero, size: size)
        }
    }

    deinit { self.load.dispose() }
}

final class PolusGiftPicker: UITableViewController {
    private let context: AccountContext
    private let recipient: EnginePeer.Id
    private let didSend: () -> Void
    private let addToShowcase: ((StarGift.UniqueGift) -> Void)?
    private let catalogLoad = MetaDisposable()
    private let collectibleLoad = MetaDisposable()
    private var gifts: [StarGift] = []
    private var collectible: StarGift?
    private var busy = false

    init(context: AccountContext, recipient: EnginePeer.Id, addToShowcase: ((StarGift.UniqueGift) -> Void)? = nil,
         didSend: @escaping () -> Void = {}) {
        self.context = context
        self.recipient = recipient
        self.didSend = didSend
        self.addToShowcase = addToShowcase
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = self.addToShowcase == nil ? "Подарок VeilGram" : "Добавить NFT в витрину"
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(self.close))
        if self.addToShowcase == nil {
            self.catalogLoad.set((self.context.engine.payments.cachedStarGifts() |> deliverOnMainQueue).start(next: { [weak self] gifts in
            guard let self, let gifts else { return }
            self.gifts = gifts.filter { if case .generic = $0 { return true }; return false }
            self.tableView.reloadData()
            }))
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { self.addToShowcase == nil ? 2 : 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (self.collectible == nil ? 1 : 2) : self.gifts.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 {
            return self.addToShowcase == nil ? "Баланс VeilGram · \(PolusTelegramExchange.balance(self.context)) ✦" : "Коллекционный подарок Telegram"
        }
        return self.gifts.isEmpty ? "Загружаем каталог Telegram…" : "Каталог Telegram"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        return self.addToShowcase == nil ? "В VeilGram получатель увидит карточку в личном чате и подарок во вкладке «Подарки»." :
            "Вставь ссылку на NFT или удержи коллекционный подарок в любом профиле и выбери «В витрину VeilGram»."
    }

    private func gift(at indexPath: IndexPath) -> StarGift? {
        indexPath.section == 0 ? (indexPath.row == 0 ? nil : self.collectible) : self.gifts[indexPath.row]
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if let gift = self.gift(at: indexPath) {
            let tile = PolusGiftTile(context: self.context, gift: gift)
            tile.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
            cell.accessoryView = tile
            cell.textLabel?.text = gift.polusTitle
            cell.detailTextLabel?.text = self.addToShowcase == nil ? "\(gift.polusCost) ✦ VeilGram" : "Нажми, чтобы добавить в витрину"
        } else {
            cell.textLabel?.text = "Коллекционный подарок по ссылке"
            cell.textLabel?.textColor = self.view.tintColor
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 62 }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !self.busy else { return }
        if let gift = self.gift(at: indexPath) {
            if let add = self.addToShowcase, case let .unique(value) = gift {
                self.dismiss(animated: true) { add(value) }
            } else {
                self.confirm(gift)
            }
        } else {
            self.enterCollectible()
        }
    }

    private func enterCollectible() {
        let alert = UIAlertController(title: "Коллекционный подарок", message: "Вставь ссылку t.me/nft/… из Telegram.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://t.me/nft/…"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Найти", style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            guard let slug = PolusProfileService.collectibleSlug(text) else {
                self.message("Вставь полную ссылку на коллекционный подарок Telegram.")
                return
            }
            self.busy = true
            self.collectibleLoad.set((self.context.engine.payments.getUniqueStarGift(slug: slug) |> deliverOnMainQueue)
                .start(next: { [weak self] gift in
                    self?.busy = false
                    self?.collectible = .unique(gift)
                    self?.tableView.reloadData()
                }, error: { [weak self] _ in
                    self?.busy = false
                    self?.message("Telegram не вернул подарок по этой ссылке.")
                }))
        })
        self.present(alert, animated: true)
    }

    private func confirm(_ gift: StarGift) {
        guard PolusTelegramExchange.balance(self.context) >= gift.polusCost else {
            self.message("Не хватает визуальных звёзд VeilGram.")
            return
        }
        let alert = UIAlertController(title: gift.polusTitle, message: "Отправить в личный чат за \(gift.polusCost) визуальных звёзд VeilGram?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Подарить", style: .default) { [weak self] _ in self?.send(gift) })
        self.present(alert, animated: true)
    }

    private func send(_ gift: StarGift) {
        guard !self.busy else { return }
        self.busy = true
        self.isModalInPresentation = true
        self.navigationItem.leftBarButtonItem?.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.isModalInPresentation = false
                self.navigationItem.leftBarButtonItem?.isEnabled = true
            }
            do {
                try await PolusTelegramExchange.sendGift(context: self.context, peer: self.recipient, item: gift.polusID, title: gift.polusTitle)
                self.dismiss(animated: true, completion: self.didSend)
            } catch {
                self.message(error.localizedDescription)
            }
        }
    }

    @objc private func close() { self.dismiss(animated: true) }

    private func message(_ text: String) {
        let alert = UIAlertController(title: "VeilGram", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ОК", style: .default))
        self.present(alert, animated: true)
    }

    deinit {
        self.catalogLoad.dispose()
        self.collectibleLoad.dispose()
    }
}
