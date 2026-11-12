import Foundation
import TelegramCore

enum PolusBuildConfig {
    static let hostedURL = ""
    static let hostedCertificateHash = ""
}

@main
struct CheckProfilePackets {
    static func main() throws {
        let account = "120000000000001"
        #if os(iOS)
        self.checkHostedAddress(account: account)
        #endif
        let peer = "120000000000002"
        let style = PolusProfile(color: "C4A7FF", status: "Привет", received: ["nft:PlushPepe-42", "invalid"])
        let packet = try PolusProfileService.packet(profile: style, gift: nil, account: account)
        let decoded = PolusProfileService.readPacket(packet, account: account, peer: peer)?.profile
        precondition(decoded?.member == true && decoded?.color == "C4A7FF")
        precondition(decoded?.status == "Привет" && decoded?.received == ["nft:PlushPepe-42"])
        precondition(PolusProfileService.readPacket(Data(packet.dropLast()), account: account, peer: peer) == nil)
        precondition(PolusProfileService.readPacket(packet + Data([0]), account: account, peer: peer) == nil)

        let legacyHeader = Data(#"{"version":2,"profile":{"banner":"aurora","color":"C4A7FF"}}"#.utf8)
        var legacyLength = UInt32(legacyHeader.count).bigEndian
        let legacyPacket = withUnsafeBytes(of: &legacyLength) { Data($0) } + legacyHeader
        let legacyProfile = PolusProfileService.readPacket(legacyPacket, account: account, peer: peer)?.profile
        precondition(legacyProfile?.color == "C4A7FF" && legacyProfile?.media == nil)

        let gift = try PolusProfileService.packet(profile: nil, gift: "nft:PlushPepe-42", account: account)
        precondition(PolusProfileService.readPacket(gift, account: account, peer: peer)?.gift == "nft:PlushPepe-42")
        precondition(VeilGramGiftLink.readLegacy(gift) == "nft:PlushPepe-42")
        for item in ["gift:123", "nft:PlushPepe-42"] {
            let url = VeilGramGiftLink.url(for: item)!
            precondition(VeilGramGiftLink.item(from: url) == item)
            precondition(VeilGramGiftLink.item(from: url.replacingOccurrences(of: "core.telegram.org", with: "example.com")) == nil)
        }
        precondition(VeilGramGiftLink.url(for: "gift:0") == nil)
        precondition(VeilGramGiftLink.item(from: "https://core.telegram.org/api/gifts#veilgram-gift=gift%3A123") == "gift:123")
        let ambiguous = try PolusProfileService.packet(profile: style, gift: "gift:123", account: account)
        precondition(PolusProfileService.readPacket(ambiguous, account: account, peer: peer) == nil)
        precondition(VeilGramGiftLink.readLegacy(ambiguous) == nil)
        let bogusGift = try PolusProfileService.packet(profile: nil, gift: "gift:abc", account: account)
        precondition(PolusProfileService.readPacket(bogusGift, account: account, peer: peer) == nil)
        precondition(PolusProfileService.collectibleSlug("https://t.me/nft/PlushPepe-42?single") == "PlushPepe-42")
        precondition(PolusProfileService.collectibleSlug("tg://nft?slug=PlushPepe-42") == "PlushPepe-42")
        precondition(PolusProfileService.collectibleSlug("https://example.com/nft/PlushPepe-42") == nil)
        precondition(PolusProfileService.mergeGifts(["gift:123", "nft:PlushPepe-42"], ["gift:123", "invalid"]) ==
            ["gift:123", "nft:PlushPepe-42"])
        print("VeilGram exchange packets passed")
    }

    #if os(iOS)
    nonisolated private static func checkHostedAddress(account: String) {
        _ = PolusHostedProfiles.address(account: account)
    }
    #endif
}
