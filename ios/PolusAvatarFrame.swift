import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

func polusColor(_ hex: String) -> UIColor {
    guard let value = UInt32(hex, radix: 16) else { return .systemIndigo }
    return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
}

enum PolusFrameImport {
    enum ImportError: LocalizedError {
        case unsupported
        case unreadable
        case sourceTooLarge
        case cannotCompress

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Этот формат не удалось открыть. Попробуй GIF, MP4 или MOV."
            case .unreadable: return "Не удалось получить оригинал файла. Если он в iCloud, сначала скачай его на iPhone."
            case .sourceTooLarge: return "Исходный файл больше 256 МБ. Выбери файл поменьше."
            case .cannotCompress: return "Не удалось подготовить баннер до 8 МБ. Попробуй другой файл."
            }
        }
    }

    static let inputLimit = 256 * 1024 * 1024

    static func prepare(_ url: URL, type: UTType? = nil, account: String) async throws -> PolusAvatarMedia {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        if let size = values.fileSize {
            guard size > 0 else { throw ImportError.unreadable }
            guard size <= self.inputLimit else { throw ImportError.sourceTooLarge }
        }
        let fileType = type ?? values.contentType ?? UTType(filenameExtension: url.pathExtension)
        if fileType?.conforms(to: .movie) != true, fileType?.conforms(to: .video) != true,
           let image = CGImageSourceCreateWithURL(url as CFURL, nil),
           let identifier = CGImageSourceGetType(image), CGImageSourceGetCount(image) > 0 {
            if (identifier as String) == UTType.gif.identifier {
                let bytes: Data
                if let size = values.fileSize, size <= PolusProfileService.mediaLimit,
                   CGImageSourceGetCount(image) <= PolusGIF.frameLimit {
                    bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                } else if let normalized = PolusGIF.normalize(image, byteLimit: PolusProfileService.mediaLimit) {
                    bytes = normalized
                } else {
                    throw ImportError.cannotCompress
                }
                return try PolusProfileService.storeMedia(bytes, kind: .gif, account: account)
            }
            guard let photo = self.thumbnail(image, index: 0, maximumSize: 640),
                  let data = photo.jpegData(compressionQuality: 0.86) else { throw ImportError.unsupported }
            return try PolusProfileService.storeMedia(data, kind: .photo, account: account)
        }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ImportError.unsupported }
        let movie = AVMutableComposition()
        guard let video = movie.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ImportError.unsupported
        }
        let range = try await track.load(.timeRange)
        guard range.duration.seconds.isFinite, range.duration.seconds > 0 else { throw ImportError.unsupported }
        let duration = CMTimeMinimum(range.duration, CMTime(seconds: 12, preferredTimescale: 600))
        try video.insertTimeRange(CMTimeRange(start: range.start, duration: duration), of: track, at: .zero)
        video.preferredTransform = try await track.load(.preferredTransform)
        for preset in [AVAssetExportPreset640x480, AVAssetExportPresetLowQuality] {
            let data: Data
            do {
                data = try await self.export(movie, preset: preset)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            return try PolusProfileService.storeMedia(data, kind: .video, account: account)
        }
        throw ImportError.cannotCompress
    }

    private static func export(_ asset: AVAsset, preset: String) async throws -> Data {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset),
              exporter.supportedFileTypes.contains(.mp4) else { throw ImportError.unsupported }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if #available(iOS 18.0, *) {
            try await exporter.export(to: temporary, as: .mp4)
        } else {
            exporter.outputURL = temporary
            exporter.outputFileType = .mp4
            await exporter.export()
            guard exporter.status == .completed else { throw ImportError.unsupported }
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= PolusProfileService.mediaLimit else { throw ImportError.cannotCompress }
        return try Data(contentsOf: temporary)
    }

    private static func thumbnail(_ image: CGImageSource, index: Int, maximumSize: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(image, index, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    static func photoImage(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return self.thumbnail(source, index: 0, maximumSize: 640)
    }

    static func gifImage(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= PolusGIF.frameLimit else { return nil }
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        for index in 0..<count {
            guard let image = self.thumbnail(source, index: index, maximumSize: 256) else { return nil }
            let ticks = max(1, Int((PolusGIF.delay(source, index: index) / 0.04).rounded()))
            frames.append(contentsOf: repeatElement(image, count: ticks))
            duration += Double(ticks) * 0.04
        }
        return count == 1 ? frames.first : UIImage.animatedImage(with: frames, duration: duration)
    }
}

final class PolusProfileBanner: UIView {
    private let gradient = CAGradientLayer()
    private let image = UIImageView()
    private let shade = CAGradientLayer()
    private let fade = CAGradientLayer()
    private let videoLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var videoFile: URL?
    private var loadTask: Task<Void, Never>?
    private var selection: PolusProfile = .empty

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.clipsToBounds = true
        self.gradient.startPoint = CGPoint(x: 0, y: 0.1)
        self.gradient.endPoint = CGPoint(x: 1, y: 0.85)
        self.layer.addSublayer(self.gradient)
        self.image.contentMode = .scaleAspectFill
        self.image.clipsToBounds = true
        self.addSubview(self.image)
        self.videoLayer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(self.videoLayer)
        self.shade.colors = [UIColor.black.withAlphaComponent(0.5).cgColor, UIColor.clear.cgColor,
            UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.72).cgColor]
        self.shade.locations = [0, 0.27, 0.50, 1]
        self.layer.addSublayer(self.shade)
        self.fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        self.fade.locations = [0, 0.74, 1]
        self.layer.mask = self.fade
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.gradient.frame = self.bounds
        self.image.frame = self.bounds
        self.videoLayer.frame = self.bounds
        self.shade.frame = self.bounds
        self.fade.frame = self.bounds
    }

    func apply(_ profile: PolusProfile, account: String, peer: String) {
        guard profile.banner != self.selection.banner || profile.media != self.selection.media else { return }
        self.selection = profile
        self.loadTask?.cancel()
        self.player?.pause()
        self.looper = nil
        self.player = nil
        self.videoLayer.player = nil
        if let file = self.videoFile { try? FileManager.default.removeItem(at: file) }
        self.videoFile = nil
        self.image.stopAnimating()
        self.image.animationImages = nil
        self.image.image = nil
        let preset = PolusProfileService.catalog.banners.first(where: { $0.id == profile.banner })
        self.gradient.colors = (preset?.colors.map(polusColor) ?? [.systemPurple, .systemIndigo]).map { $0.cgColor }
        guard let media = profile.media else { return }
        self.loadTask = Task { @MainActor [weak self] in
            guard let data = try? PolusProfileService.mediaData(account: account, peer: peer, media: media),
                  !Task.isCancelled, let self else { return }
            switch media.kind {
            case .photo:
                self.image.image = PolusFrameImport.photoImage(data)
            case .gif:
                if let animation = PolusFrameImport.gifImage(data) {
                    self.image.image = animation.images?.first ?? animation
                    self.image.animationImages = animation.images
                    self.image.animationDuration = animation.duration
                    self.updatePlayback()
                }
            case .video:
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                do {
                    try data.write(to: url, options: .atomic)
                    let player = AVQueuePlayer()
                    player.isMuted = true
                    self.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
                    self.videoFile = url
                    self.player = player
                    self.videoLayer.player = player
                    self.updatePlayback()
                } catch {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    func setVisible(_ visible: Bool) {
        guard self.isHidden == visible else { return }
        self.isHidden = !visible
        self.updatePlayback()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.updatePlayback()
    }

    private func updatePlayback() {
        if self.window != nil && !self.isHidden && !UIAccessibility.isReduceMotionEnabled {
            self.player?.play()
            if self.image.animationImages != nil, !self.image.isAnimating {
                self.image.startAnimating()
            }
        } else {
            self.player?.pause()
            self.image.stopAnimating()
        }
    }

    deinit {
        self.loadTask?.cancel()
        if let file = self.videoFile { try? FileManager.default.removeItem(at: file) }
    }
}
