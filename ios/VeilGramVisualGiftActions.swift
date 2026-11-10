import TelegramCore

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
