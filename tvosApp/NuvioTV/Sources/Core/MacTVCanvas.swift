#if os(macOS)
import SwiftUI

/// Renders the UI on a fixed 1920×1080 canvas and scales that canvas to fit the
/// window.
///
/// Every layout in this app was written for tvOS, where the screen is always
/// 1920×1080 points. The sizes are absolute — 560pt cards, hero text measured
/// against a 1080p backdrop, fixed-height spacers — so they do not reflow. Give
/// those views a 900pt-wide window and you see slightly less than half the
/// intended layout: titles clipped, rows overlapping, large empty bands where
/// fixed spacers used to sit.
///
/// Scaling the whole canvas keeps every one of those layouts exactly as tuned on
/// the Apple TV and makes the window size irrelevant. `scaleEffect` is a
/// geometry transform rather than a bitmap resize, so text and artwork are still
/// rasterised at the device's real resolution and stay sharp.
struct MacTVCanvas<Content: View>: View {
    /// The tvOS screen this app's layouts are written against.
    static var canvasSize: CGSize { CGSize(width: 1920, height: 1080) }

    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let canvas = Self.canvasSize
            let scale = min(
                proxy.size.width / canvas.width,
                proxy.size.height / canvas.height
            )

            content()
                .frame(width: canvas.width, height: canvas.height)
                // scaleEffect does not change the reported layout size, so the
                // outer frame is what actually centres the scaled canvas in the
                // window and letterboxes the remainder.
                .scaleEffect(max(scale, 0.01), anchor: .center)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .background(Color.black)
    }
}

extension View {
    /// Wraps this view in the fixed tvOS canvas; a no-op anywhere but macOS.
    func macTVCanvas() -> some View {
        MacTVCanvas { self }
    }
}
#endif
