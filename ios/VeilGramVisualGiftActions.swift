import Foundation
import SwiftSignalKit
import TelegramCore

public struct VeilGramPeerStyle: Codable, Equatable, Sendable {
    public let member: Bool?
    public let color: String?

    public init(member: Bool?, color: String?) {
        self.member = member
        self.color = color
    }
}

public enum VeilGramPeerStyleCache {
    private static let changed = Notification.Name("VeilGramPeerStyleChanged")

    private static func key(account: String, peer: String) -> String {
        "veilgram.peerStyle.\(account).\(peer)"
    }

    public static func get(account: String, peer: String) -> VeilGramPeerStyle? {
        guard let data = UserDefaults.standard.data(forKey: self.key(account: account, peer: peer)) else { return nil }
        return try? JSONDecoder().decode(VeilGramPeerStyle.self, from: data)
    }

    public static func put(account: String, peer: String, style: VeilGramPeerStyle) {
        guard self.get(account: account, peer: peer) != style else { return }
        let key = self.key(account: account, peer: peer)
        UserDefaults.standard.set(try? JSONEncoder().encode(style), forKey: key)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: self.changed, object: key)
        }
    }

    public static func observe(context: AccountContext, peer: EnginePeer.Id, updated: @escaping () -> Void) -> Disposable {
        let account = String(context.account.peerId.id._internalGetInt64Value())
        let key = self.key(account: account, peer: String(peer.id._internalGetInt64Value()))
        let observer = NotificationCenter.default.addObserver(forName: self.changed, object: nil, queue: .main) { value in
            if value.object as? String == key { updated() }
        }
        Task { @MainActor in
            await VeilGramPeerStyleLoader.load?(context, peer)
        }
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    }
}

@MainActor
public enum VeilGramPeerStyleLoader {
    public static var load: ((AccountContext, EnginePeer.Id) async -> Void)?
}

@MainActor
public struct VeilGramVisualGiftActions {
    public static var current: VeilGramVisualGiftActions?

    public let balance: (AccountContext) -> Int
    public let topUp: @MainActor (AccountContext) -> Void
    public let cost: (StarGift) -> Int
    public let send: @MainActor (AccountContext, EnginePeer.Id, StarGift) async throws -> Void

    public init(balance: @escaping (AccountContext) -> Int, topUp: @escaping @MainActor (AccountContext) -> Void,
                cost: @escaping (StarGift) -> Int,
                send: @escaping @MainActor (AccountContext, EnginePeer.Id, StarGift) async throws -> Void) {
        self.balance = balance
        self.topUp = topUp
        self.cost = cost
        self.send = send
    }
}
