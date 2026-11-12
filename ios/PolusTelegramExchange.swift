import Foundation
import AccountContext
import SwiftSignalKit
import TelegramCore

enum PolusTelegramExchange {
    private static let profileFile = "VeilGram.vgprofile"
    private static let mimeType = "application/octet-stream"
    private static let allowance = 1000

    private static func account(_ context: AccountContext) -> String {
        String(context.account.peerId.id._internalGetInt64Value())
    }

    private static func walletKey(_ context: AccountContext) -> String {
        "polus.visualStars.\(self.account(context))"
    }

    @MainActor
    static func register(context: AccountContext, notice: () -> Bool) async {
        await PolusHostedProfiles.register(account: self.account(context)) { username, recipient, text in
            let resolved = context.engine.peers.resolvePeerByName(name: username, referrer: nil, ageLimit: 0)
            |> filter { value in
                if case .result = value { return true }
                return false
            }
            guard case let .result(.user(user)?)? = await self.first(resolved),
                  user.botInfo == nil, user.id.namespace == Namespaces.Peer.CloudUser,
                  String(user.id.id._internalGetInt64Value()) == recipient,
                  !Task.isCancelled, notice() else { return false }
            let sent: Signal<Float, NoError> = standaloneSendMessage(account: context.account, peerId: user.id, text: text,
                attributes: [OutgoingContentInfoMessageAttribute(flags: .disableLinkPreviews)],
                media: nil, replyToMessageId: nil)
            |> filter { _ in false }
            |> then(.single(1))
            |> `catch` { _ in .single(0) }
            return await self.first(sent) == 1
        }
    }

    static func balance(_ context: AccountContext) -> Int {
        let spent = UserDefaults.standard.integer(forKey: self.walletKey(context))
        return max(0, self.allowance - spent)
    }

    @MainActor
    static func topUp(_ context: AccountContext) {
        UserDefaults.standard.removeObject(forKey: self.walletKey(context))
    }

    @MainActor
    static func sendGift(context: AccountContext, peer: EnginePeer.Id, item: String, title: String) async throws {
        guard let cost = PolusProfileService.giftCost(item), self.balance(context) >= cost else {
            throw PolusProfileService.ServiceError.insufficientStars
        }
        guard let url = VeilGramGiftLink.url(for: item) else { throw PolusProfileService.ServiceError.couldNotSend }
        let caption = VeilGramGiftLink.caption
        let entity = MessageTextEntity(range: 0..<caption.utf16.count, type: .TextUrl(url: url))
        let message = EnqueueMessage.message(text: caption + "\n" + title, attributes: [
            TextEntitiesMessageAttribute(entities: [entity]),
            OutgoingContentInfoMessageAttribute(flags: .disableLinkPreviews)
        ], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil,
            localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        let key = self.walletKey(context)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + cost, forKey: key)
        do {
            try await self.enqueueMessage(context: context, peer: peer, message: message)
        } catch {
            UserDefaults.standard.set(max(0, UserDefaults.standard.integer(forKey: key) - cost), forKey: key)
            throw error
        }
    }

    private static func enqueueMessage(context: AccountContext, peer: EnginePeer.Id, message: EnqueueMessage) async throws {
        guard peer.namespace == Namespaces.Peer.CloudUser, peer != context.account.peerId else {
            throw PolusProfileService.ServiceError.couldNotSend
        }
        guard let ids = await self.first(enqueueMessages(account: context.account, peerId: peer, messages: [message])),
              ids.contains(where: { $0 != nil }) else { throw PolusProfileService.ServiceError.couldNotSend }
    }

    @MainActor
    static func load(context: AccountContext, peer: EnginePeer.Id, onMetadata: ((PolusProfile) -> Void)? = nil) async -> PolusProfile {
        if peer == context.account.peerId {
            let gifts = await self.receivedGifts(context: context)
            var own = PolusProfileService.localProfile(self.account(context))
            own.member = true
            own.received = gifts
            return own
        }
        guard peer.namespace == Namespaces.Peer.CloudUser else { return .empty }
        let account = self.account(context)
        let peerKey = String(peer.id._internalGetInt64Value())
        if let cached = PolusHostedProfiles.cachedProfile(account: account, peer: peerKey) {
            onMetadata?(cached)
        }
        if var hosted = await PolusHostedProfiles.load(account: account, peer: peerKey) {
            if let media = hosted.media, PolusHostedProfiles.needsMedia(account: account, peer: peerKey, media: media) {
                var metadata = hosted
                metadata.media = nil
                onMetadata?(metadata)
                if !(await PolusHostedProfiles.fetchMedia(account: account, peer: peerKey, media: media)) {
                    hosted.media = nil
                }
            }
            return hosted
        }
        let matches = await self.search(context: context, location: .peer(peerId: peer, fromId: peer, tags: nil,
            reactions: nil, threadId: nil, minDate: nil, maxDate: nil))
        var member = false
        for message in matches {
            if message.author?.id == peer, VeilGramGiftMessage(message: message, account: context.account.peerId) != nil {
                member = true
                continue
            }
            guard let file = self.exchangeFile(message, context: context) else { continue }
            if file.fileName == self.profileFile,
               let packet = await self.packet(context: context, message: message, file: file), let profile = packet.profile {
                return profile
            }
        }
        return PolusProfile(member: member)
    }

