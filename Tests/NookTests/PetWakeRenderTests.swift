import AppKit
import XCTest
@testable import Nook

/// The cat waking up, and the sad cat, drawn for reviewing by eye (set NOOK_RENDER_DIR): contact sheets of the frames, at the notch's size and in the header, and a GIF of the waking.
@MainActor
final class PetWakeRenderTests: XCTestCase {
    private func directory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the cat.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return URL(fileURLWithPath: directory)
    }

    func testRenderTheWaking() throws {
        let dir = try directory()
        try PetRender.film("wake", to: dir, header: true, headerWidth: 70, every: 0.25, compactOnly: true, gif: true) { _ in
            PetRender.sample(PetAnimation.wakeLength()) { PetAnimation.waking(u: $0, time: 3 + $0, sleptAge: 9, sleptLength: 1e9) }
        }
        try PetRender.film("wake-light", to: dir, header: true, headerWidth: 70, every: 0.25, compactOnly: true, gif: true) { _ in
            PetRender.sample(PetAnimation.wakeLength(squint: 1)) { PetAnimation.waking(u: $0, time: 3 + $0, sleptAge: 9, sleptLength: 1e9, squint: 1) }
        }
    }

    func testRenderTheSadCat() throws {
        let dir = try directory()
        try PetRender.film("sad", to: dir, header: true, headerWidth: 70, every: 0.5, compactOnly: true, gif: true) { _ in
            PetRender.sample(9) { PetAnimation.sad(time: $0, amount: PetAnimation.sadAmount(at: $0)) }
        }
    }
}
