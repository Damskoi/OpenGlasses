import UIKit
import CoreGraphics

/// Cheap Laplacian-variance sharpness score, used ONLY to tailor the guidance message when OCR
/// finds nothing ("hold steady" for a blurry frame vs "move closer" for a sharp one with no
/// text) — never as a hard pre-OCR gate, since OCR's own result is the reliable quality signal.
enum ImageSharpness {

    /// Below this variance a frame reads as blurry. Rough and scene-dependent; deliberately
    /// conservative so a usable frame isn't nagged about quality.
    static let blurThreshold: Double = 90

    /// True only when the frame decodes AND scores below the blur threshold. Undecodable input
    /// answers false — we never claim "blurry" without evidence.
    static func isBlurry(_ data: Data) -> Bool {
        guard let score = score(data) else { return false }
        return score < blurThreshold
    }

    /// Variance of the Laplacian on a ~256px grayscale copy (higher = sharper), or nil when the
    /// image can't be decoded/rendered. Cheap enough to run on a failure path.
    static func score(_ data: Data) -> Double? {
        guard let cg = UIImage(data: data)?.cgImage, cg.width > 2, cg.height > 2 else { return nil }
        let targetW = 256
        let scale = Double(targetW) / Double(cg.width)
        let w = max(Int(Double(cg.width) * scale), 3)
        let h = max(Int(Double(cg.height) * scale), 3)

        var buffer = [UInt8](repeating: 0, count: w * h)
        let rendered: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered else { return nil }

        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Double(buffer[y * w + x])
                let lap = 4 * c
                    - Double(buffer[(y - 1) * w + x]) - Double(buffer[(y + 1) * w + x])
                    - Double(buffer[y * w + x - 1]) - Double(buffer[y * w + x + 1])
                sum += lap
                sumSq += lap * lap
                n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        return sumSq / n - mean * mean
    }
}
