import Foundation
import Testing
@testable import VigilCore

/// "Claude is waiting for the user": Notification types, PermissionRequest, the PostToolUse heartbeat,
/// and the max-wait timeout. The waiting-policy migration is in SettingsStoreTests.
@Suite struct WaitingTests {
    // MARK: notification_type

    @Test(arguments: ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"])
    func waitingTypesKeepTheMacAwake(_ type: String) {
        #expect(ClaudeNotificationType.meaning(of: type) == .waiting)
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(hook(.notification, type: type), at: at(5)).isEmpty)
        #expect(m.sessions[0].state == .waiting)
        #expect(m.phase == .working)
        #expect(m.awakeHeld)
    }

    @Test func waitingTypeFromAnIdleSessionAcquires() {
        var m = machine()
        _ = m.handle(hook(.sessionStart), at: at(0))
        #expect(m.handle(hook(.notification, type: "elicitation_dialog"), at: at(1)) == [.acquireAwake])
        #expect(m.phase == .working)
    }

    @Test func idlePromptIsIdleNotWaiting() {
        #expect(ClaudeNotificationType.meaning(of: "idle_prompt") == .idle)
        var m = machine()
        _ = m.handle(hook(.sessionStart), at: at(0))
        #expect(m.handle(hook(.notification, type: "idle_prompt"), at: at(60)).isEmpty)
        #expect(m.sessions[0].state == .idle)
        #expect(m.phase == .armed)
        #expect(!m.awakeHeld)
    }

    @Test func idlePromptAfterStopDoesNotKeepAwakeOrRestartTheCountdown() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(hook(.stop), at: at(10)) == [.showCountdown(deadline: at(40))])
        // Claude Code sends idle_prompt a while after Stop: nothing may change.
        #expect(m.handle(hook(.notification, type: "idle_prompt"), at: at(25)).isEmpty)
        #expect(m.countdownDeadline == at(40))
        #expect(m.sessions[0].state == .idle)
        #expect(m.phase == .countdown)
        #expect(m.handle(.tick, at: at(40)) == [.dismissCountdown, .releaseAwake, .sleepNow])
        // ...and a late idle_prompt after the Mac slept does not re-acquire.
        #expect(m.handle(hook(.notification, type: "idle_prompt"), at: at(90)).isEmpty)
        #expect(!m.awakeHeld)
    }

    @Test func idlePromptNeverCreatesASession() {
        var m = machine()
        #expect(m.handle(hook(.notification, "new", type: "idle_prompt"), at: at(0)).isEmpty)
        #expect(m.sessions.isEmpty)
    }

    @Test func idlePromptEndsAWaitingSession() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(permissionPrompt(), at: at(5))
        #expect(m.handle(hook(.notification, type: "idle_prompt"), at: at(70)) == [.showCountdown(deadline: at(100))])
        #expect(m.sessions[0].state == .idle)
    }

    @Test(arguments: ["auth_success", "something_new", ""])
    func unknownTypesAreLoggedAndIgnored(_ type: String) {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(hook(.stop), at: at(5))
        let before = m
        // An empty string arrives as nil from the parser; the machine treats both the same.
        let raw: String? = type.isEmpty ? nil : type
        #expect(m.handle(hook(.notification, type: raw), at: at(6)) == [.ignoredNotification(type: raw)])
        #expect(m.sessions == before.sessions)
        #expect(m.countdownDeadline == before.countdownDeadline)
    }

    @Test func unknownTypeFromAnUnknownSessionCreatesNothing() {
        var m = machine()
        #expect(m.handle(hook(.notification, "ghost", type: "mystery"), at: at(0)) == [.ignoredNotification(type: "mystery")])
        #expect(m.sessions.isEmpty)
    }

    // MARK: PermissionRequest / PostToolUse

    @Test func permissionRequestIsASecondWaitingSignal() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(hook(.permissionRequest), at: at(3)).isEmpty)
        #expect(m.sessions[0].state == .waiting)
        #expect(m.sessions[0].stateSince == at(3))
        // The Notification for the same prompt follows: still waiting, the wait does not restart.
        _ = m.handle(permissionPrompt(), at: at(4))
        #expect(m.sessions[0].stateSince == at(3))
        #expect(m.phase == .working)
    }

    @Test func postToolUseMovesAnAnsweredSessionBackToWorking() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(hook(.permissionRequest), at: at(3))
        #expect(m.handle(hook(.postToolUse), at: at(20)).isEmpty) // no release/re-acquire churn
        #expect(m.sessions[0].state == .working)
        #expect(m.sessions[0].stateSince == at(20))
        #expect(m.phase == .working)
    }

    // MARK: max wait

    @Test func maxWaitNotifiesAndStartsTheSleepCountdown() {
        var m = machine { $0.maxWaiting = 100 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(permissionPrompt(), at: at(5))
        #expect(m.handle(.tick, at: at(104)).isEmpty)
        #expect(m.handle(.tick, at: at(105)) == [.waitTimedOut(project: "proj", waited: 100), .showCountdown(deadline: at(135))])
        #expect(m.phase == .countdown)
        #expect(m.sessions[0].state == .waiting) // still waiting, it just no longer keeps the Mac awake
        #expect(m.handle(.tick, at: at(120)).isEmpty) // notified once
        #expect(m.handle(.tick, at: at(135)) == [.dismissCountdown, .releaseAwake, .sleepNow])
    }

    @Test func answeringAfterMaxWaitWorksAgainAndANewWaitGetsAFreshTimer() {
        var m = machine { $0.maxWaiting = 100 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(permissionPrompt(), at: at(5))
        _ = m.handle(.tick, at: at(105))
        // Answered from the phone during the countdown.
        #expect(m.handle(hook(.postToolUse), at: at(110)) == [.dismissCountdown])
        #expect(m.phase == .working)
        _ = m.handle(permissionPrompt(), at: at(200))
        #expect(!m.sessions[0].waitExpired)
        #expect(m.handle(.tick, at: at(299)).isEmpty)
        #expect(m.handle(.tick, at: at(300)).first == .waitTimedOut(project: "proj", waited: 100))
    }

    @Test func maxWaitDoesNotApplyUnderSleepAfterDelay() {
        var m = machine { $0.notificationPolicy = .treatAsIdle; $0.maxWaiting = 100; $0.graceSeconds = 1000 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(permissionPrompt(), at: at(5))
        #expect(!m.handle(.tick, at: at(200)).contains { if case .waitTimedOut = $0 { return true } else { return false } })
    }

    @Test func runningSubagentStillKeepsTheMacAwakeAfterMaxWait() {
        var m = machine { $0.maxWaiting = 100 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(subagent(.subagentStart, "x1"), at: at(1))
        _ = m.handle(permissionPrompt(), at: at(5))
        #expect(m.handle(.tick, at: at(105)) == [.waitTimedOut(project: "proj", waited: 100)])
        #expect(m.phase == .working)
    }

    // MARK: parsing

    @Test func parserReadsNotificationType() {
        let raw = #"{"vigil_event":"Notification","pid":9,"payload":{"session_id":"s","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}}"#
        #expect(HookEventParser.parse(Data(raw.utf8))?.notificationType == "permission_prompt")
        let none = #"{"vigil_event":"Notification","payload":{"session_id":"s","notification_type":""}}"#
        #expect(HookEventParser.parse(Data(none.utf8))?.notificationType == nil)
        let perm = #"{"vigil_event":"PermissionRequest","payload":{"session_id":"s","tool_name":"Bash"}}"#
        #expect(HookEventParser.parse(Data(perm.utf8))?.kind == .permissionRequest)
    }
}
