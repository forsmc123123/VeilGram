import UIKit

struct PatchAppearance: Sendable {
    var name = ""
    var icon120: Data?
    var icon180: Data?

    @MainActor
    mutating func selectIcon(_ bytes: Data) throws {
        guard let image = UIImage(data: bytes), image.size.width > 0, image.size.height > 0 else {
            throw InstallerFailure.message("Не удалось открыть изображение иконки.")
        }
        func render(_ size: CGFloat) -> Data {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).pngData { context in
                UIColor(red: 0.12, green: 0.08, blue: 0.20, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: size, height: size))
                let scale = max(size / image.size.width, size / image.size.height)
                let width = image.size.width * scale
                let height = image.size.height * scale
                image.draw(in: CGRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
            }
        }
        icon120 = render(120)
        icon180 = render(180)
    }

    func apply(to app: URL, info: inout [String: Any]) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { info["CFBundleDisplayName"] = String(title.prefix(40)) }
        if let icon120, let icon180 {
            try icon120.write(to: app.appendingPathComponent("VeilGramCustomIcon@2x.png"))
            try icon180.write(to: app.appendingPathComponent("VeilGramCustomIcon@3x.png"))
            var icons = info["CFBundleIcons"] as? [String: Any] ?? [:]
            icons["CFBundlePrimaryIcon"] = ["CFBundleIconFiles": ["VeilGramCustomIcon"], "UIPrerenderedIcon": true]
            info["CFBundleIcons"] = icons
            info["CFBundleIconFiles"] = ["VeilGramCustomIcon"]
            info.removeValue(forKey: "CFBundleIconName")
        }
        if !title.isEmpty || icon120 != nil {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            try data.write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
        }
    }
}
