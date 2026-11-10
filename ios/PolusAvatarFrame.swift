import AVFoundation
import ImageIO
import UIKit

enum PolusFrameImport {
    enum ImportError: LocalizedError {
        case unsupported
        case tooLong

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Выберите фото, GIF или короткое видео. Готовая рамка должна помещаться в 8 МБ."
            case .tooLong: return "Выберите видео длительностью до 12 секунд."
            }
        }
    }

    static func prepare(_ url: URL, account: String) async throws -> PolusAvatarMedia {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 64 * 1024 * 1024 else { throw ImportError.unsupported }
        if let image = CGImageSourceCreateWithURL(url as CFURL, nil) {
            if CGImageSourceGetType(image) as String? == "com.compuserve.gif" {
                let bytes = try Data(contentsOf: url)
                guard bytes.count <= PolusProfileService.mediaLimit, self.gifImage(bytes) != nil else {
                    throw ImportError.unsupported
                }
                return try PolusProfileService.storeMedia(bytes, kind: .gif, account: account)
            }
            guard let photo = self.thumbnail(image, index: 0, maximumSize: 640),
                  let data = photo.jpegData(compressionQuality: 0.86) else { throw ImportError.unsupported }
            return try PolusProfileService.storeMedia(data, kind: .photo, account: account)
        }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ImportError.unsupported }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0, duration.seconds <= 12 else { throw ImportError.tooLong }
        let movie = AVMutableComposition()
        guard let video = movie.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ImportError.unsupported
        }
        let range = try await track.load(.timeRange)
        try video.insertTimeRange(range, of: track, at: .zero)
        video.preferredTransform = try await track.load(.preferredTransform)
        guard let exporter = AVAssetExportSession(asset: movie, presetName: AVAssetExportPreset640x480) else {
            throw ImportError.unsupported
        }
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
        return try PolusProfileService.storeMedia(Data(contentsOf: temporary), kind: .video, account: account)
    }

    private static func thumbnail(_ image: CGImageSource, index: Int, maximumSize: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(image, index, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    static func gifImage(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 120 else { return nil }
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        for index in 0..<count {
            guard let image = self.thumbnail(source, index: index, maximumSize: 256) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
            let timing = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let delay = (timing?[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue
                ?? (timing?[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue ?? 0.1
            let ticks = Int((max(0.04, min(delay, 1.0)) / 0.04).rounded())
            frames.append(contentsOf: repeatElement(image, count: ticks))
            duration += Double(ticks) * 0.04
        }
        return count == 1 ? frames.first : UIImage.animatedImage(with: frames, duration: duration)
    }
}

final class PolusAvatarFrame: UIView {
    private let gradient = CAGradientLayer()
    private let image = UIImageView()
    private let ring = CAShapeLayer()
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
        self.layer.mask = self.ring
        self.ring.fillRule = .evenOdd
        self.gradient.startPoint = CGPoint(x: 0, y: 0)
        self.gradient.endPoint = CGPoint(x: 1, y: 1)
        self.layer.addSublayer(self.gradient)
        self.image.contentMode = .scaleAspectFill
        self.image.clipsToBounds = true
        self.addSubview(self.image)
        self.videoLayer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(self.videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.gradient.frame = self.bounds
        self.image.frame = self.bounds
        self.videoLayer.frame = self.bounds
        self.ring.frame = self.bounds
        let path = UIBezierPath(ovalIn: self.bounds)
        path.append(UIBezierPath(ovalIn: self.bounds.insetBy(dx: 6, dy: 6)))
        self.ring.path = path.cgPath
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
        self.image.image = nil
        let preset = PolusProfileService.catalog.banners.first(where: { $0.id == profile.banner })
        self.gradient.colors = (preset?.colors.map(polusColor) ?? [.systemPurple, .systemIndigo]).map { $0.cgColor }
        guard let media = profile.media else { return }
        self.loadTask = Task { @MainActor [weak self] in
            guard let data = try? PolusProfileService.mediaData(account: account, peer: peer, media: media),
                  !Task.isCancelled, let self else { return }
            switch media.kind {
            case .photo:
                self.image.image = UIImage(data: data)
            case .gif:
                self.image.image = PolusFrameImport.gifImage(data)
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
        } else {
            self.player?.pause()
        }
    }

    deinit {
        self.loadTask?.cancel()
        if let file = self.videoFile { try? FileManager.default.removeItem(at: file) }
    }
}
