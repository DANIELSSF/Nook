import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// What the user can set about the cat: the defaults are the cat Nook always had, every choice is saved and read back, anything odd in
/// the stored values is the default, and the settings tab for it sits in the card with the others.
@MainActor
final class PetPreferencesTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "nook-pet-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Defaults

    func testTheDefaultsAreTheCatNookAlwaysHad() {
        let prefs = PetPreferences()
        XCTAssertEqual(prefs.coat, .snow, "white")
        XCTAssertEqual(prefs.accessory, .none)
        XCTAssertEqual(prefs.personality, .curious)
        XCTAssertEqual(prefs.activity, .normal)
        XCTAssertTrue(prefs.celebrates, "it cheered when a task finished before it could be turned off")
        XCTAssertTrue(prefs.isDefault)
        XCTAssertEqual(prefs.look, PetLook())
        XCTAssertEqual(PetPreferences.load(from: suite()), prefs, "A Mac that never opened the settings has the defaults.")
        // The plain cat at rest carries itself exactly as the old one did: nothing is added to its look.
        let sit = PetAnimation.sit(time: 3)
        XCTAssertEqual(PetLife.resting(sit, temperament: .of(prefs.personality)).distance(to: sit), 0, accuracy: 1e-9)
        XCTAssertEqual(PetTemperament.of(.curious), PetTemperament())
        // And it is painted white, like the old one: the pixels of the default look are the pixels the old painter made.
        XCTAssertEqual(PetCoat.snow.fill.red, 1); XCTAssertEqual(PetCoat.snow.fill.green, 1); XCTAssertEqual(PetCoat.snow.fill.blue, 1)
    }

    func testEveryChoiceHasItsOwnSpanishNameAndALine() {
        func distinct(_ titles: [String], _ what: String) {
            XCTAssertEqual(Set(titles).count, titles.count, "\(what) are told apart: \(titles)")
            for title in titles { XCTAssertFalse(title.isEmpty, what); XCTAssertLessThanOrEqual(title.count, 10, "\(title) fits a chip") }
        }
        distinct(PetPersonality.allCases.map(\.title), "personalities"); distinct(PetActivity.allCases.map(\.title), "activities")
        distinct(PetCoat.allCases.map(\.title), "coats"); distinct(PetAccessory.allCases.map(\.title), "accessories")
        XCTAssertEqual(PetPersonality.allCases.map(\.title), ["Curioso", "Juguetón", "Tranquilo", "Dormilón"])
        XCTAssertEqual(PetActivity.allCases.map(\.title), ["Ninguna", "Poca", "Normal", "Mucha"])
        XCTAssertEqual(PetCoat.allCases.map(\.title), ["Blanco", "Crema", "Gris", "Atigrado", "Naranja"])
        XCTAssertEqual(PetAccessory.allCases.map(\.title), ["Ninguno", "Cascabel", "Pajarita", "Gafas"])
        for personality in PetPersonality.allCases { XCTAssertGreaterThan(personality.blurb.count, 20); XCTAssertLessThanOrEqual(personality.blurb.count, 70, "one line of the card") }
        for activity in PetActivity.allCases { XCTAssertGreaterThan(activity.blurb.count, 10); XCTAssertLessThanOrEqual(activity.blurb.count, 60) }
    }

    func testActivityScalesThePausesAndNoneStartsNothing() {
        XCTAssertNil(PetActivity.none.pauseScale)
        XCTAssertEqual(PetActivity.normal.pauseScale, 1)
        let scales = [PetActivity.low, .normal, .high].map { $0.pauseScale! }
        XCTAssertEqual(scales, scales.sorted(by: >), "more activity, shorter pauses")
    }

    func testEveryCoatIsLightEnoughToReadOnTheIslandsBlack() {
        for coat in PetCoat.allCases {
            let c = coat.fill
            let luminance = 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
            XCTAssertGreaterThan(luminance, 0.62, "\(coat) is a light coat: a dark one would vanish in the notch")
            if let stripe = coat.stripe {
                let s = 0.2126 * stripe.red + 0.7152 * stripe.green + 0.0722 * stripe.blue
                XCTAssertLessThan(s, luminance - 0.12, "\(coat)'s stripes are darker than the coat")
            }
        }
        XCTAssertEqual(PetCoat.allCases.filter { $0.stripe != nil }, [.tabby, .ginger], "the two tabbies have stripes")
        XCTAssertEqual(Set(PetCoat.allCases.map { "\($0.fill)" }).count, PetCoat.allCases.count, "the coats differ")
    }

    // MARK: Persistence

    func testEveryChoiceIsSavedAndReadBack() {
        let defaults = suite()
        for personality in PetPersonality.allCases { for activity in PetActivity.allCases { for coat in PetCoat.allCases { for accessory in PetAccessory.allCases {
            let prefs = PetPreferences(personality: personality, activity: activity, coat: coat, accessory: accessory, celebrates: coat != .cream)
            prefs.save(to: defaults)
            XCTAssertEqual(PetPreferences.load(from: defaults), prefs, "\(prefs)")
        } } } }
    }

    func testNothingThatIsNotAChoiceSurvives() {
        let defaults = suite()
        defaults.set("furioso", forKey: PetPreferences.Key.personality)
        defaults.set(7, forKey: PetPreferences.Key.activity)
        defaults.set(["a"], forKey: PetPreferences.Key.coat)
        defaults.set("", forKey: PetPreferences.Key.accessory)
        defaults.set("yes", forKey: PetPreferences.Key.celebrates)
        XCTAssertEqual(PetPreferences.load(from: defaults), PetPreferences(), "an old build, a hand-edited plist: the defaults")
        defaults.set("sleepy", forKey: PetPreferences.Key.personality)
        XCTAssertEqual(PetPreferences.load(from: defaults).personality, .sleepy, "one good value is kept beside the bad ones")
        XCTAssertEqual(PetPreferences.load(from: defaults).coat, .snow)
    }

    func testTheModelSavesWhatChangesAndReadsItBack() {
        let defaults = suite()
        let model = AppModel(receivesSignals: false, defaults: defaults)
        XCTAssertEqual(model.pet, PetPreferences())
        XCTAssertNil(defaults.object(forKey: PetPreferences.Key.coat), "nothing is written until something is chosen")
        model.pet.coat = .ginger
        model.pet.personality = .playful
        XCTAssertEqual(defaults.string(forKey: PetPreferences.Key.coat), "ginger")
        XCTAssertEqual(defaults.string(forKey: PetPreferences.Key.personality), "playful")
        XCTAssertEqual(AppModel(receivesSignals: false, defaults: defaults).pet, model.pet, "the next launch has the cat as it was left")
        model.pet = PetPreferences()
        XCTAssertEqual(AppModel(receivesSignals: false, defaults: defaults).pet, PetPreferences(), "Restablecer goes back to the cat of always")
    }

    // MARK: The Mac's state

    func testLowPowerAndHeatAskForLessFromTheCat() {
        XCTAssertEqual(PetPower.of(lowPower: false, thermal: .nominal), .normal)
        XCTAssertEqual(PetPower.of(lowPower: false, thermal: .fair), .normal)
        XCTAssertEqual(PetPower.of(lowPower: true, thermal: .nominal), .saving)
        XCTAssertEqual(PetPower.of(lowPower: false, thermal: .serious), .saving)
        XCTAssertEqual(PetPower.of(lowPower: true, thermal: .serious), .saving)
        XCTAssertEqual(PetPower.of(lowPower: false, thermal: .critical), .minimal)
        XCTAssertEqual(PetPower.of(lowPower: true, thermal: .critical), .minimal)
        XCTAssertLessThan(PetPower.normal, .saving); XCTAssertLessThan(PetPower.saving, .minimal)
        _ = PetPowerMonitor.shared.state   // reads the real state once without crashing
    }

    func testTheHourOfTheDayTiltsTheCat() {
        XCTAssertEqual((0..<24).map { PetDayPart.of(hour: $0) }, [.night, .night, .night, .night, .night, .night, .morning, .morning, .morning, .morning, .day, .day, .day, .day, .day, .day, .day, .day, .evening, .evening, .evening, .evening, .evening, .night])
        let day = PetTemperament.of(.curious, dayPart: .day), night = PetTemperament.of(.curious, dayPart: .night)
        XCTAssertLessThan(night.eyeOpen, day.eyeOpen, "sleepier at night")
        XCTAssertLessThan(night.fidget, day.fidget)
        XCTAssertEqual(PetTemperament.of(.curious, dayPart: .evening), day)
    }

    // MARK: The settings tab

    func testTheGatoTabSitsSecondAndItsSymbolExists() {
        XCTAssertEqual(SettingsTab.pet.title, "Gato")
        XCTAssertEqual(SettingsTab(rawValue: "pet"), .pet)
        XCTAssertNotNil(NSImage(systemSymbolName: SettingsTab.pet.symbol, accessibilityDescription: nil))
        XCTAssertEqual(SettingsTab.allCases.firstIndex(of: .pet), 1, "after Isla, before the permissions")
    }

    func testTheGatoTabFitsTheCardAndEveryScreen() {
        let model = AppModel(receivesSignals: false, defaults: suite())
        for screen in [CGSize(width: 1512, height: 982), CGSize(width: 1280, height: 800), CGSize(width: 700, height: 520)] {
            model.settingsTab = .pet
            let host = NSHostingView(rootView: SettingsCard(model: model, screen: screen, topInset: 32, permissions: PermissionsModel(states: [:])).environment(\.nookTintedGlass, false))
            let size = host.fittingSize
            XCTAssertEqual(size.width, SettingsCard.width, accuracy: 1)
            let island = NotchGeometry.expandedSize(screen: screen, topInset: 32, settings: model.display)
            let room = max(360, screen.height - island.height - SettingsPlacement.gap - SettingsPlacement.margin)
            XCTAssertLessThanOrEqual(size.height, room + 1, "the card never asks for more than the screen leaves (\(screen)): \(size.height) of \(room)")
            XCTAssertGreaterThan(size.height, 300)
        }
    }

    /// The preview and the swatches are pictures of the cat: each takes the coat chosen, and the picture changes when the choice does.
    func testThePicturesShowTheChosenCoatAndAccessory() throws {
        func average(_ view: NSView, in rect: CGRect) throws -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, n: CGFloat = 0
            let k = CGFloat(rep.pixelsWide) / view.bounds.width
            for x in Int(rect.minX * k)..<Int(rect.maxX * k) { for y in Int(rect.minY * k)..<Int(rect.maxY * k) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent + c.greenComponent + c.blueComponent > 0.6 { r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1 }
            } }
            return (r / max(n, 1), g / max(n, 1), b / max(n, 1))
        }
        func thumbnail(_ look: PetLook) -> NSHostingView<some View> {
            let host = NSHostingView(rootView: PetThumbnail(look: look, scale: 2.2).frame(width: 90, height: 80))
            host.frame = NSRect(x: 0, y: 0, width: 90, height: 80)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            return host
        }
        let area = CGRect(x: 20, y: 10, width: 50, height: 60)
        let white = try average(thumbnail(PetLook(coat: .snow)), in: area)
        let ginger = try average(thumbnail(PetLook(coat: .ginger)), in: area)
        XCTAssertGreaterThan(white.r, 0.9); XCTAssertGreaterThan(white.g, 0.9); XCTAssertGreaterThan(white.b, 0.9, "the white cat is white")
        XCTAssertGreaterThan(ginger.r, ginger.b + 0.2, "the ginger one is orange")
        XCTAssertLessThan(ginger.b, 0.7)
        let collar = try average(thumbnail(PetLook(coat: .snow, accessory: .collar)), in: area)
        XCTAssertLessThan(collar.r, white.r, "a mint collar takes some of the red out of the white")
    }
}