    private static func receivedGifts(context: AccountContext) async -> [String] {
        let matches = await self.search(context: context, location: .general(scope: .privateChats, groupId: nil,
            tags: nil, minDate: nil, maxDate: nil, folderId: nil, communityId: nil))
        var gifts: [String] = []
        for message in matches {
            guard message.author?.id == message.id.peerId,
                  let delivery = VeilGramGiftMessage(message: message, account: context.account.peerId) else { continue }
            if let gift = delivery.item {
                gifts.append(gift)
            } else if let file = delivery.legacyFile,
                      let packet = await self.packet(context: context, message: message, file: file),
                      let gift = packet.gift {
                gifts.append(gift)
            }
            if gifts.count == 6 { break }
        }
        return gifts
    }

    private static func search(context: AccountContext, location: SearchMessagesLocation) async -> [EngineRawMessage] {
        let signal = context.engine.messages.searchMessages(location: location, query: "VeilGram", state: nil, limit: 50)
        guard let (result, _) = await self.first(signal) else { return [] }
        return result.messages.sorted { $0.timestamp == $1.timestamp ? $0.id.id > $1.id.id : $0.timestamp > $1.timestamp }
    }

    private static func exchangeFile(_ message: EngineRawMessage, context: AccountContext) -> TelegramMediaFile? {
        let peer = message.id.peerId
        guard peer.namespace == Namespaces.Peer.CloudUser, peer != context.account.peerId,
              message.id.namespace == Namespaces.Message.Cloud, message.author?.id == peer,
              message.forwardInfo == nil, message.minAutoremoveOrClearTimeout == nil else { return nil }
        return message.media.compactMap { $0 as? TelegramMediaFile }.first { file in
            guard let size = file.size, size > 4, file.mimeType == self.mimeType else { return false }
            return file.fileName == self.profileFile && size <= Int64(PolusProfileService.packetLimit)
        }
    }

    private static func packet(context: AccountContext, message: EngineRawMessage, file: TelegramMediaFile) async -> (profile: PolusProfile?, gift: String?)? {
        let reference = AnyMediaReference.message(message: MessageReference(message), media: file)
        let fetch = context.engine.resources.fetch(reference: reference.resourceReference(file.resource),
            userLocation: .peer(message.id.peerId), userContentType: .other).startStandalone()
        defer { fetch.dispose() }
        let dataSignal = context.engine.resources.data(id: EngineMediaResource.Id(file.resource.id)) |> filter { $0.isComplete }
        guard let resource = await self.first(dataSignal), let size = file.size else { return nil }
        let path = resource.path
        let account = self.account(context)
        let peer = String(message.id.peerId.id._internalGetInt64Value())
        return await Task.detached { () -> (profile: PolusProfile?, gift: String?)? in
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  bytes.count == Int(size) else { return nil }
            return PolusProfileService.readPacket(bytes, account: account, peer: peer)
        }.value
    }

    private static func first<Value>(_ signal: Signal<Value, NoError>) async -> Value? {
        await withCheckedContinuation { continuation in
            let disposable = MetaDisposable()
            var resolved = false
            func resolve(_ value: Value?) {
                guard !resolved else { return }
                resolved = true
                continuation.resume(returning: value)
                disposable.dispose()
            }
            disposable.set((signal |> deliverOnMainQueue |> take(1)).start(next: { resolve($0) }, completed: { resolve(nil) }))
            Queue.mainQueue().after(12.0) { resolve(nil) }
        }
    }
}

public enum VeilGramChatDecoration {
    @MainActor
    public static func registerHosting(context: AccountContext, notice: () -> Bool) async {
        await PolusTelegramExchange.register(context: context, notice: notice)
    }

    @MainActor
    public static func installGiftActions() {
        PolusHostedProfiles.styleUpdated = { account, peer, profile in
            VeilGramPeerStyleCache.put(account: account, peer: peer, style: VeilGramPeerStyle(member: profile.member, color: profile.color))
        }
        VeilGramPeerStyleLoader.load = { context, peer in
            guard peer.namespace == Namespaces.Peer.CloudUser else { return }
            let account = String(context.account.peerId.id._internalGetInt64Value())
            let peerKey = String(peer.id._internalGetInt64Value())
            if peer == context.account.peerId {
                let own = PolusProfileService.localProfile(account)
                VeilGramPeerStyleCache.put(account: account, peer: peerKey, style: VeilGramPeerStyle(member: true, color: own.color))
            } else {
                if let profile = await PolusHostedProfiles.load(account: account, peer: peerKey) {
                    await PolusHostedProfiles.prefetchMedia(account: account, peer: peerKey, profile: profile)
                }
            }
        }
        VeilGramVisualGiftActions.current = VeilGramVisualGiftActions(
            balance: PolusTelegramExchange.balance,
            topUp: PolusTelegramExchange.topUp,
            cost: { $0.polusCost },
            send: { context, peer, gift in
                try await PolusTelegramExchange.sendGift(context: context, peer: peer, item: gift.polusID, title: gift.polusTitle)
            })
    }

    @MainActor
    public static func load(context: AccountContext, peer: EnginePeer.Id) async -> (member: Bool, color: UInt32?) {
        let profile = await PolusTelegramExchange.load(context: context, peer: peer)
        return (profile.member == true, profile.color.flatMap { UInt32($0, radix: 16) })
    }
}
