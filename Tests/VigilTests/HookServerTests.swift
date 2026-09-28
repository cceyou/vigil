import Foundation
import Testing
@testable import VigilCore

@Suite(.serialized) struct HookServerTests {
    /// Short path: sockaddr_un limits sun_path to 104 bytes.
    private func socketPath() -> String { "/tmp/vgl-\(UUID().uuidString.prefix(8)).sock" }

    private func installScript(in dir: URL) throws -> String {
        let path = dir.appendingPathComponent("hook.sh")
        try HookScript.contents.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    private func runHook(_ script: String, event: String, payload: String, socket: String,
                         launcher: String = "/bin/sh") -> (ShellResult, TimeInterval) {
        let start = Date()
        let r = Shell.run(launcher, [script, event], stdin: payload,
                          environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "VIGIL_SOCKET": socket], timeout: 5)
        return (r, Date().timeIntervalSince(start))
    }

    @Test func parserAcceptsWrappedAndBarePayloads() throws {
        let wrapped = #"{"vigil_event":"Stop","pid":123,"payload":{"session_id":"s1","cwd":"/a/b","hook_event_name":"Stop"}}"#
        #expect(HookEventParser.parse(Data(wrapped.utf8)) == HookEvent(kind: .stop, sessionID: "s1", cwd: "/a/b", pid: 123))
        let bare = #"{"session_id":"s2","hook_event_name":"UserPromptSubmit","cwd":"/x"}"#
        #expect(HookEventParser.parse(Data(bare.utf8)) == HookEvent(kind: .userPromptSubmit, sessionID: "s2", cwd: "/x", pid: nil))
        // pid 0 (not found by the script) becomes nil
        let noPid = #"{"vigil_event":"Stop","pid":0,"payload":{"session_id":"s3"}}"#
        #expect(HookEventParser.parse(Data(noPid.utf8))?.pid == nil)
    }

    @Test func parserRejectsGarbage() {
        for bad in ["", "not json", "[]", #"{"vigil_event":"Nope","payload":{"session_id":"x"}}"#,
                    #"{"vigil_event":"Stop","payload":{}}"#, #"{"vigil_event":"Stop","payload":{"session_id":""}}"#] {
            #expect(HookEventParser.parse(Data(bad.utf8)) == nil)
        }
    }

    @Test func eventsRoundTripThroughHookScriptAndSocket() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sock = socketPath()
        let box = EventBox()
        let server = HookServer(socketPath: sock) { box.add($0) }
        try server.start()
        defer { server.stop() }
        #expect(HookServer.probe(socketPath: sock))

        let script = try installScript(in: dir)
        let payload = #"{"session_id":"abc-123","cwd":"/Users/me/my project","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#
        let (result, elapsed) = runHook(script, event: "UserPromptSubmit", payload: payload, socket: sock)

        #expect(result.status == 0)
        #expect(result.stdout.isEmpty && result.stderr.isEmpty) // must never print
        #expect(elapsed < 1.5)
        #expect(box.waitForCount(1))
        let event = try #require(box.all.first)
        #expect(event.kind == .userPromptSubmit)
        #expect(event.sessionID == "abc-123")
        #expect(event.cwd == "/Users/me/my project")
    }

    @Test func multilinePayloadStillArrivesAsOneEvent() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sock = socketPath()
        let box = EventBox()
        let server = HookServer(socketPath: sock) { box.add($0) }
        try server.start(); defer { server.stop() }
        let script = try installScript(in: dir)
        let payload = "{\n  \"session_id\": \"multi\",\n  \"cwd\": \"/tmp\"\n}\n"
        _ = runHook(script, event: "Stop", payload: payload, socket: sock)
        #expect(box.waitForCount(1))
        #expect(box.all.first?.sessionID == "multi")
    }

    @Test func hookScriptExitsZeroSilentlyWhenVigilIsNotRunning() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let script = try installScript(in: dir)
        let (result, elapsed) = runHook(script, event: "Stop", payload: #"{"session_id":"x"}"#, socket: "/tmp/vgl-nonexistent.sock")
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty && result.stderr.isEmpty)
        #expect(elapsed < 1.0)
    }

    @Test func hookScriptSurvivesStaleSocketAndBadInput() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let script = try installScript(in: dir)
        // A leftover socket file with no listener behind it.
        let stale = socketPath()
        let s = HookServer(socketPath: stale) { _ in }
        try s.start()
        // Simulate a crash: the socket file stays, nobody listens.
        s.stop()
        FileManager.default.createFile(atPath: stale, contents: Data())
        let (r1, _) = runHook(script, event: "Stop", payload: "{}", socket: stale)
        #expect(r1.status == 0 && r1.stdout.isEmpty && r1.stderr.isEmpty)
        try? FileManager.default.removeItem(atPath: stale)

        for bad in ["", "garbage", "\u{0}"] {
            let (r, _) = runHook(script, event: "Stop; rm -rf /", payload: bad, socket: "/tmp/vgl-none.sock")
            #expect(r.status == 0 && r.stdout.isEmpty)
        }
    }

    @Test func hookScriptFindsTheClaudeProcess() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sock = socketPath()
        let box = EventBox()
        let server = HookServer(socketPath: sock) { box.add($0) }
        try server.start(); defer { server.stop() }
        let script = try installScript(in: dir)

        // A shell that presents itself as "claude" and runs the hook as a child (so the PID walk must find it).
        let fakeClaude = dir.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: fakeClaude, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        let pidFile = dir.appendingPathComponent("pid").path
        // $0 = placeholder, $1 = hook script, $2 = file receiving the fake claude's own PID. `; true` stops sh from exec-ing.
        let command = #"echo '{"session_id":"pidtest"}' | "$1" Stop; echo $$ > "$2"; true"#
        let r = Shell.run(fakeClaude.path, ["-c", command, "_", script, pidFile],
                          environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "VIGIL_SOCKET": sock], timeout: 5)
        #expect(r.status == 0)
        #expect(box.waitForCount(1))
        let expected = Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(expected != nil)
        #expect(box.all.first?.pid == expected)
    }

    @Test func serverRecreatesStaleSocketAndSurvivesGarbageClients() throws {
        let sock = socketPath()
        FileManager.default.createFile(atPath: sock, contents: Data("stale".utf8))
        let box = EventBox()
        let server = HookServer(socketPath: sock) { box.add($0) }
        try server.start(); defer { server.stop() }
        #expect(HookServer.probe(socketPath: sock))

        // A client sending garbage and one that connects and hangs up must not break the server.
        let garbage = Shell.run("/bin/sh", ["-c", "printf 'not json\\n' | /usr/bin/nc -U -w 1 '\(sock)'"], timeout: 5)
        _ = garbage
        let silent = Shell.run("/bin/sh", ["-c", ": | /usr/bin/nc -U -w 1 '\(sock)'"], timeout: 5)
        _ = silent
        let good = Shell.run("/bin/sh", ["-c", "printf '{\"vigil_event\":\"Stop\",\"pid\":0,\"payload\":{\"session_id\":\"ok\"}}\\n' | /usr/bin/nc -U -w 1 '\(sock)'"], timeout: 5)
        _ = good
        #expect(box.waitForCount(1))
        #expect(box.all.first?.sessionID == "ok")
        #expect(box.all.count == 1)
    }

    @Test func stopRemovesTheSocket() throws {
        let sock = socketPath()
        let server = HookServer(socketPath: sock) { _ in }
        try server.start()
        #expect(FileManager.default.fileExists(atPath: sock))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: sock))
        #expect(!HookServer.probe(socketPath: sock))
    }
}
