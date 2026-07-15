import AVFoundation
import Foundation
import UIKit

// MARK: - Plan BS P2/P3 — pure broadcast support types

/// Output geometry for the RTMP encoder (was hardcoded 720×1280 portrait).
enum BroadcastGeometry {
    static func outputSize(orientation: String) -> (width: Int, height: Int) {
        orientation == "landscape" ? (1280, 720) : (720, 1280)
    }

    /// Aspect-fit rect for drawing a frame into the output buffer (black letterbox around
    /// it). The previous stretch-to-fill distorted any source whose aspect didn't match.
    static func aspectFitRect(imageSize: CGSize, in canvas: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvas.width - size.width) / 2,
            y: (canvas.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// Monotonic sample-time clock for the broadcast audio track: mic buffers arrive without
/// usable timeline context, so the stream's audio PTS is a running sample count.
struct BroadcastAudioClock {
    private(set) var sampleTime: Int64 = 0

    /// Returns the presentation sample-time for a buffer of `frames`, then advances.
    mutating func take(frames: AVAudioFrameCount) -> Int64 {
        let time = sampleTime
        sampleTime += Int64(frames)
        return time
    }
}

/// A selectable broadcast video source.
enum BroadcastVideoSource: String, CaseIterable, Codable {
    case glasses
    case phoneBack = "phone_back"
    case phoneFront = "phone_front"

    var displayLabel: String {
        switch self {
        case .glasses: return "Glasses"
        case .phoneBack: return "Phone (Back)"
        case .phoneFront: return "Phone (Front)"
        }
    }

    var isPhone: Bool { self != .glasses }

    var phonePosition: AVCaptureDevice.Position? {
        switch self {
        case .glasses: return nil
        case .phoneBack: return .back
        case .phoneFront: return .front
        }
    }
}

/// Mid-stream source-switch state machine (pure). Debounces rapid switches so the RTMP
/// pipeline isn't churned, and remembers the active source for frame routing.
struct BroadcastSourceSelector {
    private(set) var active: BroadcastVideoSource
    let debounce: TimeInterval
    private var lastSwitch: Date?

    init(initial: BroadcastVideoSource, debounce: TimeInterval = 1.0) {
        self.active = initial
        self.debounce = debounce
    }

    /// Attempt a switch at `now`. Returns true if accepted (and applied).
    mutating func requestSwitch(to source: BroadcastVideoSource, now: Date) -> Bool {
        guard source != active else { return false }
        if let last = lastSwitch, now.timeIntervalSince(last) < debounce { return false }
        active = source
        lastSwitch = now
        return true
    }
}

/// Dual-capture picture-in-picture compositing (pure — UIGraphicsImageRenderer, CPU path,
/// preserving the broadcast pipeline's background safety; no Metal).
enum FrameCompositor {
    struct Spec {
        /// Inset width as a fraction of the canvas width.
        var insetFraction: CGFloat = 0.30
        var margin: CGFloat = 16
        var cornerRadius: CGFloat = 10
    }

    /// Bottom-trailing inset rect for a secondary frame of `insetSize` aspect on `canvas`.
    static func insetRect(canvas: CGSize, insetAspect: CGFloat, spec: Spec = Spec()) -> CGRect {
        guard canvas.width > 0, canvas.height > 0, insetAspect > 0 else { return .zero }
        let width = canvas.width * spec.insetFraction
        let height = width / insetAspect
        return CGRect(
            x: canvas.width - width - spec.margin,
            y: canvas.height - height - spec.margin,
            width: width,
            height: height
        )
    }

    /// Compose `inset` over `main` (canvas = main's size). Returns `main` untouched when
    /// there is no inset.
    static func compose(main: UIImage, inset: UIImage?, spec: Spec = Spec()) -> UIImage {
        guard let inset, inset.size.width > 0, inset.size.height > 0 else { return main }
        let canvas = main.size
        guard canvas.width > 0, canvas.height > 0 else { return main }

        let rect = insetRect(
            canvas: canvas,
            insetAspect: inset.size.width / inset.size.height,
            spec: spec
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            main.draw(in: CGRect(origin: .zero, size: canvas))
            let path = UIBezierPath(roundedRect: rect, cornerRadius: spec.cornerRadius)
            context.cgContext.saveGState()
            path.addClip()
            inset.draw(in: rect)
            context.cgContext.restoreGState()
        }
    }
}
