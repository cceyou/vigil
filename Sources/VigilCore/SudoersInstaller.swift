import Foundation

/// One-time privileged setup: /etc/sudoers.d/vigil allowing exactly two pmset commands without a password.
public struct SudoersInstaller: Sendable {
    public static let destination = "/etc/sudoers.d/vigil"
    public static let commands = ["/usr/bin/pmset -a disablesleep 1", "/usr/bin/pmset -a disablesleep 0"]

    public init() {}

    public static func isValidUserName(_ user: String) -> Bool {
        !user.isEmpty && user.count <= 64 && user.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    public static func rule(for user: String) -> String {
        """
        # Managed by Vigil.app - allows exactly these two commands, nothing else. Remove via Vigil > Settings.
        \(user) ALL = (root) NOPASSWD: \(commands.joined(separator: ", "))

        """
    }

    /// True if `sudo -n` may run the pmset commands without a password (does not change any power setting).
    public static func isInstalled() -> Bool {
        commands.allSatisfy { command in
            Shell.run("/usr/bin/sudo", ["-n", "-l"] + command.split(separator: " ").map(String.init), timeout: 5).ok
        }
    }

    /// Validates with `visudo -cf` and installs root:wheel 0440. Asks for the admin password once.
    public func install(user: String = NSUserName()) throws {
        guard Self.isValidUserName(user) else { throw InstallError.sudoersInvalid("unsupported user name") }
        let tmp = NSTemporaryDirectory() + "vigil-sudoers-\(UUID().uuidString)"
        do { try Self.rule(for: user).write(toFile: tmp, atomically: true, encoding: .utf8) } catch {
            throw InstallError.io("could not write temp file: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Unprivileged pre-check so obvious mistakes never trigger a password prompt.
        let check = Shell.run("/usr/sbin/visudo", ["-cf", tmp], timeout: 10)
        guard check.ok else { throw InstallError.sudoersInvalid(check.stderr + check.stdout) }

        // Authoritative check + install in one privileged shell: never install a file that fails visudo.
        let command = "/usr/sbin/visudo -cf '\(tmp)' && /usr/bin/install -d -m 0755 -o root -g wheel /etc/sudoers.d "
            + "&& /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' '\(Self.destination)'"
        try runPrivileged(command, prompt: L("Vigil needs to allow two power commands (pmset disablesleep) without a password."))
        guard Self.isInstalled() else { throw InstallError.privileged("sudoers rule was installed but does not work") }
        Log.shared.info("sudoers rule installed")
    }

    public func remove() throws {
        try runPrivileged("/bin/rm -f '\(Self.destination)'", prompt: L("Vigil will remove its sudoers rule."))
        Log.shared.info("sudoers rule removed")
    }

    /// Runs a shell command as root via the standard macOS admin password dialog.
    private func runPrivileged(_ shellCommand: String, prompt: String) throws {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "do shell script \"\(esc(shellCommand))\" with prompt \"\(esc(prompt))\" with administrator privileges"
        let r = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120)
        if r.ok { return }
        if r.stderr.contains("-128") || r.stderr.lowercased().contains("user canceled") { throw InstallError.userCancelled }
        throw InstallError.privileged(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
