import Foundation

enum PolusBuildConfig {
    static let catalogJSON = """
    {"banners":[{"id":"aurora","title":"Aurora","symbol":"✦","colors":["8877FF","6699FF"]}]}
    """
}

@main
struct CheckProfilePackets {
    static func main() throws {
        let account = "120000000000001"
        let peer = "120000000000002"
        let style = PolusProfile(banner: "aurora", color: "C4A7FF", status: "Привет", received: ["nft:PlushPepe-42", "invalid"])
        let packet = try PolusProfileService.packet(profile: style, gift: nil, account: account)
        let decoded = PolusProfileService.readPacket(packet, account: account, peer: peer)?.profile
        precondition(decoded?.member == true && decoded?.banner == "aurora" && decoded?.color == "C4A7FF")
        precondition(decoded?.status == "Привет" && decoded?.received == ["nft:PlushPepe-42"])
        precondition(PolusProfileService.readPacket(Data(packet.dropLast()), account: account, peer: peer) == nil)
        precondition(PolusProfileService.readPacket(packet + Data([0]), account: account, peer: peer) == nil)

        let gift = try PolusProfileService.packet(profile: nil, gift: "nft:PlushPepe-42", account: account)
        precondition(PolusProfileService.readPacket(gift, account: account, peer: peer)?.gift == "nft:PlushPepe-42")
        let ambiguous = try PolusProfileService.packet(profile: style, gift: "gift:123", account: account)
        precondition(PolusProfileService.readPacket(ambiguous, account: account, peer: peer) == nil)
        let bogusGift = try PolusProfileService.packet(profile: nil, gift: "gift:abc", account: account)
        precondition(PolusProfileService.readPacket(bogusGift, account: account, peer: peer) == nil)
        print("VeilGram exchange packets passed")
    }
}
