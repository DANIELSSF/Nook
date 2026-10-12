import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The question before quitting as the island draws it (`QuitPromptView.swift`): that it is there while the model asks, that «Quedarme» and «Salir» answer it, that Enter and Esc mean
/// «Quedarme» whatever had the keyboard, that the keyboard goes back to where it was, and the sad cat's picture for the plain alert. The events go to a window of the test's own that is
/// never made key.
@MainActor
final class QuitPromptTests: XCTestCase {
    private func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: The words

    func testTheHintSaysCommandQAgainQuits() {
        XCTAssertEqual(QuitCopy.hint, "Pulsa ⌘Q otra vez para salir")
        XCTAssertEqual(QuitCopy.stay, "Quedarme")
        XCTAssertEqual(QuitCopy.quit, "Salir")
        XCTAssertTrue(QuitCopy.spoken.contains(QuitAlert.question) && QuitCopy.spoken.contains(QuitAlert.detail), "VoiceOver gets the question and what it means")
    }

    // MARK: The keys

    private func key(_ code: UInt16, _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testEnterReturnAndEscapeMeanQuedarmeAndNothingElseDoes() {
        let view = QuitKeyView(frame: .zero)
        var stays = 0
        view.onStay = { stays += 1 }
        view.keyDown(with: key(36, "\r")); view.keyDown(with: key(76, "\u{3}")); view.keyDown(with: key(53, "\u{1b}"))
        XCTAssertEqual(stays, 3)
        view.keyDown(with: key(0, "a")); view.keyDown(with: key(49, " ")); view.keyDown(with: key(48, "\t"))
        XCTAssertEqual(stays, 3, "no other key is for the island behind the question: it does not reach the message field")
        view.cancelOperation(nil)
        XCTAssertEqual(stays, 4, "Esc as the system sends it (cancelOperation:) is the same")
    }

    func testItDrawsNothingAndTakesNoClicks() {
        let view = QuitKeyView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(view.hitTest(NSPoint(x: 50, y: 50)))
        XCTAssertTrue(view.acceptsFirstResponder)
    }

    /// The question takes the keyboard from the message field, and gives it back to the field when it goes.
    func testTheKeyboardGoesToTheQuestionAndBackToWhatHadIt() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let question = QuitKeyView(frame: NSRect(x: 0, y: 100, width: 100, height: 100))
        window.contentView?.addSubview(question)
        wait(0.2)
        XCTAssertTrue(window.firstResponder === question, "the question has the keyboard")
        question.removeFromSuperview()
        XCTAssertTrue(window.firstResponder === field, "and the field has it again")
        window.close()
    }

    // MARK: In the island

    @MainActor private struct Rig {
        var model: AppModel
        var window: NSPanel
        var host: NSHostingView<NookPanel>
        var quits: Counter
        var quitHost: RecordingQuitHost
    }
    private final class Counter { var count = 0 }

