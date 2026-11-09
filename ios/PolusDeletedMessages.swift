import Foundation
import Postbox

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
