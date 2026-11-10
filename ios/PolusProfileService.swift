import Foundation
import CryptoKit
import TelegramCore

struct PolusDecoration: Decodable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let colors: [String]
}

struct PolusCatalog: Decodable, Sendable {
    let banners: [PolusDecoration]
}

struct PolusAvatarMedia: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case photo, gif, video
    }

    let id: String
    let kind: Kind
}

struct PolusProfile: Codable, Equatable, Sendable {
    var banner: String?
    var media: PolusAvatarMedia?
    var color: String?
    var status: String?
    var member: Bool?
    var received: [String]?

    static let empty = PolusProfile()
}

enum PolusProfileService {
    private struct LocalProfile: Codable {
        let profile: PolusProfile
    }

    private struct Packet: Codable {
        let version: Int
        let profile: PolusProfile?
        let gift: String?
    }

    enum ServiceError: LocalizedError {
        case invalidMedia
        case insufficientStars
        case couldNotSend

        var errorDescription: String? {
            switch self {
            case .invalidMedia: return "Не удалось открыть баннер. Выбери фото, GIF или видео размером до 8 МБ."
            case .insufficientStars: return "Не хватает визуальных звёзд VeilGram."
            case .couldNotSend: return "Не удалось добавить сообщение в очередь Telegram. Проверь личный чат с получателем."
            }
        }
    }

    static let catalog = (try? JSONDecoder().decode(PolusCatalog.self, from: Data(PolusBuildConfig.catalogJSON.utf8))) ?? PolusCatalog(banners: [])
    static let mediaLimit = 8 * 1024 * 1024
    static let packetLimit = mediaLimit + 2052

    private static func localKey(_ account: String) -> String { "polus.profile.\(account)" }

    private static func showcaseKey(_ account: String) -> String { "polus.showcase.\(account)" }

    static func showcase(_ account: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: self.showcaseKey(account)) ?? []
    }

    static func setShowcase(_ gifts: [String], account: String) {
        UserDefaults.standard.set(gifts, forKey: self.showcaseKey(account))
    }

    static func mergeGifts(_ first: [String], _ second: [String]) -> [String] {
        var seen = Set<String>()
        return Array((first + second).filter { self.giftCost($0) != nil && seen.insert($0).inserted }.prefix(18))
    }

    static func localProfile(_ account: String) -> PolusProfile {
        guard let data = UserDefaults.standard.data(forKey: self.localKey(account)),
              let record = try? JSONDecoder().decode(LocalProfile.self, from: data) else { return .empty }
        return record.profile
    }

    @MainActor
    static func save(account: String, profile: PolusProfile) {
        let style = PolusProfile(banner: profile.banner, media: profile.media, color: profile.color, status: profile.status)
        let data = try? JSONEncoder().encode(LocalProfile(profile: style))
        UserDefaults.standard.set(data, forKey: self.localKey(account))
    }

    static func giftCost(_ id: String) -> Int? {
        VeilGramGiftLink.cost(id)
    }

    static func collectibleSlug(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.giftCost("nft:" + value) != nil { return value }
        let urlText = value.lowercased().hasPrefix("t.me/") ? "https://" + value : value
        guard let url = URLComponents(string: urlText) else { return nil }
        let slug: String?
        if url.scheme == "tg", url.host?.lowercased() == "nft" {
            slug = url.queryItems?.first(where: { $0.name == "slug" })?.value
        } else if url.scheme == "https", url.host?.lowercased() == "t.me" {
            let path = url.path.split(separator: "/")
            slug = path.count == 2 && path.first == "nft" ? String(path[1]) : nil
        } else {
            slug = nil
        }
        guard let slug, self.giftCost("nft:" + slug) != nil else { return nil }
        return slug
    }

    static func packet(profile: PolusProfile?, gift: String?, account: String) throws -> Data {
        var style = profile
        style?.member = nil
        let header = try JSONEncoder().encode(Packet(version: 2, profile: style, gift: gift))
        guard header.count <= 2048 else { throw ServiceError.invalidMedia }
        var length = UInt32(header.count).bigEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(header)
        if let media = style?.media {
            data.append(try self.mediaData(account: account, peer: account, media: media))
        }
        return data
    }

    static func readPacket(_ data: Data, account: String, peer: String) -> (profile: PolusProfile?, gift: String?)? {
        guard data.count > 4, data.count <= self.packetLimit else { return nil }
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 2048, data.count >= length + 4,
              let packet = try? JSONDecoder().decode(Packet.self, from: Data(data.dropFirst(4).prefix(length))),
              packet.version == 2 else { return nil }
        let bytes = data.dropFirst(length + 4)
        if var style = packet.profile, packet.gift == nil {
            if let media = style.media {
                guard !bytes.isEmpty, bytes.count <= self.mediaLimit,
                      self.mediaId(Data(bytes), kind: media.kind) == media.id,
                      (try? self.writeMedia(Data(bytes), account: account, peer: peer, media: media)) != nil else { return nil }
            } else if !bytes.isEmpty {
                return nil
            }
            style.banner = self.catalog.banners.first(where: { $0.id == style.banner })?.id
            if let color = style.color, color.range(of: "^[A-F0-9]{6}$", options: .regularExpression) == nil {
                style.color = nil
            }
            if let status = style.status, status.unicodeScalars.count > 32 || status.rangeOfCharacter(from: .controlCharacters) != nil {
                style.status = nil
            }
            style.member = true
            style.received = style.received.map { self.mergeGifts($0, []) }
            return (style, nil)
        }
        if packet.profile == nil, let gift = packet.gift, self.giftCost(gift) != nil, bytes.isEmpty {
            return (nil, gift)
        }
        return nil
    }

    private static func mediaId(_ data: Data, kind: PolusAvatarMedia.Kind) -> String {
        var hash = SHA256()
        hash.update(data: Data(kind.rawValue.utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func mediaPath(_ account: String, peer: String, media: PolusAvatarMedia) throws -> URL {
        let pattern = "^[1-9][0-9]{0,15}$"
        guard account.range(of: pattern, options: .regularExpression) != nil,
              peer.range(of: pattern, options: .regularExpression) != nil,
              media.id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ServiceError.invalidMedia }
        let directory: FileManager.SearchPathDirectory = account == peer ? .applicationSupportDirectory : .cachesDirectory
        let folder = try FileManager.default.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VeilGramAvatar", isDirectory: true).appendingPathComponent(account, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(account == peer ? media.id : "\(peer)-\(media.id)")
    }

    private static func writeMedia(_ data: Data, account: String, peer: String, media: PolusAvatarMedia) throws {
        try data.write(to: self.mediaPath(account, peer: peer, media: media), options: .atomic)
    }

    static func storeMedia(_ data: Data, kind: PolusAvatarMedia.Kind, account: String) throws -> PolusAvatarMedia {
        guard !data.isEmpty, data.count <= self.mediaLimit else { throw ServiceError.invalidMedia }
        let media = PolusAvatarMedia(id: self.mediaId(data, kind: kind), kind: kind)
        try self.writeMedia(data, account: account, peer: account, media: media)
        return media
    }

    static func mediaData(account: String, peer: String, media: PolusAvatarMedia) throws -> Data {
        try Data(contentsOf: self.mediaPath(account, peer: peer, media: media))
    }
}
