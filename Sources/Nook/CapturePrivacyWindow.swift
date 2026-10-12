import AppKit
import SwiftUI

/// Explicit Nook windows apply exclusion before ordering and before growth. Application-level
/// discovery supplements this for AppKit transients; it cannot guarantee their first frame.
class CapturePrivacyPanel: NSPanel {
    weak var capturePrivacy: CapturePrivacy? { didSet { capturePrivacy?.prepare(self) } }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { capturePrivacy?.prepare(self) }
        super.order(place, relativeTo: otherWin)
    }
    override func orderFrontRegardless() {
        capturePrivacy?.prepare(self)
        super.orderFrontRegardless()
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        capturePrivacy?.prepare(self)
        super.makeKeyAndOrderFront(sender)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        capturePrivacy?.prepare(self, size: CGSize(width: max(frame.width, frameRect.width), height: max(frame.height, frameRect.height)))
        super.setFrame(frameRect, display: flag)
        capturePrivacy?.prepare(self)
    }
}

/// The detached terminal has a normal title bar, so its entire window frame is excluded too.
final class CapturePrivacyWindow: NSWindow {
    weak var capturePrivacy: CapturePrivacy? { didSet { capturePrivacy?.prepare(self) } }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { capturePrivacy?.prepare(self) }
        super.order(place, relativeTo: otherWin)
    }
    override func orderFrontRegardless() {
        capturePrivacy?.prepare(self)
        super.orderFrontRegardless()
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        capturePrivacy?.prepare(self)
        super.makeKeyAndOrderFront(sender)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        capturePrivacy?.prepare(self, size: CGSize(width: max(frame.width, frameRect.width), height: max(frame.height, frameRect.height)))
        super.setFrame(frameRect, display: flag)
        capturePrivacy?.prepare(self)
    }
}

/// Registers a SwiftUI-created popover as soon as its content attaches to a window.
/// System-owned panels and some native menu windows remain outside this guarantee.
struct CapturePrivacyAttachment: NSViewRepresentable {
    let privacy: CapturePrivacy
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.privacy = privacy
        return view
    }
    func updateNSView(_ view: AttachmentView, context: Context) {
        view.privacy = privacy
        if let window = view.window { privacy.prepare(window) }
    }
    final class AttachmentView: NSView {
        weak var privacy: CapturePrivacy?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { privacy?.prepare(window) }
        }
    }
}