    private func rig() -> Rig {
        let name = "nook-quit-prompt-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.animations = false
        model.neckWithoutWindow = 32
        model.expanded = true; model.islandContentVisible = true
        let quitHost = RecordingQuitHost()
        model.quitPromptHost = quitHost
        let quits = Counter()
        model.terminateApp = { quits.count += 1 }
        let size = model.islandSize
        let host = NSHostingView(rootView: NookPanel(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSPanel(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        addTeardownBlock { window.close() }
        wait(0.4)
        return Rig(model: model, window: window, host: host, quits: quits, quitHost: quitHost)
    }

    private func click(_ label: String, in rig: Rig) throws {
        let point = try XCTUnwrap(AccessibilityLookup.center(of: label, in: rig.window), "\(label) is on screen")
        let location = NSPoint(x: point.x, y: rig.host.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            rig.window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        wait(0.3)
    }

    func testTheQuestionIsOnTheIslandWhileTheModelAsksAndGoneWhenItStopsAsking() throws {
        let rig = rig()
        XCTAssertNil(AccessibilityLookup.center(of: "Quedarme", in: rig.window), "nothing is asked yet")
        XCTAssertEqual(rig.model.shouldTerminate(.user), .terminateCancel)
        wait(0.5)
        XCTAssertNotNil(AccessibilityLookup.center(of: "Quedarme", in: rig.window))
        XCTAssertNotNil(AccessibilityLookup.center(of: "Salir", in: rig.window))
        rig.model.answerQuit(false)
        wait(0.5)
        XCTAssertNil(AccessibilityLookup.center(of: "Quedarme", in: rig.window), "answered: the card goes")
    }

    func testQuedarmeAnswersStayAndSalirQuits() throws {
        let rig = rig()
        _ = rig.model.shouldTerminate(.user)
        wait(0.5)
        try click("Quedarme", in: rig)
        XCTAssertNil(rig.model.quitPrompt)
        XCTAssertEqual(rig.quitHost.dismissed, 1, "«Quedarme» is the answer «stay»")
        XCTAssertEqual(rig.quits.count, 0)

        _ = rig.model.shouldTerminate(.user)
        wait(0.5)
        try click("Salir", in: rig)
        XCTAssertNil(rig.model.quitPrompt)
        XCTAssertEqual(rig.quits.count, 1, "«Salir» quits")
    }

    func testEnterAndEscapeAnswerStayWhateverHadTheKeyboard() throws {
        for (name, code, characters) in [("Enter", UInt16(36), "\r"), ("Esc", UInt16(53), "\u{1b}")] {
            let rig = rig()
            _ = rig.model.shouldTerminate(.user)
            wait(0.6)
            XCTAssertTrue(rig.window.firstResponder is QuitKeyView, "\(name): the question has the keyboard, not the message field")
            rig.window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
            wait(0.3)
            XCTAssertNil(rig.model.quitPrompt, "\(name) answers stay")
            XCTAssertEqual(rig.quitHost.dismissed, 1)
            XCTAssertEqual(rig.quits.count, 0, "and quits nothing")
        }
    }

    // MARK: The picture

    func testTheSadCatIsAPictureOfTheCatOnTheIslandsBlack() throws {
        let image = QuitAlert.icon()
        XCTAssertEqual(image.size, NSSize(width: 128, height: 128))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        func brightness(_ x: Int, _ y: Int) -> Double { Double(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? -1) }
        func alpha(_ x: Int, _ y: Int) -> Double { Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? -1) }
        XCTAssertEqual(alpha(1, 1), 0, accuracy: 0.05, "the corner of the rounded square is clear")
        XCTAssertEqual(alpha(rep.pixelsWide / 2, 8), 1, accuracy: 0.05)
        XCTAssertLessThan(brightness(rep.pixelsWide / 2, 8), 0.1, "the island's black")
        var white = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where alpha(x, y) > 0.9 { total += 1; if brightness(x, y) > 0.9 { white += 1 } }
        }
        XCTAssertGreaterThan(Double(white) / Double(max(total, 1)), 0.08, "the cat is on it")
        XCTAssertLessThan(Double(white) / Double(max(total, 1)), 0.5)
    }

    /// The cat is in the middle of its picture: its limp tail and its ears leave about the same room on each side, and none of it touches the edge.
    func testTheSadCatSitsInTheMiddleOfItsPicture() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(QuitAlert.icon().tiffRepresentation)))
        var left = rep.pixelsWide, right = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9, color.brightnessComponent > 0.9, color.saturationComponent < 0.2 else { continue }
                left = min(left, x); right = max(right, x)
            }
        }
        let width = Double(rep.pixelsWide)
        let roomLeft = Double(left) / width, roomRight = Double(rep.pixelsWide - 1 - right) / width
        XCTAssertGreaterThan(roomLeft, 0.1, "the tail does not touch the edge")
        XCTAssertGreaterThan(roomRight, 0.1, "nor do the ears")
        XCTAssertEqual(roomLeft, roomRight, accuracy: 0.08, "about the same room either side: \(roomLeft) and \(roomRight)")
    }
}
