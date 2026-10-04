import Foundation
import Testing
@testable import VigilCore

/// Records what would have played; never touches audio.
final class FakeSoundPlayer: SoundPlaying {
    private(set) var played: [String] = []
    private(set) var volumes: [Double] = []
    func play(_ sound: String, volume: Double) {
        played.append(sound)
        volumes.append(volume)
    }
}

/// A state machine with the chime watching it, the way AppModel wires them.
private struct Rig {
    var machine: StateMachine = VigilTests.machine()
    let player = FakeSoundPlayer()
    let chime: ChimeMachine

    init(_ configure: (inout SoundSettings) -> Void = { _ in }) {
        var settings = SoundSettings()
        configure(&settings)
        chime = ChimeMachine(settings: settings, player: player)
    }

    mutating func send(_ event: Event, at seconds: TimeInterval) {
        let before = machine.sessions
        _ = machine.handle(event, at: at(seconds))
        chime.observe(event, before: before, after: machine.sessions, at: at(seconds))
    }
}

@Suite struct ChimeTests {
    @Test func workingToIdlePlaysExactlyOnce() {
        var r = Rig()
        r.send(hook(.userPromptSubmit), at: 0)
        r.send(hook(.stop), at: 60)
        #expect(r.player.played == ["Glass"])
        #expect(r.player.volumes == [0.8])
        // Later events on the idle session (idle_prompt, a duplicate Stop, ticks) stay silent.
        r.send(hook(.notification, type: "idle_prompt"), at: 120)
        r.send(hook(.stop), at: 130)
        r.send(.tick, at: 140)
        #expect(r.player.played == ["Glass"])
    }

    @Test func shortTurnDoesNotPlay() {
        var r = Rig()
        r.send(hook(.userPromptSubmit), at: 0)
        r.send(hook(.stop), at: 12)
        #expect(r.player.played.isEmpty)
        // "Vždy" (0) plays even a short one.
        var always = Rig { $0.minTurnDuration = 0 }
        always.send(hook(.userPromptSubmit), at: 0)
        always.send(hook(.stop), at: 2)
        #expect(always.player.played == ["Glass"])
    }

    @Test func turnTimeCountsFromThePromptNotFromTheLastStateChange() {
        var r = Rig()
        r.send(hook(.userPromptSubmit), at: 0)
        r.send(permissionPrompt(), at: 20)
        r.send(hook(.postToolUse, pid: 1), at: 25) // approved: working again
        r.send(hook(.stop), at: 40)
        #expect(r.player.played == ["Tink", "Glass"])
    }

    @Test func activeSubagentsBlockTheSoundUntilTheLastOneFinishes() {
        var r = Rig()
        r.send(hook(.userPromptSubmit), at: 0)
        r.send(subagent(.subagentStart, "x1"), at: 5)
        r.send(subagent(.subagentStart, "x2"), at: 6)
        r.send(hook(.stop), at: 60)
        #expect(r.player.played.isEmpty)
        r.send(subagent(.subagentStop, "x1"), at: 90)
        #expect(r.player.played.isEmpty)
        r.send(subagent(.subagentStop, "x2"), at: 120)
        #expect(r.player.played == ["Glass"])
    }

    @Test func twoSessionsFinishingWithinThreeSecondsPlayOnce() {
        var r = Rig()
        r.send(hook(.userPromptSubmit, "a"), at: 0)
        r.send(hook(.userPromptSubmit, "b"), at: 1)
        r.send(hook(.stop, "a"), at: 100)
        r.send(hook(.stop, "b"), at: 102)
        #expect(r.player.played == ["Glass"])
        // Outside the window each one plays again.
        r.send(hook(.userPromptSubmit, "a"), at: 110)
        r.send(hook(.stop, "a"), at: 200)
        #expect(r.player.played == ["Glass", "Glass"])
    }

    @Test func interruptedSessionDoesNotPlay() {
        var r = Rig()
        // Ctrl+C: no Stop, the process dies.
        r.send(hook(.userPromptSubmit, "a", pid: 10), at: 0)
        r.send(.sessionsDied(["a"]), at: 100)
        // Killed / closed: SessionEnd while working.
        r.send(hook(.userPromptSubmit, "b", pid: 11), at: 0)
        r.send(hook(.sessionEnd, "b"), at: 100)
        // idle_prompt while still marked working.
        r.send(hook(.userPromptSubmit, "c", pid: 12), at: 0)
        r.send(hook(.notification, "c", type: "idle_prompt"), at: 100)
        #expect(r.player.played.isEmpty)
    }

    @Test func doneSoundRespectsItsSetting() {
        var r = Rig { $0.doneEnabled = false }
        r.send(hook(.userPromptSubmit), at: 0)
        r.send(hook(.stop), at: 60)
        #expect(r.player.played.isEmpty)
    }

    @Test func waitingSoundRespectsItsSetting() {
        var r = Rig()
        r.send(hook(.userPromptSubmit), at: 0)
        r.send(permissionPrompt(), at: 10)
        r.send(hook(.permissionRequest), at: 10.5) // the same prompt's second signal
        #expect(r.player.played == ["Tink"])

        var off = Rig { $0.waitingEnabled = false }
        off.send(hook(.userPromptSubmit), at: 0)
        off.send(permissionPrompt(), at: 10)
        off.send(hook(.notification, type: "elicitation_dialog"), at: 20)
        #expect(off.player.played.isEmpty)
    }

    @Test func waitingSoundUsesItsOwnSound() {
        var r = Rig { $0.waitingSound = "Pop"; $0.volume = 0.5 }
        r.send(hook(.userPromptSubmit), at: 0)
        r.send(hook(.notification, type: "agent_needs_input"), at: 10)
        #expect(r.player.played == ["Pop"])
        #expect(r.player.volumes == [0.5])
        // idle_prompt and unknown types never play.
        var idle = Rig()
        idle.send(hook(.notification, type: "idle_prompt"), at: 0)
        idle.send(hook(.notification, type: "something_new"), at: 10)
        #expect(idle.player.played.isEmpty)
    }

    @Test func settingsDecodeWithDefaults() throws {
        let s = try JSONDecoder().decode(SoundSettings.self, from: Data(#"{"doneSound":"Hero","volume":3}"#.utf8))
        #expect(s.doneSound == "Hero")
        #expect(s.volume == 1)
        #expect(s.doneEnabled && s.waitingEnabled && s.minTurnDuration == 30 && s.waitingSound == "Tink")
        #expect(SystemSounds.names().contains("Glass"))
    }
}
