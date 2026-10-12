import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// A card with a sixth tab, as it may have one day. Its name is as long as a tab's is likely to get, so the bar is tried at its worst.
enum SixTabs: String, CaseIterable, SettingsTabItem {
    case island, pet, permissions, privacy, screen, notifications
    var id: String { rawValue }
    private var known: SettingsTab? { SettingsTab(rawValue: rawValue) }
    var title: String { known?.title ?? "Notificaciones" }
    var symbol: String { known?.symbol ?? "bell" }
    var attentionNote: String { known?.attentionNote ?? "Faltan los avisos" }
}

/// The selection of a bar that stands on its own, in a model the test can move (as the card's model is moved by a tab, or by "Permisos…" in the menu).
@MainActor
final class SettingsTabBarSelection<Tab: SettingsTabItem>: ObservableObject {
    @Published var tab: Tab
    init(_ tab: Tab) { self.tab = tab }
}

/// A bar on its own, as the card holds it: 16 pt from the card's edges, on the card's surface, `width` wide.
struct SettingsTabBarHarness<Tab: SettingsTabItem>: View {
    var tabs: [Tab]
    @ObservedObject var selection: SettingsTabBarSelection<Tab>
    var attention: Set<Tab> = []
    var width: CGFloat = SettingsCard.width

    var body: some View {
        SettingsTabBar(tabs: tabs, selection: Binding(get: { selection.tab }, set: { selection.tab = $0 }), attention: attention)
            .padding(.horizontal, 16).padding(.vertical, 6).frame(width: width).background(Color(white: 0.105)).environment(\.colorScheme, .dark)
    }
}

/// Finds the tabs of a bar in a window by what VoiceOver calls them: where they are, what they say, and pressing them (which is what a click or Space does,
/// without sending an event to anything). SwiftUI builds its accessibility nodes only when assistive technology is on: the lookup tells the app it is.
@MainActor
enum SettingsTabBarProbe {
    /// An offscreen window (borderless, so it can never take the keyboard) holding `view` at its fitting size, laid out and settled.
    static func window(_ view: some View, width: CGFloat) -> NSWindow {
        let host = NSHostingView(rootView: view.environment(\.nookTintedGlass, false))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        window.setContentSize(host.frame.size)
        window.contentView = host
        window.orderFrontRegardless()
        told.remove(window.windowNumber)
        settle()
        return window
    }

    static func settle(_ seconds: TimeInterval = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// The windows (by number) that have been told that assistive technology is on, so a test that looks at six tabs waits for the nodes once, not six times.
    private static var told: Set<Int> = []

    /// The accessibility node with this label, nil when there is none.
    static func node(_ label: String, in window: NSWindow) -> NSObject? {
        if !told.contains(window.windowNumber) {
            _ = AccessibilityLookup.center(of: label, in: window)
            told.insert(window.windowNumber)
        }
        func search(_ element: AnyObject) -> NSObject? {
            guard let node = element as? NSObject else { return nil }
            if node.value(forKey: "accessibilityLabel") as? String == label, let frame = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, frame != .zero { return node }
            for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { if let found = search(child as AnyObject) { return found } }
            return nil
        }
        for child in window.contentView?.accessibilityChildren() ?? [] { if let found = search(child as AnyObject) { return found } }
        return nil
    }

    /// Where the element with this label stands in the window, from its top left; nil when there is none.
    static func frame(_ label: String, in window: NSWindow) -> NSRect? {
        guard let node = node(label, in: window), let host = window.contentView,
              let screen = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else { return nil }
        let inWindow = window.convertFromScreen(screen)
        return NSRect(x: inWindow.minX, y: host.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    /// What VoiceOver says after the label.
    static func value(_ label: String, in window: NSWindow) -> String? { node(label, in: window)?.value(forKey: "accessibilityValue") as? String }

    /// What VoiceOver offers as help for the element with this label: SwiftUI's tooltip (`.help`) of the element.
    static func help(_ label: String, in window: NSWindow) -> String? { node(label, in: window)?.value(forKey: "accessibilityHelp") as? String }

    /// Whether VoiceOver says the element with this label is selected.
    static func isSelected(_ label: String, in window: NSWindow) -> Bool? {
        (node(label, in: window)?.value(forKey: "accessibilitySelected") as? NSNumber)?.boolValue
    }

    /// The press VoiceOver (or Voice Control, or Space on a focused tab) makes. Returns whether the element took it.
    @discardableResult
    static func press(_ label: String, in window: NSWindow) -> Bool {
        let press = NSSelectorFromString("accessibilityPerformPress")
        guard let node = node(label, in: window), node.responds(to: press) else { return false }
        // The method answers with a BOOL, which is not an object: the result is left unread (the tests look at what the press did).
        _ = node.perform(press)
        settle(0.3)
        return true
    }

    /// The width a name takes when it is the selected tab's.
    static func titleWidth(_ title: String) -> CGFloat {
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).size().width
    }

    /// What the selected tab needs: its symbol, the gap, its whole name, and its padding on both sides.
    static func selectedNeed(_ title: String) -> CGFloat {
        SettingsTabMetrics.symbol + SettingsTabMetrics.gap + titleWidth(title) + 2 * SettingsTabMetrics.padding
    }

    // MARK: The switch, frame by frame

    /// One frame of a bar as its window draws it, and how long after the selection changed it was taken.
    struct Frame {
        var millis: Int
        var image: NSBitmapImageRep
    }

    /// The bar's switch from `from` to `to` as its window draws it: a frame before, about one every 20 ms for `frames` of them, and one once everything has settled
    /// (`millis` 9999). The window is offscreen but ordered in, so what animates does.
    static func film<Tab: SettingsTabItem>(tabs: [Tab], from: Tab, to: Tab, attention: Set<Tab>, width: CGFloat, frames count: Int = 16) throws -> [Frame] {
        let selection = SettingsTabBarSelection(from)
        let host = NSHostingView(rootView: SettingsTabBarHarness(tabs: tabs, selection: selection, attention: attention, width: width))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: host.frame.width, height: host.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        settle()
        func grab(_ millis: Int) throws -> Frame {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return Frame(millis: millis, image: rep)
        }
        var film = [try grab(0)]
        let start = CACurrentMediaTime()
        selection.tab = to
        for _ in 0..<count {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            film.append(try grab(Int(((CACurrentMediaTime() - start) * 1000).rounded())))
        }
        settle(0.4)
        film.append(try grab(9999))
        return film
    }

    /// Where the pill is in a frame, in points from the bar's left: the first and last pixel of the row through the middle of the bar that are mint and not grey. Nil when there is none.
    static func pill(in frame: Frame) -> ClosedRange<CGFloat>? {
        let rep = frame.image
        let scale = CGFloat(rep.pixelsWide) / max(rep.size.width, 1)
        let y = rep.pixelsHigh / 2
        var first: Int?, last: Int?
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.greenComponent - color.redComponent > 0.04 { first = first ?? x; last = x }
        }
        guard let first, let last else { return nil }
        return (CGFloat(first) / scale)...(CGFloat(last + 1) / scale)
    }
}
