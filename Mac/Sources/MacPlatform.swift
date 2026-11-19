import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CryptoKit
import ZIPFoundation

func isCancelledRequest(_ error: Error) -> Bool {
    error is CancellationError || ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled)
}
enum MediaFailure: LocalizedError {
    case unsupportedPhoto
    var errorDescription: String? { "This file cannot be displayed. You can download its original." }
}
enum MacFiles {
    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FoteraMac", isDirectory: true) }
    static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func originalDigests(_ file: URL) throws -> Set<String> {
        var result: Set<String> = [try digest(file)]
        guard let archive = try? Archive(url: file, accessMode: .read, pathEncoding:nil) else { return result }
        var total: UInt64 = 0
        for entry in archive where entry.type == .file {
            total += entry.uncompressedSize
            guard total <= 2_000_000_000 else { throw ConnectionError.invalidResponse }
            var hash = SHA256()
            _ = try archive.extract(entry, consumer: { data in try Task.checkCancellation(); hash.update(data: data) })
            result.insert(hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        return result
    }
    static func decode(_ data: Data, edge: Int = 1600) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceCreateThumbnailWithTransform:true, kCGImageSourceThumbnailMaxPixelSize:edge] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
// The Mac transfer queue owns disk bodies produced by the shared DSM request builder.
enum BackgroundUploads {
    static func bodyURL(_ id: UUID) -> URL { MacFiles.support.appendingPathComponent("Bodies/" + id.uuidString) }
}
enum UploadPreviews {
    struct Preview { let field: String; let data: Data }
    static func generate(source: URL, filename: String) async throws -> [Preview] {
        try await Task.detached(priority: .utility) {
            let image: CGImage
            if let source = CGImageSourceCreateWithURL(source as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceCreateThumbnailWithTransform:true, kCGImageSourceThumbnailMaxPixelSize:1280] as CFDictionary) { image = cg }
            else if ["mov","mp4","m4v"].contains((filename as NSString).pathExtension.lowercased()) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width:1280,height:1280)
                guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return [] }; image = cg
            } else { return [] }
            return try [("thumb_sm",240),("thumb_m",320),("thumb_xl",1280)].map { field, edge in
                try Task.checkCancellation()
                let ratio = min(1, Double(edge)/Double(max(image.width,image.height)))
                let width = max(1,Int((Double(image.width)*ratio).rounded())), height = max(1,Int((Double(image.height)*ratio).rounded()))
                guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ConnectionError.invalidResponse }
                context.interpolationQuality = .high; context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
                let data = NSMutableData()
                guard let output = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil), let cg = context.makeImage() else { throw ConnectionError.invalidResponse }
                CGImageDestinationAddImage(output,cg,[kCGImageDestinationLossyCompressionQuality:0.9] as CFDictionary)
                guard CGImageDestinationFinalize(output) else { throw ConnectionError.invalidResponse }
                return Preview(field:field,data:data as Data)
            }
        }.value
    }
}
actor OfflineVault {
    static let shared = OfflineVault()
    private func path(account: String, shared: Bool, id: Int) -> URL { MacFiles.support.appendingPathComponent("Originals/" + LibraryCache.hash(account + "|\(shared)|\(id)")) }
    func originalURL(account: String, shared: Bool, id: Int) -> URL? {
        let file = path(account:account,shared:shared,id:id); return FileManager.default.fileExists(atPath:file.path) ? file : nil
    }
    func copyOriginal(account: String, photo: RemotePhoto, shared: Bool) throws -> URL? {
        guard let file = originalURL(account:account,shared:shared,id:photo.id) else { return nil }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension((photo.filename as NSString).pathExtension)
        try FileManager.default.copyItem(at:file,to:target); return target
    }
    func save(_ source: URL, account: String, shared: Bool, id: Int) throws {
        let target = path(account:account,shared:shared,id:id)
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        guard !FileManager.default.fileExists(atPath:target.path) else { return }
        try FileManager.default.copyItem(at:source,to:target)
    }
}
