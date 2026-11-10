import Foundation

public struct VeilGramGiftMessage {
    public let item: String?
    public let legacyFile: TelegramMediaFile?
    public let title: String

    public init?(message: EngineRawMessage, account: EnginePeer.Id) {
        let peer = message.id.peerId
        let caption = VeilGramGiftLink.caption
        guard peer.namespace == Namespaces.Peer.CloudUser, peer != account,
              message.id.namespace == Namespaces.Message.Cloud || message.id.namespace == Namespaces.Message.Local,
              let author = message.author?.id, author == peer || author == account,
              message.forwardInfo == nil, message.minAutoremoveOrClearTimeout == nil else { return nil }
        if message.text.hasPrefix(caption + "\n"), message.media.isEmpty,
           let entities = message.attributes.compactMap({ $0 as? TextEntitiesMessageAttribute }).first?.entities {
            for entity in entities where entity.range == 0..<caption.utf16.count {
                if case let .TextUrl(url) = entity.type, let item = VeilGramGiftLink.item(from: url) {
                    self.item = item
                    self.legacyFile = nil
                    self.title = String(message.text.dropFirst(caption.count + 1).prefix(80))
                    return
                }
            }
        }
        guard message.text.hasPrefix(caption + ": "), message.media.count == 1,
              let file = message.media.first as? TelegramMediaFile, file.fileName == "VeilGram.vggift",
              file.mimeType == "application/octet-stream", let size = file.size, size > 4, size <= 2052 else { return nil }
        self.item = nil
        self.legacyFile = file
        self.title = String(message.text.dropFirst(caption.count + 2).prefix(80))
    }
}
