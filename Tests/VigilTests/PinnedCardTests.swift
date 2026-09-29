import Foundation
import Testing
@testable import VigilCore

@Suite struct PinnedCardTests {
    @Test func pinnedCardClosesOnNotchShortcutCloseButtonAndOutsideClick() {
        for trigger: PinnedCard.Trigger in [.notchClick, .shortcut, .closeButton, .mouseDownOutside] {
            #expect(PinnedCard.reaction(to: trigger, shown: true, pinned: true) == .close, "\(trigger)")
        }
    }

    @Test func escClosesOnlyWhenTheCardIsKey() {
        #expect(PinnedCard.reaction(to: .escape(cardIsKey: false), shown: true, pinned: true) == .none)
        #expect(PinnedCard.reaction(to: .escape(cardIsKey: true), shown: true, pinned: true) == .close)
        #expect(PinnedCard.reaction(to: .escape(cardIsKey: true), shown: false, pinned: false) == .none)
    }

    @Test func outsideClickLeavesAnUnpinnedHoverCardToTheHoverTimer() {
        #expect(PinnedCard.reaction(to: .mouseDownOutside, shown: true, pinned: false) == .none)
        #expect(PinnedCard.reaction(to: .mouseDownOutside, shown: false, pinned: false) == .none)
    }

    @Test func openingAndPinning() {
        #expect(PinnedCard.reaction(to: .hover, shown: false, pinned: false) == .show)
        #expect(PinnedCard.reaction(to: .hover, shown: true, pinned: false) == .none)
        #expect(PinnedCard.reaction(to: .clickInCard, shown: true, pinned: false) == .pin)
        #expect(PinnedCard.reaction(to: .clickInCard, shown: true, pinned: true) == .none)
        #expect(PinnedCard.reaction(to: .notchClick, shown: false, pinned: false) == .pin)
        #expect(PinnedCard.reaction(to: .shortcut, shown: false, pinned: false) == .pin)
        #expect(PinnedCard.reaction(to: .closeButton, shown: false, pinned: false) == .none)
    }

    @Test func cardBecomesKeyOnlyFromAClickIntoIt() {
        #expect(PinnedCard.becomesKey(on: .clickInCard))
        for trigger: PinnedCard.Trigger in [.hover, .notchClick, .shortcut, .closeButton, .mouseDownOutside, .escape(cardIsKey: false)] {
            #expect(!PinnedCard.becomesKey(on: trigger), "\(trigger)")
        }
    }

    @Test func outsideClickMonitorRunsOnlyWhilePinned() {
        #expect(PinnedCard.watchesOutsideClicks(shown: true, pinned: true))
        #expect(!PinnedCard.watchesOutsideClicks(shown: true, pinned: false))
        #expect(!PinnedCard.watchesOutsideClicks(shown: false, pinned: false))
    }

    /// Regression guard: Esc must never be registered as a global hot key, and Vigil never monitors keys
    /// outside its own windows (that would need Accessibility and would swallow Esc from Claude Code).
    @Test func noGlobalEscOrKeyMonitorInTheSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            #expect(!text.contains("register(keyCode: UInt32(kVK_Escape)"), "global Esc hot key in \(url.lastPathComponent)")
            for line in text.split(separator: "\n") where line.contains("addGlobalMonitorForEvents") {
                #expect(!line.contains("key"), "global key monitor in \(url.lastPathComponent): \(line)")
                #expect(line.contains(".leftMouseDown"), "global monitor must be mouse-only: \(line)")
            }
        }
        #expect(scanned > 20)
    }
}
