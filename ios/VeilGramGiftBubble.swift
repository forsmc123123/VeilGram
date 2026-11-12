import UIKit
import AccountContext
import ChatMessageBubbleContentNode
import ChatMessageItemCommon
import ComponentFlow
import Display
import GiftItemComponent
import SwiftSignalKit
import TelegramCore

public final class VeilGramGiftBubble: ChatMessageBubbleContentNode {
    private var card: VeilGramGiftCard?

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        if gesture == .tap, let card = self.card, card.frame.contains(point) {
            if let link = card.collectibleLink {
                return ChatMessageBubbleContentTapAction(content: .url(.init(url: link, concealed: false)))
            }
            return ChatMessageBubbleContentTapAction(content: .custom { card.presentDetails() })
        }
        return super.tapActionAtPoint(point, gesture: gesture, isEstimating: isEstimating)
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        return { [weak self] item, _, _, _, _, _ in
            let properties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: true, headerSpacing: 0,
                hidesBackground: .always, forceFullCorners: false, forceAlignment: .center)
            let gift = VeilGramGiftMessage(message: item.message, account: item.context.account.peerId)
            return (properties, nil, 260, { constrained, _ in
                return (min(260, constrained.width), { width in
                    let size = CGSize(width: width, height: 300)
                    return (size, { _, _, _ in
                        guard let self, let gift else { return }
                        self.item = item
                        let card: VeilGramGiftCard
                        if let current = self.card {
                            card = current
                        } else {
                            card = VeilGramGiftCard(frame: .zero)
                            self.view.addSubview(card)
                            self.card = card
                        }
                        card.frame = CGRect(x: 0, y: 3, width: size.width, height: size.height - 6)
                        card.update(context: item.context, message: item.message, gift: gift)
                    })
                })
            })
        }
    }
}

