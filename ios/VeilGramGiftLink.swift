import Foundation

public enum VeilGramGiftLink {
    public static let caption = "🎁 Визуальный подарок VeilGram"
    private static let marker = "veilgram-gift="

    public static func cost(_ item: String) -> Int? {
        if item.range(of: "^gift:[1-9][0-9]{0,18}$", options: .regularExpression) != nil { return 25 }
        if item.range(of: "^nft:[A-Za-z0-9]{1,60}-[1-9][0-9]{0,11}$", options: .regularExpression) != nil { return 100 }
        return nil
    }

    public static func url(for item: String) -> String? {
        guard self.cost(item) != nil else { return nil }
        return "https://core.telegram.org/api/gifts#" + self.marker + item
    }

    public static func item(from url: String) -> String? {
        guard url.utf8.count <= 180, let parts = URLComponents(string: url), parts.scheme == "https",
              parts.host == "core.telegram.org", parts.path == "/api/gifts", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil,
              let fragment = parts.fragment, fragment.hasPrefix(self.marker) else { return nil }
        let item = String(fragment.dropFirst(self.marker.count))
        return self.cost(item) != nil ? item : nil
    }

    public static func readLegacy(_ bytes: Data) -> String? {
        struct Packet: Decodable {
            let version: Int
            let gift: String
        }
        guard bytes.count > 4, bytes.count <= 2052 else { return nil }
        let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length == bytes.count - 4 else { return nil }
        let data = Data(bytes.dropFirst(4))
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields["profile"] == nil || fields["profile"] is NSNull,
              let packet = try? JSONDecoder().decode(Packet.self, from: data), packet.version == 2,
              self.cost(packet.gift) != nil else { return nil }
        return packet.gift
    }
}
