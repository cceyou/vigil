# Vigil

A macOS menu bar app that keeps your MacBook **awake with the lid closed while Claude Code is working**, then puts it to **sleep once Claude Code has finished**, but only when you are away. With the lid open it never yanks the Mac to sleep under you (see [The sleep gate](#the-sleep-gate)).

- Menu bar only (no Dock icon, no Cmd+Tab entry). Click the icon for the popover (a black "Live Activity" style card), right-click for Toggle / Sleep now / Settings / Quit.
- A thin **edge notch** on the right side of the screen opens a Liquid Glass card with your **Claude usage limits** (5-hour and weekly), read from Claude Code's documented status line JSON.
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
3. **Status line**: click *Install*. Needed for the usage card; your existing status line keeps working (see [Claude usage](#edge-notch-and-claude-usage)).
4. **Notifications**: click *Allow* and accept the macOS prompt.
5. **Launch at login**: click *Enable*.

Then click **Run self-test**. It checks the sudo permission, the hooks (present *and* up to date), the socket, a fake hook event sent through the real `hook.sh`, a fake `SubagentStart` → `SubagentStop` pair (the session must go working → idle), the status line (wrapper installed, previous command chained, a fake status line JSON through the real `statusline.sh` to the socket) and notification authorization, with a fix button next to anything that fails. The fake subagent events run through a private sandbox state machine, so the self-test can never hold the Mac awake or put it to sleep.

> Restart Claude Code sessions that were already running so they load the new hooks. (Recent Claude Code versions also pick up hook changes live, but restarting is the documented way.)

## The popover

Pure black, `#1C1C1E` cards, one accent colour (green by default; blue, orange or purple in Settings). Orange is reserved for "waiting for you". Top to bottom:

1. **Island**: a black capsule with the most important live value: elapsed time while Claude works, *Spí za 0:24* during the sleep countdown, *Čeká* (orange) when a session waits for you, *Připraveno* when idle. The menu bar icon mirrors it (bolt / moon / exclamation mark).
2. **Session card** for the most recently active session: project name, *Hlavní agent + 2 subagenti* (Czech plurals: 1 subagent, 2–4 subagenti, 0 and 5+ subagentů), a bolt → moon track (the used part of *keep awake 1 h*, the countdown, or a slow shimmer while Claude works without a timer), and *Běží …* / *Vzhůru ještě …* (the manual hour or the max keep-awake failsafe, whichever ends first). With several working sessions the cards page horizontally with dots. *Zrušit* cancels a running countdown.
3. **Waiting card** when a session waits for your answer. *Otevřít* walks up the process tree from the Claude PID to the app that owns it (Terminal, iTerm, Ghostty, VS Code…) and brings it to the front; if none is found it opens the Claude app.
4. **Tiles**: lid, battery (the symbol is green only while charging), temperature (`ProcessInfo.thermalState`: nominal = Normální, fair = Zvýšená, serious/critical = Vysoká).
5. **+1 h vzhůru** and **Uspat hned**.
6. **…** (top right): History, Settings, Quit. History, Settings and Self-test open in their own small windows.

The setup checklist, power errors and guard notices (low battery, heat, time limit) appear as extra cards only when they apply.

## Edge notch and Claude usage

A 5×56 pt glass pill sits on the right edge of the screen (vertically centred by default; position 20–80 % in Settings). It grows to 9×72 pt when the pointer comes within about 12 pt. Rest on it for 180 ms (configurable) and a card slides out; move away from both and it hides after 400 ms. Click the card to **pin** it. **⌥⌘U** (configurable, can be turned off) toggles the card from anywhere.

- The notch and card are borderless `NSPanel`s with `.nonactivatingPanel`: they never activate Vigil. The notch never becomes key; the card becomes key only when you click into it (`becomesKeyOnlyIfNeeded`), never on hover, so it never takes focus from the app you are typing in. Hover comes from an `NSTrackingArea` on the panel: no Accessibility permission. The shortcut is a Carbon `RegisterEventHotKey`.
- It never opens while a mouse button is held (dragging a window to the edge), stays 80 pt away from the corners (Hot Corners), and sits inside `visibleFrame`, so a Dock on the right keeps it just inside the Dock.
- One notch per display, or only the main display. The notch works in full-screen apps too. Optionally (*Skrýt v aplikacích na celou obrazovku*, **default off**) it hides while a **native full-screen Space** is showing on that display. A maximized (zoomed, "Fill") window never counts. Detection is a pure function (`FullScreenDetector`) over the window list, which needs no Screen Recording permission. It uses two signals seen on every full-screen Space and on no regular one: the app's transparent reveal strip across the top of the display, and the Dock's full-screen backdrop one layer above its wallpaper. Window size is not a signal: with the menu bar shown in full screen, the window is as tall as a maximized one. Checked only on a Space change, a screen-parameter change and wake, debounced by 300 ms, and never because one of Vigil's own windows appeared (they are left out of the snapshot). **⌥⌘U opens the card even while the notch is hidden.**
- **One state machine** (`NotchMachine`: hidden / idle / hovering / open / pinned) drives the notch and the card. Every transition is logged: `log show --predicate 'subsystem == "cz.krystof.vigil" AND category == "notch"'`, and the same lines appear in Vigil's own log as `notch: …`.
  - A hide never happens while the pointer is on the notch or the card, or while the card is pinned. It waits until the pointer leaves ("hide deferred").
  - Every hide invalidates all pending timers and forgets where the pointer was. Every show starts from idle and re-creates the tracking areas.
  - A watchdog resets to idle (and logs it) if the card or notch on screen disagrees with the state for more than a second. "On screen" is the window server's `kCGWindowIsOnscreen` (`CGWindowListCopyWindowInfo`), never `NSWindow.isVisible`.
- **Self-healing.** On 30 Oct 2026, after 18 days of runtime with sleeps and display changes, the card panel created at launch was still "visible" to AppKit but not on screen for the window server: the machine opened it, no hover ever reached it, and it closed after the 400 ms hide delay. So:
  - On wake (system and displays) and on every screen-parameter change, every notch and card panel is thrown away and built anew (`rebuilding the notch and card panels (wake)` in the log). A panel created while a native full-screen Space shows would stay on that Space without mouse events, so the rebuild waits for a regular Space (`rebuild deferred …`).
  - Right after the card opens, Vigil checks that the window server shows it; if not, it gets a new panel at once (`repair: the card was opened but is not on screen`).
  - Every 30 s a health check (`NotchHealth`) compares the machine with the screen: notch and card on screen as the state says, tracking areas installed, one notch per display. Anything wrong is logged (`health check repaired: …`) and everything is rebuilt.
  - The hide timer looks at the pointer before closing: on the card or the notch (a transparent edge, a missed `mouseEntered`), the card stays (`hide skipped: …`).
  - **…** ▸ *Obnovit notch* rebuilds by hand. Every pointer enter and exit is logged (`notch: pointer entered the card`).
- Self-test ▸ *Notch na okraji*: whether the notch is visible and why not, the frontmost app, whether a full-screen Space is showing, and a hover test: it opens the card through the hover path (without moving the pointer) and checks that the window server shows it.
- **Closing a pinned card**: click the notch, press **⌥⌘U**, click the **×** in the card header, or click anywhere outside the card. The outside click is seen by a `leftMouseDown` monitor that runs only while the card is pinned; it watches the mouse only, never keys, so it needs no Accessibility permission.
- **Esc** closes the card only after you have clicked into it (the card is then the key window). Vigil never registers Esc system-wide, so Esc always reaches Claude Code, where it interrupts.

**The card** (Liquid Glass via `.glassEffect()` on macOS 26, `.ultraThinMaterial` with a hairline and a soft shadow before that) is monochrome. Its only colours are warnings: a bar turns orange at 80 % and red at 95 %, a context ring turns orange at 80 % (*brzy auto-compact*). It shows:

- *Aktuální relace* (5-hour window) and *Tento týden* (weekly window): percentage, bar, reset time, and for the week a pace line comparing used % with the elapsed share of the week (*Tempo v pořádku* or *Při tomto tempu limit dojde v pátek kolem 14:00*).
- How fresh the data is, by when the numbers were last **new**: they changed, or they came with a new API response. That is when the session's `cost.total_api_duration_ms` grows. A status line re-run that repeats the old numbers doesn't count. After 10 minutes the bars are dimmed, the card shows *Data z 14:02* and says *Chat v aplikaci Claude se tu projeví až při další práci v Claude Code*. The reset countdowns keep running (they need no new data); once a window's reset time has passed it shows *Obnoveno · 0 %*. The next status line from any Claude Code session updates everything at once.
- **Why chat doesn't move the numbers:** chat in the Claude app uses the same plan limits, but Vigil only learns them from Claude Code's status line, after a Claude Code API response. There is no documented way to read them otherwise; Vigil uses no private endpoints and never reads tokens from the Keychain.
- Up to three Claude Code sessions with model name and context-window use, then the Vigil state and **+1 h** / **Uspat** buttons.

**Where the numbers come from.** Only documented sources: Claude Code pipes JSON to the status line command on stdin. Since v2.1.80, when you are logged in with a **Claude.ai Pro or Max** subscription, it includes `rate_limits.five_hour` and `rate_limits.seven_day` (`used_percentage`, `resets_at` in epoch seconds), plus `session_id`, `cwd`, `model.display_name` and `context_window.used_percentage`. `rate_limits` appears only **after the first API response** of a session. Vigil does not call undocumented endpoints and does not read OAuth tokens from the Keychain. With an API key or an older Claude Code the card says why it is empty; everything else keeps working.

**The status line wrapper** (`~/Library/Application Support/Vigil/statusline.sh`, installed through the same backed-up settings.json merge as the hooks):

- reads stdin once and forwards the JSON to `vigil.sock` in the background (`nc -U -w 1`), so it never blocks;
- if you already had a `statusLine` command, runs it with the same stdin and prints its output unchanged;
- otherwise prints one short line, e.g. `Claude 42 % · týden 15 %`;
- always exits 0.

Your previous `statusLine` object is saved verbatim in `statusline.original.json` (its command in `statusline.chain`), and Vigil's entry keeps its other keys such as `padding`. **Remove** (Settings ▸ Status line, or `uninstall.sh`) puts it back exactly, or drops the key if there was none. Installing twice changes nothing.

**Notifications** (on by default): the 5-hour window crosses 80 % and 95 %, the weekly window crosses 80 %, and *Limit obnoven — můžete pokračovat* when a window with usage in it resets. Each fires once per window cycle. The last known values are kept in `usage.json`.

## How it works

```
Claude Code ──hook──▶ hook.sh ──nc -U──▶ vigil.sock ──▶ StateMachine ──▶ effects (pmset, IOPM, notifications)
```

**Hooks** (installed into `~/.claude/settings.json`, each marked by the command path `…/Vigil/hook.sh` so they can be removed cleanly, and stamped with the hook-set version, e.g. `…/hook.sh" Stop --vigil-hooks=4`):

| Hook | Meaning |
|---|---|
| `SessionStart` | a session exists (idle) |
| `UserPromptSubmit` | **working** |
| `Stop` | done (idle) |
| `Notification` | depends on `notification_type`: `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input` = **waiting for you**; `idle_prompt` = idle (Claude finished, the prompt sits idle); anything else is logged and ignored |
| `PermissionRequest` (matcher `*`) | a permission dialog is shown: **waiting for you** (a second signal next to `Notification`). `hook.sh` never prints a decision, so Claude Code always asks as usual |
| `SessionEnd` | session gone |
| `PostToolUse` (matcher `*`) | *heartbeat*: a tool ran, so a waiting session has been answered and is **working** again (see below) |
| `SubagentStart` | a subagent (Agent tool, background agent) started: the session is **working** |
| `SubagentStop` | that subagent finished |
| `TaskCreated` | Claude added an item to its task list (`task_id`, `task_subject`): **work-time estimate only** |
| `TaskCompleted` | Claude completed an item: **work-time estimate only**. Exit code 2 from this hook (or `TaskCreated`) would *cancel* the task, which is one more reason `hook.sh` always exits 0 |

`hook.sh` (installed at `~/Library/Application Support/Vigil/hook.sh`) reads the hook JSON on stdin, walks up the process tree to find the `claude`/`node` PID, and sends one JSON line to the app's Unix socket with `/usr/bin/nc -U -w 1`. It **always exits 0, prints nothing**, and does nothing if Vigil is not running (≈10-15 ms per call).

**Why `PostToolUse`?** When you approve a permission prompt, Claude Code fires *no* `UserPromptSubmit`, so a session that had sent a `Notification` would stay "waiting" while Claude works again (and under *Sleep after a delay* the Mac could go to sleep mid-task). The heartbeat flips a *waiting* session back to *working*. It also lets Vigil adopt a session it missed (for example if Vigil restarted mid-task; PID required). It never revives an *idle* session. Remove it by deleting the `PostToolUse` entry if you don't want it; everything else keeps working.

**Hook versions.** When Vigil's hook set changes (version 2 added `SubagentStart`/`SubagentStop`; version 3 added `PermissionRequest` and the `*` matcher on `PostToolUse`; version 4 added `TaskCreated`/`TaskCompleted`), Vigil notices that the entries in `settings.json` are older than the app and shows **Update hooks** in Settings, in the setup checklist and in the self-test. Updating backs up `settings.json`, replaces only Vigil's own entries (whatever version they are) and leaves every other hook untouched, including hooks that share a group with Vigil's. Running it twice changes nothing. **Already-running Claude Code sessions must be restarted** to pick up the new hooks.

**Subagents.** The main agent can end its turn (`Stop`) while subagents it started keep working. Vigil keeps a set of active subagents per session, keyed by `agent_id` (with `agent_type` and start time): `SubagentStart` adds one, `SubagentStop` removes it. A `SubagentStop` for an agent Vigil never saw start (for example Vigil launched mid-session) is ignored.

**Busy: one derived state per session** (`StateMachine.busyReasons`). A session keeps the Mac awake while it has any of these, and every change is logged (`busy ferrun (7335456a): shell active (npm test)`):
- **turn**: `UserPromptSubmit` without a `Stop` since. Auto-continued turns (a background task finished and Claude goes on by itself) arrive as `UserPromptSubmit` too, carrying a `<task-notification>` or an `<agent-message>`.
- **subagents**: `SubagentStart` without `SubagentStop`, matched by `agent_id`, background agents included. A tool call carrying an unknown `agent_id` adopts that agent (it started before Vigil did).
- **background shells**: a `Bash` call with `run_in_background` (its `PostToolUse` returns `backgroundTaskId`). `Stop` and `SubagentStop` carry Claude Code's own list, `background_tasks`, which is the main signal: a shell listed as `running` keeps the session busy until it ends, whatever its CPU (a `gh run` wait loop uses almost none and is still work). It ends with the `<task-notification>` Claude Code feeds back, `TaskStop`/`KillShell`, the next `background_tasks` without it, or when its process disappears. Vigil finds the process among the descendants of the session's Claude process (the `eval '…'` of Claude Code's wrapper shell) every 5 s and watches the CPU of its process tree.
  - **Servers** (`npm/pnpm/yarn run dev`, `next dev`, `vite`, `stripe listen`, `serve`, `http.server`, `docker compose up`, `tail -f`, …) run until stopped, so they count only while they work: after 5 minutes under 2 % CPU (averaged over the last 5 minutes) they no longer keep the Mac awake.
  - Settings ▸ *Shelly na pozadí*: *Dokud běží, kromě serverů* (default), *Vždy, dokud běží*, *Ignorovat*. The popover and the card show *1 shell běží · npm test* with **Ignorovat** for a single shell.
- **recent activity**: any activity hook (`PostToolUse`, `SubagentStart`, a known `SubagentStop`, `TaskCreated`/`TaskCompleted`, `UserPromptSubmit`, `PermissionRequest`, `SessionStart` with `source: compact`) in the last 2 minutes. Compaction is activity, never a fresh start: no `SessionStart` (`resume`, `clear`, `compact`) resets a session. `Stop`, `SessionEnd`, `Notification` and the `SubagentStop`s of Claude Code's internal agents (no `agent_type`, unknown `agent_id`: away summary, compaction) are not activity and are ignored.
- **waiting** for your answer (below).

**Rules**
- A session is **working** while it is busy by the list above (waiting aside).
- The Mac may sleep only when **all** sessions are idle by that definition or ended. A session **waiting for you** keeps the Mac awake under the default policy (see below).
- `Stop` while subagents are still running only marks the main agent idle; no countdown starts. The countdown starts when the **last** `SubagentStop` arrives, and a `SubagentStart` during the countdown cancels it.
- **Stuck-subagent guard**: a subagent with no `SubagentStop` for longer than the *stuck subagent limit* (default 2 h) is dropped with a warning in the log. `SessionEnd` or a dead Claude process clears all of that session's subagents.
- After the last session goes idle, Vigil asks the **sleep gate** (below). Only if it says yes does a **grace period** (default 30 s) start: the countdown you see ("Sleeping in 0:24") and the notification with **Cancel** / **Keep awake**. A new prompt, any keyboard, mouse or trackpad input, or opening the lid cancels it (checked every second) and Vigil goes back to *Připraveno*.
- If the gate says no, there is no countdown and no notification: Vigil releases its keep-awake at once, macOS sleeps by your Energy settings, and the island shows *Hotovo · Mac běží normálně*.
- When the countdown expires: `pmset -a disablesleep 0` is restored **first**, the gate is asked once more with a fresh reading, then `pmset sleepnow`. Always in that order (the executor is a single ordered queue).
- Ctrl+C fires no `Stop`, so every 10 s Vigil checks each session's PID with `kill(pid, 0)` and drops dead ones. A "working" session with no events for longer than the max duration is dropped too.
- `hook.sh` records the session's own Claude process. A background session (`claude --bg`, the agents view) runs as `claude bg-spare` under `claude bg-pty-host` under one shared `claude daemon`: the hook takes the `bg-spare` process, never the shared ones above it (before, every background session got the daemon's PID).
- **Silence failsafe**: work stops counting after **30 minutes without any activity**: no hook and no change in the session's processes (new or ended processes, or CPU used by anything under Claude except its helpers: caffeinate, MCP and language servers, Vigil's scripts). Long work with the lid closed is never cut while anything moves; the absolute limit is the max keep-awake (12 h).
- **Waiting for your answer** (Settings ▸ *When Claude is waiting for an answer*):
  - *Keep awake* (default): a waiting session counts as busy, so you can answer permission prompts and questions from your phone through Claude Code Remote Control while the lid is closed. The island shows *Čeká* in orange. `PostToolUse` (or a new prompt) moves the session back to working once you have answered.
  - *Maximum wait for an answer* (default 2 h, 30 min to 8 h): after waiting that long Vigil notifies you and starts the normal sleep countdown. Answering later still works; the next wait gets a fresh timer.
  - *Sleep after a delay*: waiting counts as idle and the grace-period countdown starts.
  - `idle_prompt` is never "waiting": it cannot keep the Mac awake or restart a countdown.
  - Upgrading: a policy still at the old default (*Sleep after a delay*) moves to *Keep awake* once (settings revision 3). A policy you changed yourself is kept, and choosing *Sleep after a delay* again afterwards sticks.

### The sleep gate

Every automatic sleep (the countdown after Claude finishes, the end of *+1 h vzhůru*, the maximum wait for an answer, the max keep-awake failsafe, the battery and thermal guards) goes through one pure function, `SleepGate.decide`, over a snapshot read fresh at that moment. Only **Uspat hned** bypasses it.

- **Lid closed and no external display active** (`AppleClamshellState`, and `CGDisplayIsBuiltin` over the active displays): allowed. Nobody can be using the Mac.
- **Otherwise** (lid open, or closed-lid desktop mode with an external display): not allowed. Vigil only releases its own keep-awake (`disablesleep 0`, drops its IOPM assertions) and hands power management back to macOS.
- **S otevřeným víkem uspat po nečinnosti** (Settings; *Nikdy* by default, or 5 / 10 / 20 min): with the lid open, a forced sleep is allowed after that long without keyboard, mouse or trackpad input (`CGEventSource.secondsSinceLastEventType(.combinedSessionState, anyInputEventType)`; no Accessibility permission).
- **Another app keeping the Mac awake** (a `PreventUserIdleDisplaySleep` or `PreventUserIdleSystemSleep` assertion, from `IOPMCopyAssertionsByProcess`: video, calls, presentations) blocks it. Vigil's own assertions, powerd's permanent "Prevent sleep while display is on" and the `caffeinate` Claude Code spawns for itself (a caffeinate whose parent is `claude`) don't count. This rule does not apply with the lid closed and no external display.
- **No reading yet** (just launched): never force sleep blind.
- Every decision is logged with its reason (`sleep: lid closed, no external display [countdownExpired]`, `skip: lid open, user active 12 s ago …`, `skip: assertion held by zoom.us`) and kept in History ▸ *Relace* ▸ *Rozhodnutí o spánku* (`sleep-decisions.json`, last 100). The self-test has a *Pojistka uspání* check that prints what the gate reads and would decide right now.
- This replaces the old *Only sleep if the lid is closed* option. It read a cached lid state, which is how the Mac could be put to sleep while you were using it.
- While awake, Vigil holds `pmset disablesleep 1` (lid-closed, on battery) **and** IOPM assertions `PreventUserIdleSystemSleep` + `PreventSystemSleep` (idle sleep).

### Work-time estimate

While Claude works, Vigil estimates how long the current turn (your prompt → Claude's `Stop`) will still take. It is **information only**: it lives in its own `TurnTracker` and the state machine never sees it, so it can never keep the Mac awake or put it to sleep (a test replays the same hooks with and without task events and checks that every sleep decision is identical).

**Signals.** Task list progress from `TaskCreated`/`TaskCompleted`, plus the `PostToolUse` calls of `TaskCreate`/`TaskUpdate` (the start of a task, `in_progress`, only comes from there) and, for older Claude Code versions, `TodoWrite` (the whole list every time). The field names were taken from payloads recorded on a real machine, which are kept as test fixtures (`Tests/VigilTests/Fixtures`). Also the `PostToolUse` heartbeat (tool count, last activity) and subagent start/stop.

**Model** (small pure functions, the clock is always passed in):
- **With a task list** (N items, k done): remaining ≈ what is left of the current task + (N − k − 1) × time per task. Time per task blends this turn's average with the project's historical median, and this turn weighs more as more items are done (k / (k + 2)). The current task's elapsed time counts, and a slow task never makes its own remainder negative. If the list grows, the estimate is recomputed and the popover shows *+2 kroky* for 30 s.
- **Without a task list**: conditional history. From this project's past turns (all projects when there are fewer than 5) take those that already lasted longer than this one; the range is the 25th–75th percentile of how much longer they went on.
- **Subagents**: while one runs, the remaining time is at least the typical remaining time of that `agent_type` from history.
- **No task list and fewer than 5 comparable past turns: no estimate.** The row, the middle footer column and the notch value disappear.
- The display is smoothed (an exponential moving average of the *finish time*, τ = 30 s), so it doesn't jump with every tool call.
- **Confidence**: high needs at least 3 finished items with an even pace; history alone is never more than medium. Low confidence is shown in the secondary colour and with a wider range (±55 % instead of ±30 % or ±15 %).
- **Rounding**: under 10 min to 1 min, under 1 h to 5 min, above that to 15 min. Never "0" while working; under a minute it says *brzy*.
- **Time spent waiting for you** (a permission prompt or a question) is excluded: it says nothing about how long the work takes.

**What it can't know**: plan changes Claude hasn't written into its task list yet; items of very different size (one "refactor" and six "rename" items count the same); how long you take to answer; anything about a turn with no task list and too little history (then it shows nothing rather than guess).

**Where it shows**: a step row in the popover's session card (*Krok 4 ze 7 · hotovo asi v 21:15 (±5 min)* and the task in progress, or *Bez seznamu úkolů / Podle 14 podobných úkolů v projektu*); a segmented track, one segment per task, ending in a flag; a three-column footer *Běží · Zbývá (or Obvykle ještě) · Vzhůru ještě*; optionally the island (Settings ▸ *Ostrov během práce ukazuje*: *Čas běhu* / *Odhad*); each session row of the edge notch card (*Opus · krok 4/7 · kontext 42 %* and *~12 min*); and an optional notification, off by default, once per turn with medium or high confidence (*rasinova-residence: hotovo asi za 5 min*).

**History and accuracy.** Every finished turn is stored in `turns.json` (last 500): duration, active duration, the number of tasks and each task's duration, subagents and their types, and the estimate shown at 25, 50 and 75 % of the run. History ▸ *Přesnost odhadů* scores each turn on its earliest estimate: *Průměrná chyba* (last 20), *Trefa do rozsahu* (actual inside the range) and *Trend* (this week vs last week), plus a table per turn. Settings ▸ *Smazat historii odhadů* clears it. A turn interrupted without `Stop`, or one Vigil only saw part of (started mid-turn), is never stored.

### Safety

A stuck `disablesleep 1` in a backpack is dangerous, so there are several independent layers:

- **Restore on**: Quit, `SIGTERM`/`SIGINT`/`SIGHUP`, logout/shutdown, and at launch if `SleepDisabled = 1` without an active session. Every 10 s Vigil also re-checks and undoes a stuck value.
- **Watchdog**: when `disablesleep 1` is set, a detached shell watches the app's PID and runs `sudo -n pmset -a disablesleep 0` if the app dies (crash or `kill -9`). Verified: restored ~0.6 s after `SIGKILL`.
- **Silence failsafe** (30 min without activity, see Rules) and **max keep-awake** (default 12 h, 4 to 24 h): restore, and sleep if the gate allows. Settings revision 4 moved everyone from the old 2-hour limit to 12 hours.
- **Battery guard** (default 5 %, can be turned off): on battery below the threshold, restore normal sleep with a notification, and sleep at once if the gate allows (lid closed, no external display). Otherwise macOS takes over sleep instead of Vigil forcing it.
- **Thermal guard**: `ProcessInfo.thermalState` of `.serious`/`.critical` with the lid closed: restore, and sleep immediately if the gate allows.

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

Watch Claude Code on/off, launch at login, grace period (10 s to 5 min), background shells, maximum keep-awake (4 to 24 h), stuck subagent limit (30 min, 1, 2 or 4 h), low-battery threshold, sleep with the lid open after inactivity (never / 5 / 10 / 20 min), waiting-for-an-answer policy and maximum wait (30 min to 8 h), island content (elapsed time / estimate), "almost done" notification, clear estimate history, install/update/remove hooks, install/remove sleep permission, Dry run, Run self-test, Open log. **Look**: accent colour (green, blue, orange, purple). **Edge notch and usage**: notch on/off, position on the edge, displays (all / main), hover delay, hide in full-screen apps, keyboard shortcut (record a new one, or turn it off), usage notifications, install/remove the status line.

**Dry run** goes through the whole flow (working → idle → countdown → restore → sleep) but only logs `would run: pmset …`, and never calls `pmset`. While anything is busy it logs `[dry-run] would NOT sleep: shell active (sleep 300)` once a minute. For testing the closed-lid path at the desk, `defaults write cz.krystof.vigil vigil.debug.simulateLidClosed -bool true` makes the sleep gate see a closed lid with nobody at the Mac (dry run only; `defaults delete` it afterwards). Use *Simulate a session* to watch it happen (the simulated session includes a subagent that outlives the main agent's `Stop`).

While subagents run, the session card reads *Hlavní agent + 2 subagenti*. When every main agent is done but subagents still run, the island keeps counting and the menu bar icon stays in the working state (its tooltip says *Subagents working*).

Data lives in `~/Library/Application Support/Vigil/`: `hook.sh`, `statusline.sh` (+ `statusline.original.json`, `statusline.chain`), `usage.json` (last known limits and per-session model/context), `vigil.sock`, `sleep-decisions.json` (every sleep or skip with its reason, last 100), `turns.json` (last 500 finished turns for the work-time estimate), `history.json` (last 50 sessions: project, start, duration, how it ended, most subagents at once and total subagent time), `logs/vigil.log` (rotating, 1 MB × 3). Preferences are in `defaults read cz.krystof.vigil`.

## Troubleshooting

| Symptom | Check |
|---|---|
| Icon never turns to "working" | Popover ▸ *Run self-test*. `grep "hook " ~/Library/Application\ Support/Vigil/logs/vigil.log`. Are the hooks in `~/.claude/settings.json` (`grep Vigil ~/.claude/settings.json`)? Restart the Claude Code session. |
| Mac slept while a subagent was running | That Claude Code session was started before the subagent hooks were installed. Settings ▸ *Update hooks* if it is offered, then **restart Claude Code** so the new hooks load. Check with `grep Subagent ~/Library/Application\ Support/Vigil/logs/vigil.log`. |
| A session stays "working" long after its subagents finished | A `SubagentStop` got lost. The stuck-subagent guard drops it after the limit (Settings ▸ *Stuck subagent limit*); look for `dropped stuck subagent` in the log. |
| "Couldn't change sleep settings" | The sudoers rule is missing: run `sudo -n -l` and look for the two `pmset` commands, or click *Install sleep permission*. |
| `pmset -g \| grep SleepDisabled` shows 1 with Vigil not running | `sudo pmset -a disablesleep 0` (relaunching Vigil also fixes it). |
| Hook commands fail in Claude Code | `hook.sh` missing? Vigil restores it at launch and every 10 s while running. Or click *Install hooks* again. |
| Usage card says "No limits yet" | Limits arrive only with a Claude.ai Pro/Max login, Claude Code 2.1.80+, and after the first response of a session. `grep usage ~/Library/Application\ Support/Vigil/logs/vigil.log`. Self-test ▸ *Status line* must be green. |
| My old status line disappeared | Settings ▸ *Status line* ▸ *Remove* restores it exactly (it is in `statusline.original.json`). While installed it is still run through `statusline.chain`. |
| The Mac went to sleep while I was using it | It should not any more: `grep -E "sleep:|skip:" ~/Library/Application\ Support/Vigil/logs/vigil.log` shows every decision and why, and History ▸ *Rozhodnutí o spánku* lists them. A `pmset -g log` line "Software Sleep" at the same second as a `sleep:` line is Vigil; the log says which gate rule allowed it. |
| The notch does nothing in a full-screen app | Self-test ▸ *Notch na okraji* says why and shows the state. With *Skrýt v aplikacích na celou obrazovku* on it is hidden there on purpose: use ⌥⌘U. The `notch` log category shows every transition. |
| Usage numbers don't change while I chat in the Claude app | Expected: only Claude Code reports them. The card dims old numbers and says when they are from. |
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

It quits Vigil (which restores sleep), removes only Vigil's entries from `~/.claude/settings.json` and puts your previous `statusLine` back (timestamped backup first), deletes `/etc/sudoers.d/vigil` (password), makes sure `SleepDisabled` is 0, and deletes the app, its data and its preferences. By hand: `sudo rm /etc/sudoers.d/vigil`, remove entries containing `Vigil/hook.sh` from `settings.json` (or restore a `settings.json.vigil-backup-*`), then delete `Vigil.app` and `~/Library/Application Support/Vigil`.

## Manual test checklist

1. `./build.sh && open build/Vigil.app`, complete the checklist, **Run self-test**: all seven checks green.
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
11. Usage: after a response in Claude Code (Pro/Max login), hover the right screen edge: the card shows both windows and the session. Drag a window to the right edge with the mouse held: the card must not open. Click the card: it pins (× appears). Press Esc in a terminal: the terminal gets it and the card stays. Click into the card, press Esc: it closes. Pin again, click the desktop: it closes. ⌥⌘U toggles it.
12. Battery/thermal guards: unplug and set the threshold above the current level (Settings ▸ Low battery threshold): Vigil restores and sleeps at once.

## Development

```bash
swift build                    # debug build (Vigil.app is assembled only by build.sh)
./build.sh --test              # unit tests + release build
Vigil --snapshot <dir>         # render the popover, windows and usage card to PNGs, no permissions needed
```

Layout: `Sources/VigilCore` (StateMachine, SleepGate + PresenceReader, FullScreenDetector + NotchMachine, TurnTracker + EtaModel + EtaAccuracy + TaskSignals (work-time estimate), HookServer, PowerController, SettingsInstaller = `ClaudeSettingsMerger` + `HookInstaller` + `SudoersInstaller`, StatusLine (parser) + StatusLineInstaller + StatusLineScript, Usage (limits, pace, rollover, alerts), CzechPlural, ProcessTree, Notifier, BatteryThermalMonitor, Persistence, SelfTest, Logging), `Sources/Vigil` (AppKit shell, SwiftUI popover, AuxWindows, EdgeNotch + UsageCardView, HotKey), `Tests/VigilTests` (237 tests: the notch state machine (Space change while hovering, pending timers after a hide, hover after re-show, pinned through a Space change, watchdog recovery, shortcut while hidden), full-screen detection against window snapshots recorded on a real Mac (native full screen with the menu bar shown, maximized and ordinary windows), usage freshness (status line re-runs vs new API responses, staleness, reset rollover) against a recorded status line, the sleep gate (lid closed / open / desktop mode, idle threshold, foreign assertions, Claude's own caffeinate, countdown cancelled by input and by opening the lid, "Uspat hned" always sleeps, guards through the gate), the work-time estimate (task model with steady pace / growing list / one slow task, conditional history percentiles, subagent floor, rounding and "brzy", EMA, accuracy statistics, z/ze and krok/kroky/kroků) and the task parsers against recorded fixtures, state machine incl. multi-session/grace/interrupt/cancel, subagents and the waiting-for-an-answer policy (every `notification_type`, `PermissionRequest`, max wait), pinned-card rules, settings.json merger incl. missing/invalid/idempotent/removal and the v1 → v2 hook upgrade, status line parser with and without `rate_limits`, pace, reset rollover and threshold alerts, Czech plurals, status line installer (no previous / chained / exact restore / idempotent / invalid JSON) and the real `statusline.sh` against a socket, settings migration, PID liveness, socket + real `hook.sh` round trips, watchdog script, localization completeness and the formal Czech tone). Tests never touch your real preferences: each one gets its own `UserDefaults` suite (`TestDefaults`) whose name is an absolute path in a temp directory, removed in tearDown. A plain suite name would not do: cfprefsd leaves an empty `~/Library/Preferences/<suite>.plist` behind even after `removePersistentDomain`.

The Command Line Tools ship without SwiftUI's macro plugin, so views cannot use `@State`; view state lives in `@Observable` objects instead.

- **Tests** use Swift Testing. On a Command-Line-Tools-only machine the testing macro plugin is not on the default path; `build.sh --test` passes `-plugin-path` for you. By hand: `swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"`.
- **Localization**: `Resources/Localizable.xcstrings` is the source of truth (Xcode-compatible). Code calls `L("English text")`. `build.sh` generates `en.lproj`/`cs.lproj` from it and **fails the build** if the code uses a string that is missing or has no Czech translation.
- **Icon**: `swift Scripts/make_icon.swift Resources/Assets.xcassets` renders it with CoreGraphics into the asset catalog; `build.sh` turns the PNGs into `AppIcon.icns` with `iconutil`.
- **Signing**: ad-hoc by default (`codesign --sign - --options runtime`). For a stable identity: `SIGN_IDENTITY="Apple Development: you (TEAMID)" ./build.sh`. The app is **not notarized**; a locally built copy has no quarantine flag and opens normally. The App Sandbox is off (needs `~/.claude`, `pmset`, a socket); Hardened Runtime is on with no exceptions.
- **Xcode**: `project.yml` (XcodeGen) is provided (`xcodegen generate`), but it has **not been run through `xcodebuild`** because Xcode is not installed on the development machine. SwiftPM + `build.sh` is the verified path.

## Known limitations

- The countdown notification cannot tick live (macOS does not update delivered notifications); the popover and the menu bar title show the real countdown.
- Closing the lid needs `disablesleep`, which requires the sudoers rule; without it Vigil still holds idle-sleep assertions (lid-open case) and says so in the UI.
- The usage numbers are only as fresh as the last status line update from a running Claude Code session; the card says how old they are.
- `--snapshot` renders offscreen, where Liquid Glass and materials draw flat; the live card is translucent.
- The lid-closed / real-sleep behavior (checklist steps 4-5) has to be verified by hand on your machine.
