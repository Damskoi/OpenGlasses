import UIKit

/// Bounds an outgoing image so it stays within cloud vision-model limits before it is
/// base64-encoded into a request.
///
/// Anthropic's Messages API rejects an inline image larger than **5 MB** with a 400
/// (`image exceeds 5 MB maximum`) and downsamples anything over the model's long-edge
/// ceiling anyway. Ray-Ban glasses frames arrive small (the DAT stream is already downscaled), so
/// this never bites on the glasses path — but the iPhone-camera fallback
/// (`PhoneCameraSource`) and the photo tools capture at full sensor resolution, where a
/// 12 MP JPEG can clear 5 MB and fail the request on *exactly* the no-glasses path we rely
/// on for hardware-free development. This shrinks such images first; already-small images
/// pass through untouched, so the common glasses path pays nothing.
///
/// (Lesson cribbed from the `glassbridge` project's LEARNINGS.md, which hit this 400 with
/// native iPhone JPEGs.)
enum LLMImagePreparer {
    /// Longest edge (in pixels) we allow before downscaling. Current Claude models
    /// (Sonnet 5 / Opus 4.7+, incl. our default) support high-resolution vision up to
    /// 2576 px on the long edge; older models just downscale server-side, so this is safe
    /// across providers. Costs more image tokens than the old 1568 ceiling, but history
    /// pruning keeps only the latest image so the spend is bounded — and the extra fidelity
    /// is exactly what instrument_reading / text-in-scene captures need.
    static let maxLongEdge: CGFloat = 2576
    /// Byte ceiling for the encoded JPEG, kept comfortably under Anthropic's 5 MB hard limit.
    static let maxBytes = 4_500_000
    /// Frames below this long edge carry no usable content (the 1×1 placeholder failure mode).
    static let minLongEdge = 32

    /// True for undecodable or absurdly small images (long edge < `minLongEdge`). Such frames
    /// should be dropped before they are base64'd into a conversation and poison context —
    /// a degenerate placeholder frame reads as "the camera saw nothing" to the model.
    static func isDegenerate(_ data: Data) -> Bool {
        guard let image = UIImage(data: data), let cg = image.cgImage else { return true }
        return max(cg.width, cg.height) < minLongEdge
    }

    /// Returns JPEG `Data` within `maxLongEdge` / `maxBytes` where possible. Already-bounded
    /// input is returned unchanged (no re-encode). Undecodable input is returned as-is —
    /// there is nothing we can do, and failing open beats dropping the image.
    static func prepared(_ data: Data) -> Data {
        guard let image = UIImage(data: data), let cg = image.cgImage else { return data }
        let pxLongEdge = CGFloat(max(cg.width, cg.height))

        // Fast path: small enough in both dimensions and bytes — leave it exactly as-is.
        if data.count <= maxBytes && pxLongEdge <= maxLongEdge { return data }

        let resized = pxLongEdge > maxLongEdge ? downscale(cg, toLongEdge: maxLongEdge) : image

        // Step the JPEG quality down until the payload fits under the byte cap.
        for quality in [CGFloat(0.8), 0.65, 0.5, 0.35, 0.25] {
            if let jpeg = resized.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                return jpeg
            }
        }
        // Last resort: hardest compression even if still over (better than a guaranteed 400).
        return resized.jpegData(compressionQuality: 0.2) ?? data
    }

    private static func downscale(_ cg: CGImage, toLongEdge longEdge: CGFloat) -> UIImage {
        let pxLongEdge = CGFloat(max(cg.width, cg.height))
        let scale = longEdge / pxLongEdge
        let target = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // `target` is already in pixels; don't let Retina multiply it back up
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let source = UIImage(cgImage: cg)
        return renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: target)) }
    }
}
