import AppKit
import UniformTypeIdentifiers

/// Tệp đính kèm trong khung chat: ảnh gửi thẳng cho Claude xem (khối image base64),
/// tệp khác gửi đường dẫn để Claude tự đọc bằng tool Read.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let isImage: Bool
    let thumbnail: NSImage?

    var name: String { url.lastPathComponent }

    static func == (a: Attachment, b: Attachment) -> Bool { a.id == b.id }

    static func make(_ url: URL) -> Attachment {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let isImage = type?.conforms(to: .image) == true
        var thumb: NSImage?
        if isImage, let img = NSImage(contentsOf: url) {
            thumb = img
        } else {
            thumb = NSWorkspace.shared.icon(forFile: url.path)
        }
        return Attachment(url: url, isImage: isImage && thumb != nil, thumbnail: thumb)
    }

    /// Ảnh trong clipboard (vd. ⌘⇧⌃4) → lưu thành PNG tạm để đính kèm.
    static func fromPasteboard() -> [Attachment] {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(make)
        }
        guard let img = NSImage(pasteboard: pb), let url = saveTemp(img) else { return [] }
        return [make(url)]
    }

    static func saveTemp(_ img: NSImage) -> URL? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = SessionManager.supportDir.appendingPathComponent("attachments")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("anh-\(f.string(from: Date()))-\(UUID().uuidString.prefix(4)).png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }

    /// Khối nội dung gửi cho Claude. Ảnh lớn được thu nhỏ (cạnh dài ≤ 1600px, JPEG) cho vừa giới hạn API.
    func contentBlock() -> [String: Any]? {
        guard isImage, let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ext = url.pathExtension.lowercased()
        let raw = (try? Data(contentsOf: url)) ?? Data()
        let longSide = max(cg.width, cg.height)
        // PNG/JPEG/GIF/WebP nhỏ thì gửi nguyên; còn lại (HEIC, TIFF, ảnh to) đổi sang JPEG.
        if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext), longSide <= 1600, raw.count < 3_500_000 {
            let mime = ext == "jpg" ? "image/jpeg" : "image/\(ext)"
            return ["type": "image", "source": ["type": "base64", "media_type": mime, "data": raw.base64EncodedString()]]
        }
        let scale = min(1, 1600 / Double(longSide))
        let w = Int(Double(cg.width) * scale), h = Int(Double(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let jpeg = NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) ?? Data()
        return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }
}
