import UIKit
import AccountContext
import ComponentFlow
import GiftItemComponent
import SwiftSignalKit
import TelegramCore

private extension StarGift {
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
    private let account: String
    private let recipient: String
    private let didSend: () -> Void
    private let catalogLoad = MetaDisposable()
    private let collectibleLoad = MetaDisposable()
    private var gifts: [StarGift] = []
    private var collectible: StarGift?
    private var balance: Int?
    private var busy = false
    private var pending: (item: String, nonce: UUID)?

    init(context: AccountContext, account: String, recipient: String, didSend: @escaping () -> Void) {
        self.context = context
        self.account = account
        self.recipient = recipient
        self.didSend = didSend
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Подарок VeilGram"
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(self.close))
        self.catalogLoad.set((self.context.engine.payments.cachedStarGifts() |> deliverOnMainQueue).start(next: { [weak self] gifts in
            guard let self, let gifts else { return }
            self.gifts = gifts.filter { if case .generic = $0 { return true }; return false }
            self.tableView.reloadData()
        }))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.balance = try await PolusProfileService.load(account: self.account, peer: self.account).balance
            } catch {
                self.message(error.localizedDescription)
            }
            self.tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (self.collectible == nil ? 1 : 2) : self.gifts.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return self.balance.map { "Баланс VeilGram · \($0) ✦" } ?? "Баланс VeilGram" }
        return self.gifts.isEmpty ? "Загружаем каталог Telegram…" : "Каталог Telegram"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "Подарки видны в VeilGram. Оплата идёт визуальными звёздами VeilGram." : nil
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
            cell.detailTextLabel?.text = "\(gift.polusCost) ✦ VeilGram"
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
            self.confirm(gift)
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
            let pattern = "^(?:https://)?t\\.me/nft/([A-Za-z0-9]{1,60}-[1-9][0-9]{0,11})/?$"
            guard let range = text.range(of: pattern, options: .regularExpression),
                  let slug = text[range].split(separator: "/").last else {
                self.message("Вставь полную ссылку на коллекционный подарок Telegram.")
                return
            }
            self.busy = true
            self.collectibleLoad.set((self.context.engine.payments.getUniqueStarGift(slug: String(slug)) |> deliverOnMainQueue)
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
        guard let balance = self.balance else { return }
        guard balance >= gift.polusCost || self.pending?.item == gift.polusID else {
            self.message("Не хватает визуальных звёзд VeilGram.")
            return
        }
        let alert = UIAlertController(title: gift.polusTitle, message: "Подарить за \(gift.polusCost) визуальных звёзд VeilGram?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Подарить", style: .default) { [weak self] _ in self?.send(gift) })
        self.present(alert, animated: true)
    }

    private func send(_ gift: StarGift) {
        guard !self.busy else { return }
        let item = gift.polusID
        let nonce = self.pending.flatMap { $0.item == item ? $0.nonce : nil } ?? UUID()
        self.pending = (item, nonce)
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
                self.balance = try await PolusProfileService.sendGift(account: self.account, recipient: self.recipient, item: item, nonce: nonce)
                self.pending = nil
                self.didSend()
                self.dismiss(animated: true)
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