private final class VeilGramGiftCard: UIView {
    private final class CachedGift {
        let gift: StarGift
        init(_ gift: StarGift) { self.gift = gift }
    }
    private static let artworkCache: NSCache<NSString, CachedGift> = {
        let cache = NSCache<NSString, CachedGift>()
        cache.countLimit = 128
        return cache
    }()
    private let gradient = CAGradientLayer()
    private let fallback = UILabel()
    private let title = UILabel()
    private let caption = UILabel()
    private let button = UILabel()
    private let art = ComponentView<Empty>()
    private let artLoad = MetaDisposable()
    private let legacyLoad = MetaDisposable()
    private var sourceKey: String?
    private var context: AccountContext?
    private var resolved: StarGift?
    private var artworkKey: String?
    var collectibleLink: String? {
        guard case let .unique(gift)? = self.resolved else { return nil }
        return "https://t.me/nft/" + gift.slug
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = true
        self.clipsToBounds = true
        self.layer.cornerRadius = 22
        self.layer.cornerCurve = .continuous
        self.layer.borderWidth = 0
        self.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        self.gradient.colors = [UIColor.systemIndigo.withAlphaComponent(0.22).cgColor,
            UIColor.secondarySystemBackground.cgColor]
        self.gradient.startPoint = CGPoint(x: 0, y: 0)
        self.gradient.endPoint = CGPoint(x: 1, y: 1)
        self.layer.addSublayer(self.gradient)
        self.fallback.text = "🎁"
        self.fallback.font = .systemFont(ofSize: 51)
        self.fallback.textAlignment = .center
        self.title.textColor = .label
        self.title.font = .systemFont(ofSize: 17, weight: .semibold)
        self.title.textAlignment = .center
        self.title.numberOfLines = 2
        self.caption.text = "Визуальный подарок"
        self.caption.font = .systemFont(ofSize: 13)
        self.caption.textColor = .secondaryLabel
        self.caption.textAlignment = .center
        self.addSubview(self.fallback)
        self.addSubview(self.title)
        self.addSubview(self.caption)
        self.button.text = "Посмотреть"
        self.button.textAlignment = .center
        self.button.font = .systemFont(ofSize: 16, weight: .semibold)
        self.button.textColor = .label
        self.button.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.2)
        self.button.clipsToBounds = true
        self.button.layer.cornerRadius = 20
        self.addSubview(self.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(context: AccountContext, message: EngineRawMessage, gift: VeilGramGiftMessage) {
        let recipient = message.peers[message.id.peerId].map { EnginePeer($0).compactDisplayTitle } ?? ""
        let outgoing = message.author?.id == context.account.peerId
        let title = outgoing ? "Подарок для " + recipient : "Подарок для вас"
        self.title.text = title
        self.accessibilityLabel = title + ", визуальный подарок VeilGram"
        let key = gift.item ?? gift.legacyFile.map { "legacy:\($0.fileId.id)" }
        guard self.context !== context || self.sourceKey != key else { return }
        self.context = context
        self.sourceKey = key
        self.resolved = nil
        self.artLoad.set(nil)
        self.legacyLoad.set(nil)
        self.setNeedsLayout()

        if let item = gift.item {
            self.loadArt(context: context, item: item)
        } else if let file = gift.legacyFile {
            let reference = AnyMediaReference.message(message: MessageReference(message), media: file)
            let fetch = context.engine.resources.fetch(reference: reference.resourceReference(file.resource),
                userLocation: .peer(message.id.peerId), userContentType: .other).start()
            let data = (context.engine.resources.data(id: EngineMediaResource.Id(file.resource.id))
                |> filter { $0.isComplete }
                |> take(1)
                |> deliverOnMainQueue).start(next: { [weak self] resource in
                    guard let self, self.sourceKey == key,
                          let bytes = try? Data(contentsOf: URL(fileURLWithPath: resource.path), options: .mappedIfSafe),
                          let item = VeilGramGiftLink.readLegacy(bytes) else { return }
                    self.loadArt(context: context, item: item)
                })
            self.legacyLoad.set(ActionDisposable {
                fetch.dispose()
                data.dispose()
            })
        }
    }

    func presentDetails() {
        guard var presenter = self.window?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let detail = UIAlertController(title: self.title.text, message: "Визуальный подарок VeilGram. Он отображается в витрине получателя.", preferredStyle: .alert)
        detail.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        presenter.present(detail, animated: true)
    }

    private func loadArt(context: AccountContext, item: String) {
        self.artworkKey = item
        if let cached = Self.artworkCache.object(forKey: item as NSString) {
            self.show(cached.gift)
            return
        }
        if item.hasPrefix("nft:") {
            let slug = String(item.dropFirst(4))
            self.artLoad.set((context.engine.payments.getUniqueStarGift(slug: slug) |> deliverOnMainQueue)
                .start(next: { [weak self] value in self?.show(.unique(value)) }))
        } else if let id = Int64(item.dropFirst(5)) {
            self.artLoad.set((context.engine.payments.cachedStarGifts() |> deliverOnMainQueue)
                .start(next: { [weak self] values in
                    if let gift = values?.first(where: {
                        if case let .generic(value) = $0 { return value.id == id }
                        return false
                    }) {
                        self?.show(gift)
                    }
                }))
        }
    }

    private func show(_ gift: StarGift) {
        self.resolved = gift
        if let key = self.artworkKey {
            Self.artworkCache.setObject(CachedGift(gift), forKey: key as NSString)
        }
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.gradient.frame = self.bounds
        let side = max(0, min(166, self.bounds.width - 28))
        let artFrame = CGRect(x: floor((self.bounds.width - side) / 2), y: 12, width: side, height: side)
        self.fallback.frame = artFrame
        self.title.frame = CGRect(x: 12, y: 183, width: max(0, self.bounds.width - 24), height: 42)
        self.caption.frame = CGRect(x: 0, y: 222, width: self.bounds.width, height: 18)
        self.button.frame = CGRect(x: 42, y: 247, width: max(0, self.bounds.width - 84), height: 40)
        guard let context = self.context, let gift = self.resolved, side > 0 else {
            self.fallback.isHidden = false
            self.art.view?.isHidden = true
            return
        }
        let presentation = context.sharedContext.currentPresentationData.with { $0 }
        let subject: GiftItemComponent.Subject
        switch gift {
        case let .generic(value): subject = .starGift(gift: value, price: "")
        case let .unique(value): subject = .uniqueGift(gift: value, price: nil)
        }
        let _ = self.art.update(transition: .immediate,
            component: AnyComponent(GiftItemComponent(context: context, theme: presentation.theme, strings: presentation.strings,
                subject: subject, mode: .profile, cornerRadius: 16, allowAnimations: !UIAccessibility.isReduceMotionEnabled)),
            environment: {}, containerSize: artFrame.size)
        if let view = self.art.view {
            if view.superview == nil { self.addSubview(view) }
            view.frame = artFrame
            view.isHidden = false
            self.fallback.isHidden = true
        }
    }

    deinit {
        self.artLoad.dispose()
        self.legacyLoad.dispose()
    }
}
