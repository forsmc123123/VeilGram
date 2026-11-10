import Foundation
import Postbox

public struct PolusDeletedRecord: Codable {
    public let id: MessageId
    public let chat: String
    public let timestamp: Int32
    public let text: String

    fileprivate init(message: Message, transaction: Transaction) {
        self.id = message.id
        self.timestamp = message.timestamp
        self.text = message.text.isEmpty ? "Вложение" : message.text
        switch transaction.getPeer(message.id.peerId) {
        case let user as TelegramUser:
            let name = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
            self.chat = name.isEmpty ? "Личный чат" : name
        case let group as TelegramGroup:
            self.chat = group.title
        case let channel as TelegramChannel:
            self.chat = channel.title
        default:
            self.chat = "Чат"
        }
    }
}

public enum PolusDeletedArchive {
    private static let key = ItemCacheEntryId(collectionId: -101, key: ValueBoxKey("veilgram.deleted.v1"))
    private static let limit = 1000

    private struct Archive: Codable {
        var migrated = false
        var records: [PolusDeletedRecord] = []
    }

    public static func records(transaction: Transaction) -> [PolusDeletedRecord] {
        var archive = self.read(transaction)
        if !archive.migrated {
            var previous: [PolusDeletedRecord] = []
            let indexed = Set(archive.records.map(\.id))
            for peer in transaction.chatListGetAllPeerIds() {
                transaction.withAllMessages(peerId: peer, namespace: Namespaces.Message.Cloud) { message in
                    if message.isPolusDeleted, !indexed.contains(message.id) {
                        previous.append(PolusDeletedRecord(message: message, transaction: transaction))
                    }
                    return true
                }
            }
            previous.sort { $0.timestamp < $1.timestamp }
            archive.records = Array((previous + archive.records).suffix(self.limit))
            archive.migrated = true
            self.write(archive, transaction)
        }
        return Array(archive.records.reversed())
    }

    fileprivate static func record(_ message: Message, transaction: Transaction) {
        var archive = self.read(transaction)
        guard !archive.records.contains(where: { $0.id == message.id }) else { return }
        archive.records.append(PolusDeletedRecord(message: message, transaction: transaction))
        if archive.records.count > self.limit {
            archive.records.removeFirst(archive.records.count - self.limit)
        }
        self.write(archive, transaction)
    }

    private static func read(_ transaction: Transaction) -> Archive {
        transaction.retrieveItemCacheEntry(id: self.key)?.get(Archive.self) ?? Archive()
    }

    private static func write(_ archive: Archive, _ transaction: Transaction) {
        if let entry = CodableEntry(archive) {
            transaction.putItemCacheEntry(id: self.key, entry: entry)
        }
    }
}

extension ReplayContext {
    /// Keeps a local copy of an eligible incoming message during the remote deletion transaction.
    func keepPolusDeletedMessage(_ id: MessageId) -> Bool {
        guard id.namespace == Namespaces.Message.Cloud,
              let message = self.transaction.getMessage(id) else { return false }
        if message.isPolusDeleted { return true }

        guard message.flags.contains(.Incoming), !message.flags.contains(.CopyProtected),
              id.peerId != self.accountPeerId, message.author?.id != self.accountPeerId,
              !message.attributes.contains(where: { attribute in
                  attribute is AutoremoveTimeoutMessageAttribute || attribute is AutoclearTimeoutMessageAttribute ||
                  attribute is EphemeralMessageAttribute || attribute is EphemeralReplacementMessageAttribute ||
                  attribute is EphemeralOutgoingMessageAttribute
              }) else { return false }

        let cachedData = self.transaction.getPeerCachedData(peerId: id.peerId)
        let timer: CachedPeerAutoremoveTimeout?
        switch self.transaction.getPeer(id.peerId) {
        case is TelegramUser:
            timer = (cachedData as? CachedUserData)?.autoremoveTimeout
        case let group as TelegramGroup:
            guard !group.flags.contains(.copyProtectionEnabled) else { return false }
            timer = (cachedData as? CachedGroupData)?.autoremoveTimeout
        case let channel as TelegramChannel:
            guard case .group = channel.info, channel.participationStatus == .member,
                  !channel.flags.contains(.copyProtectionEnabled) else { return false }
            timer = (cachedData as? CachedChannelData)?.autoremoveTimeout
        default:
            return false
        }
        if case let .known(value)? = timer, (value?.effectiveValue ?? 0) > 0 { return false }

        // Preserve text, captions and ordinary attachments. Live or ephemeral content follows Telegram's deletion.
        guard !message.text.isEmpty || !message.media.isEmpty,
              message.media.allSatisfy({ media in
                  if let file = media as? TelegramMediaFile {
                      return !file.isSticker && !file.isAnimatedSticker && !file.isInstantVideo
                  }
                  return media is TelegramMediaImage || media is TelegramMediaWebpage
              }) else { return false }

        PolusDeletedArchive.record(message, transaction: self.transaction)
        let attributes = message.attributes.filter { $0 is TextEntitiesMessageAttribute }
            + [NotificationInfoMessageAttribute(flags: [.polusDeleted, .muted])]
        self.transaction.updateMessage(id) { _ in
            .update(StoreMessage(
                id: id, customStableId: nil, globallyUniqueId: message.globallyUniqueId, groupingKey: nil,
                threadId: message.threadId, timestamp: message.timestamp, flags: [.Incoming], tags: [],
                globalTags: [], localTags: [], forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init),
                authorId: message.author?.id, text: message.text, attributes: attributes, media: message.media
            ))
        }
        return true
    }
}
