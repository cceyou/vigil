# Vigil

A macOS menu bar app that keeps your MacBook **awake with the lid closed while Claude Code is working**, then puts it to **sleep once Claude Code has finished**.

- Menu bar only (no Dock icon, no Cmd+Tab entry). Click the icon for the popover, right-click for Toggle / Sleep now / Settings / Quit.
- Knows what Claude Code is doing through **hooks**, not by watching processes, and tracks any number of concurrent sessions.
- Fails safe: `disablesleep` is always restored on quit, on signals, at launch, and by a watchdog if the app is killed.
- English and Czech, following the system language. macOS 14+. `build.sh` builds for the machine it runs on (developed and tested on Apple silicon; Intel is untested).

> **Heat warning.** A closed laptop in a bag overheats. Keep it on a flat surface, ideally plugged in. Vigil shows this reminder permanently and shuts the keep-awake down if the Mac gets hot (see [Safety](#safety)).

## Install

```bash
./build.sh              # builds ./build/Vigil.app (ad-hoc signed, Hardened Runtime, no sandbox)
./build.sh --install    # ...and copies it to /Applications (quits a running Vigil first so it restores sleep)
./build.sh --test       # ...runs the unit tests first
open build/Vigil.app
```

`build.sh` needs only the Xcode **Command Line Tools** (`xcode-select --install`); full Xcode is not required. See [Development](#development) for signing and Xcode notes.

## One-time setup (under 2 minutes)

The first launch opens the popover with a checklist. Each item shows a green check when done:

1. **Sleep permission**: click *Allow*, enter your admin password once. This installs `/etc/sudoers.d/vigil`, so `pmset disablesleep` works without a password afterwards.
2. **Claude Code hooks**: click *Add hooks*. Vigil backs up `~/.claude/settings.json`, then merges its hooks in.
3. **Notifications**: click *Allow* and accept the macOS prompt.
4. **Launch at login**: click *Enable*.

Then click **Run self-test**. It checks the sudo permission, the hooks (present *and* up to date), the socket, a fake hook event sent through the real `hook.sh`, a fake `SubagentStart` → `SubagentStop` pair (the session must go working → idle), and notification authorization, with a fix button next to anything that fails. The fake subagent events run through a private sandbox state machine, so the self-test can never hold the Mac awake or put it to sleep.

> Restart Claude Code sessions that were already running so they load the new hooks. (Recent Claude Code versions also pick up hook changes live, but restarting is the documented way.)

## How it works

```
Claude Code ──hook──▶ hook.sh ──nc -U──▶ vigil.sock ──▶ StateMachine ──▶ effects (pmset, IOPM, notifications)
```

**Hooks** (installed into `~/.claude/settings.json`, each marked by the command path `…/Vigil/hook.sh` so they can be removed cleanly, and stamped with the hook-set version, e.g. `…/hook.sh" Stop --vigil-hooks=2`):

| Hook | Meaning |
|---|---|
| `SessionStart` | a session exists (idle) |
| `UserPromptSubmit` | **working** |
| `Stop` | done (idle) |
| `Notification` | Claude is waiting for you (see policy below) |
| `SessionEnd` | session gone |
| `PostToolUse` | *heartbeat* (an addition beyond the five you asked for, see below) |
| `SubagentStart` | a subagent (Agent tool, background agent) started: the session is **working** |
| `SubagentStop` | that subagent finished |

`hook.sh` (installed at `~/Library/Application Support/Vigil/hook.sh`) reads the hook JSON on stdin, walks up the process tree to find the `claude`/`node` PID, and sends one JSON line to the app's Unix socket with `/usr/bin/nc -U -w 1`. It **always exits 0, prints nothing**, and does nothing if Vigil is not running (≈10-15 ms per call).

**Why `PostToolUse`?** When you approve a permission prompt, Claude Code fires *no* `UserPromptSubmit`, so a session that had sent a `Notification` would stay "waiting" while Claude works again, and with the default policy the Mac could go to sleep mid-task. The heartbeat flips a *waiting* session back to *working*. It also lets Vigil adopt a session it missed (for example if Vigil restarted mid-task; PID required). It never revives an *idle* session. Remove it by deleting the `PostToolUse` entry if you don't want it; everything else keeps working.

**Hook versions.** When Vigil's hook set changes (version 2 added `SubagentStart`/`SubagentStop`), Vigil notices that the entries in `settings.json` are older than the app and shows **Update hooks** in Settings, in the setup checklist and in the self-test. Updating backs up `settings.json`, replaces only Vigil's own entries (whatever version they are) and leaves every other hook untouched, including hooks that share a group with Vigil's. Running it twice changes nothing. **Already-running Claude Code sessions must be restarted** to pick up the new hooks.

**Subagents.** The main agent can end its turn (`Stop`) while subagents it started keep working. Vigil keeps a set of active subagents per session, keyed by `agent_id` (with `agent_type` and start time): `SubagentStart` adds one, `SubagentStop` removes it. A `SubagentStop` for an agent Vigil never saw start (for example Vigil launched mid-session) is ignored.

**Rules**
- A session is **working** if its main agent got `UserPromptSubmit` without a `Stop` since, **or** it has at least one active subagent.
- The Mac may sleep only when **all** sessions are idle by that definition, waiting (default policy) or ended.
- `Stop` while subagents are still running only marks the main agent idle; no countdown starts. The countdown starts when the **last** `SubagentStop` arrives, and a `SubagentStart` during the countdown cancels it.
- **Stuck-subagent guard**: a subagent with no `SubagentStop` for longer than the *stuck subagent limit* (default 2 h) is dropped with a warning in the log. `SessionEnd` or a dead Claude process clears all of that session's subagents.
- After the last session goes idle, a **grace period** (default 30 s) starts. That is also the countdown you see ("Sleeping in 0:24") and the notification with **Cancel** / **Keep awake**. A new prompt during the countdown cancels it.
- When it expires: `pmset -a disablesleep 0` is restored **first**, then `pmset sleepnow`. Always in that order (the executor is a single ordered queue).
- Ctrl+C fires no `Stop`, so every 10 s Vigil checks each session's PID with `kill(pid, 0)` and drops dead ones. A "working" session with no events for longer than the max duration is dropped too.
- *Notification policy* (Settings): treat "waiting for me" as idle and start the countdown (default), or keep awake.
- *Only sleep if the lid is closed* (default off): with the lid open, Vigil restores normal sleep but does not force it.
- While awake, Vigil holds `pmset disablesleep 1` (lid-closed, on battery) **and** IOPM assertions `PreventUserIdleSystemSleep` + `PreventSystemSleep` (idle sleep).

### Safety

A stuck `disablesleep 1` in a backpack is dangerous, so there are several independent layers:

- **Restore on**: Quit, `SIGTERM`/`SIGINT`/`SIGHUP`, logout/shutdown, and at launch if `SleepDisabled = 1` without an active session. Every 10 s Vigil also re-checks and undoes a stuck value.
- **Watchdog**: when `disablesleep 1` is set, a detached shell watches the app's PID and runs `sudo -n pmset -a disablesleep 0` if the app dies (crash or `kill -9`). Verified: restored ~0.6 s after `SIGKILL`.
- **Max keep-awake** (default 8 h): restore and sleep.
- **Battery guard** (default 5 %, can be turned off): on battery below the threshold, restore normal sleep with a notification, and sleep at once if the lid is closed. With the lid open, macOS takes over sleep instead of Vigil forcing it.
- **Thermal guard**: `ProcessInfo.thermalState` of `.serious`/`.critical` with the lid closed: restore and sleep immediately.

### Privileges: sudoers vs. a privileged helper

`disablesleep` needs root. Vigil uses a one-time **sudoers rule**:

```
<you> ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

Validated with `visudo -cf` before it is moved into place (`root:wheel`, `0440`). Only those two exact commands are allowed (`pmset -a sleep 1` and `pmset -a disablesleep 2` still ask for a password). `pmset sleepnow` needs no root.

| | sudoers rule (used) | `SMAppService` privileged helper |
|---|---|---|
| Setup | one password prompt, ~30 lines of code | needs a real signed helper (Developer ID/team), a LaunchDaemon plist, XPC, and approval in Login Items |
| Works with ad-hoc signing | yes | not reliably |
| Watchdog after a crash | trivial (`sudo -n` from a shell) | needs a second path into the helper |
| Who can flip the setting | **any process running as your user** (but only these two commands) | only callers matching a code-signing requirement |
| Footprint | one file in `/etc/sudoers.d` | a root daemon that stays installed |

For a personal tool the sudoers rule is the simpler trade; if you distribute Vigil to others, a signed helper is the better design.

## Settings

Launch at login, grace period (10 s to 5 min), maximum keep-awake (1 to 24 h), stuck subagent limit (30 min, 1, 2 or 4 h), low-battery threshold, only-sleep-if-lid-closed, notification policy, install/update/remove hooks, install/remove sleep permission, Dry run, Run self-test, Open log.

**Dry run** goes through the whole flow (working → idle → countdown → restore → sleep) but only logs `would run: pmset …`, and never calls `pmset`. Use *Simulate a session* to watch it happen (the simulated session includes a subagent that outlives the main agent's `Stop`).

The popover shows a badge on a session row while subagents run (*alwayson · Working · 2 subagents*); hover it or click it to see their types (*Explore, code-reviewer*). When every main agent is done but subagents still run, the header reads *Subagents working · 0:12:40* instead of a countdown, and the menu bar icon stays in the working state.

Data lives in `~/Library/Application Support/Vigil/`: `hook.sh`, `vigil.sock`, `history.json` (last 50 sessions: project, start, duration, how it ended, most subagents at once and total subagent time), `logs/vigil.log` (rotating, 1 MB × 3). Preferences are in `defaults read cz.krystof.vigil`.

## Troubleshooting

| Symptom | Check |
|---|---|
| Icon never turns to "working" | Popover ▸ *Run self-test*. `grep "hook " ~/Library/Application\ Support/Vigil/logs/vigil.log`. Are the hooks in `~/.claude/settings.json` (`grep Vigil ~/.claude/settings.json`)? Restart the Claude Code session. |
| Mac slept while a subagent was running | That Claude Code session was started before the subagent hooks were installed. Settings ▸ *Update hooks* if it is offered, then **restart Claude Code** so the new hooks load. Check with `grep Subagent ~/Library/Application\ Support/Vigil/logs/vigil.log`. |
| A session stays "working" long after its subagents finished | A `SubagentStop` got lost. The stuck-subagent guard drops it after the limit (Settings ▸ *Stuck subagent limit*); look for `dropped stuck subagent` in the log. |
| "Couldn't change sleep settings" | The sudoers rule is missing: run `sudo -n -l` and look for the two `pmset` commands, or click *Install sleep permission*. |
| `pmset -g \| grep SleepDisabled` shows 1 with Vigil not running | `sudo pmset -a disablesleep 0` (relaunching Vigil also fixes it). |
| Hook commands fail in Claude Code | `hook.sh` missing? Vigil restores it at launch and every 10 s while running. Or click *Install hooks* again. |
| No notification buttons | System Settings ▸ Notifications ▸ Vigil ▸ set the style to *Alerts* to keep the buttons on screen. |
| Icon hidden on a notched MacBook | Too many menu bar icons: hold ⌘ and drag some away. |
| `codesign` fails with "detritus not allowed" | The project is in an iCloud-synced folder (Desktop/Documents). `build.sh` builds and signs under `~/Library/Caches/Vigil` (valid), but iCloud re-stamps the copy in `./build` seconds later, so `codesign --verify` on *that* copy fails even though the app launches. Use `./build.sh --install` (a copy in `/Applications` always verifies), or keep the project outside iCloud. |
| `ld: warning: search path … not found` | Harmless notices from Command Line Tools without Xcode; `build.sh` hides exactly those and says how many. |

Live log: `tail -f ~/Library/Application\ Support/Vigil/logs/vigil.log`.

## Uninstall

In the app: Settings ▸ *Remove hooks*, *Remove* (sleep permission), turn off *Launch at login*, Quit. Or run everything at once:

```bash
./uninstall.sh            # asks before each step
./uninstall.sh --yes      # no questions
./uninstall.sh --hooks-only [--yes]   # only the settings.json entries
```

It quits Vigil (which restores sleep), removes only Vigil's entries from `~/.claude/settings.json` (timestamped backup first), deletes `/etc/sudoers.d/vigil` (password), makes sure `SleepDisabled` is 0, and deletes the app, its data and its preferences. By hand: `sudo rm /etc/sudoers.d/vigil`, remove entries containing `Vigil/hook.sh` from `settings.json` (or restore a `settings.json.vigil-backup-*`), then delete `Vigil.app` and `~/Library/Application Support/Vigil`.

## Manual test checklist

1. `./build.sh && open build/Vigil.app`, complete the checklist, **Run self-test**: all six checks green.
2. Start a long Claude Code task (for example ask it to run a 3-minute `sleep`). Icon turns to ⚡, header says "Claude is working".
3. `pmset -g | grep SleepDisabled` → `1`. `pmset -g assertions | grep Vigil` → two assertions.
4. **Close the lid** (on a hard surface, plugged in). Wait a minute, then open a screen-share/SSH or just check later that the task kept running and the Mac never slept.
5. Let the task finish. Within the grace period a notification appears; after it, the Mac **sleeps by itself** (`pmset -g log | grep -i sleep`).
6. Try **Cancel** (Mac stays awake, back to armed) and **Keep awake** (holds 1 h) on the countdown.
7. Two Claude sessions at once: finish one, the Mac stays awake until the other is done.
   - Subagents: ask Claude to start a background subagent (e.g. "run an Explore agent in the background") and end its turn: the row shows the subagent badge, the header says "Subagents working", and the countdown only starts once the subagent finishes.
8. Press Ctrl+C in a session mid-task: within about 10 s the session disappears and the countdown starts.
9. Start a task, then `kill -9 $(pgrep -x Vigil)`: `pmset -g | grep SleepDisabled` is back to `0` within a few seconds.
10. Start a task, then Quit Vigil from the menu, and again with `kill $(pgrep -x Vigil)`: `SleepDisabled` returns to `0` immediately.
11. Battery/thermal guards: unplug and set the threshold above the current level (Settings ▸ Low battery threshold): Vigil restores and sleeps at once.

## Development

```bash
swift build                    # debug build (Vigil.app is assembled only by build.sh)
./build.sh --test              # unit tests + release build
Vigil --snapshot <dir>         # render the popover to PNGs (light + dark), no permissions needed
```

Layout: `Sources/VigilCore` (StateMachine, HookServer, PowerController, SettingsInstaller = `ClaudeSettingsMerger` + `HookInstaller` + `SudoersInstaller`, Notifier, BatteryThermalMonitor, Persistence, SelfTest, Logging), `Sources/Vigil` (AppKit shell + SwiftUI popover), `Tests/VigilTests` (97 tests: state machine incl. multi-session/grace/interrupt/cancel and subagents (Stop with active subagents, last SubagentStop, SubagentStart during countdown, unknown SubagentStop, stuck-subagent timeout), settings.json merger incl. missing/invalid/idempotent/removal and the v1 → v2 hook upgrade, PID liveness, socket + real `hook.sh` round trips, watchdog script, localization completeness).

- **Tests** use Swift Testing. On a Command-Line-Tools-only machine the testing macro plugin is not on the default path; `build.sh --test` passes `-plugin-path` for you. By hand: `swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"`.
- **Localization**: `Resources/Localizable.xcstrings` is the source of truth (Xcode-compatible). Code calls `L("English text")`. `build.sh` generates `en.lproj`/`cs.lproj` from it and **fails the build** if the code uses a string that is missing or has no Czech translation.
- **Icon**: `swift Scripts/make_icon.swift Resources/Assets.xcassets` renders it with CoreGraphics into the asset catalog; `build.sh` turns the PNGs into `AppIcon.icns` with `iconutil`.
- **Signing**: ad-hoc by default (`codesign --sign - --options runtime`). For a stable identity: `SIGN_IDENTITY="Apple Development: you (TEAMID)" ./build.sh`. The app is **not notarized**; a locally built copy has no quarantine flag and opens normally. The App Sandbox is off (needs `~/.claude`, `pmset`, a socket); Hardened Runtime is on with no exceptions.
- **Xcode**: `project.yml` (XcodeGen) is provided (`xcodegen generate`), but it has **not been run through `xcodebuild`** because Xcode is not installed on the development machine. SwiftPM + `build.sh` is the verified path.

## Known limitations

- The countdown notification cannot tick live (macOS does not update delivered notifications); the popover and the menu bar title show the real countdown.
- Closing the lid needs `disablesleep`, which requires the sudoers rule; without it Vigil still holds idle-sleep assertions (lid-open case) and says so in the UI.
- The lid-closed / real-sleep behavior (checklist steps 4-5) has to be verified by hand on your machine.
