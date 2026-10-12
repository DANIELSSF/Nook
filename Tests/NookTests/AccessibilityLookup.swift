import AppKit
import XCTest

/// Finds a control in a window by its accessibility label, so a test can press it where it is instead of guessing where a layout put it. SwiftUI builds
/// its accessibility nodes only when assistive technology is on, so the lookup tells the app it is (the nodes are SwiftUI's own, read by key).
enum AccessibilityLookup {
    /// The middle of the element with this label, from the window's top left (what a click takes); nil when there is none.
    @MainActor
    static func center(of label: String, in window: NSWindow) -> NSPoint? {
        NSApp.accessibilitySetValue(true as NSNumber, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func search(_ element: AnyObject) -> NSRect? {
            guard let node = element as? NSObject else { return nil }
            if node.value(forKey: "accessibilityLabel") as? String == label, let frame = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, frame != .zero { return frame }
            for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { if let found = search(child as AnyObject) { return found } }
            return nil
        }
        guard let host = window.contentView else { return nil }
        for child in host.accessibilityChildren() ?? [] {
            if let screen = search(child as AnyObject) {
                let inWindow = window.convertFromScreen(screen)
                return NSPoint(x: inWindow.midX, y: host.bounds.height - inWindow.midY)
            }
        }
        return nil
    }
}
