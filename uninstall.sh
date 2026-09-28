#!/bin/bash
# Removes everything Vigil put on this Mac. Safe to run more than once. Asks before each step.
#
#   ./uninstall.sh          interactive
#   ./uninstall.sh --yes    do everything without asking
#   ./uninstall.sh --hooks-only [--yes]   only remove the hook entries from settings.json (CLAUDE_SETTINGS=<file>
#                                         overrides the path; handy for trying it on a copy)
#
# Steps: quit the app (it restores normal sleep) -> remove our hooks from ~/.claude/settings.json (backup first)
#        -> remove /etc/sudoers.d/vigil (asks for your password) -> delete the app, its data and its settings.
set -uo pipefail

YES=0; HOOKS_ONLY=0
for a in "$@"; do
  case "$a" in --yes) YES=1 ;; --hooks-only) HOOKS_ONLY=1 ;; *) echo "unknown option: $a" >&2; exit 2 ;; esac
done
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
SUPPORT="$HOME/Library/Application Support/Vigil"

ask() { [ "$YES" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

quit_vigil() {
say "Quit Vigil"
if pgrep -x Vigil >/dev/null; then
  pkill -TERM -x Vigil
  for _ in $(seq 1 20); do pgrep -x Vigil >/dev/null || break; sleep 0.25; done
  pgrep -x Vigil >/dev/null && { pkill -KILL -x Vigil; echo "had to force-quit (watchdog will restore sleep)"; } || echo "quit"
else echo "not running"; fi
}

login_item() {
say "Login item"
osascript -e 'tell application "System Events" to delete (every login item whose name is "Vigil")' >/dev/null 2>&1 || true
echo "(if Vigil still shows under System Settings > General > Login Items, remove it there)"
}

remove_hooks() {
say "Claude Code hooks in $SETTINGS"
if [ -f "$SETTINGS" ] && grep -q "Vigil/hook.sh" "$SETTINGS"; then
  if ask "Remove Vigil's hook entries (a timestamped backup is made first)?"; then
    SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os, shutil, sys, time
path = os.environ["SETTINGS"]
raw = open(path, encoding="utf-8").read()
try:
    root = json.loads(raw)
except Exception as e:
    sys.exit(f"settings.json is not valid JSON ({e}); leaving it untouched. Remove the entries containing 'Vigil/hook.sh' by hand.")
hooks = root.get("hooks")
if not isinstance(hooks, dict):
    sys.exit("no hooks object; nothing to do")
removed = 0
for event in list(hooks):
    groups = hooks[event]
    if not isinstance(groups, list): continue
    kept = []
    for g in groups:
        hs = g.get("hooks") if isinstance(g, dict) else None
        if not isinstance(hs, list): kept.append(g); continue
        left = [h for h in hs if not (isinstance(h, dict) and "Vigil/hook.sh" in str(h.get("command", "")))]
        removed += len(hs) - len(left)
        if left: g["hooks"] = left; kept.append(g)
        elif len(left) == len(hs): kept.append(g)
    if kept: hooks[event] = kept
    else: del hooks[event]
if not hooks: del root["hooks"]
backup = f"{path}.vigil-backup-{time.strftime('%Y%m%d-%H%M%S')}"
shutil.copy2(path, backup)
tmp = path + ".vigil-tmp"
with open(tmp, "w", encoding="utf-8") as f: json.dump(root, f, indent=2, sort_keys=True, ensure_ascii=False); f.write("\n")
os.replace(tmp, path)
print(f"removed {removed} hook entries; backup: {backup}")
PY
  fi
else echo "no Vigil hooks found"; fi
}

remove_sudoers() {
say "Sleep permission (/etc/sudoers.d/vigil)"
if [ -e /etc/sudoers.d/vigil ]; then
  if ask "Remove /etc/sudoers.d/vigil (needs your admin password)?"; then
    sudo /bin/rm -f /etc/sudoers.d/vigil && echo "removed"
  fi
else echo "not installed"; fi
}

restore_sleep() {
say "Make sure sleep is back to normal"
if pmset -g | awk '/SleepDisabled/{print $2}' | grep -q 1; then
  echo "SleepDisabled is still 1 - restoring (asks for your password if the sudoers rule is already gone)"
  sudo /usr/bin/pmset -a disablesleep 0
else echo "SleepDisabled = 0"; fi
}

remove_app() {
say "App, data and settings"
if ask "Delete /Applications/Vigil.app, $SUPPORT and the saved preferences?"; then
  rm -rf /Applications/Vigil.app "$SUPPORT"
  defaults delete cz.krystof.vigil >/dev/null 2>&1 || true
  echo "deleted"
fi
}

if [ "$HOOKS_ONLY" = 1 ]; then remove_hooks; exit 0; fi
quit_vigil; login_item; remove_hooks; remove_sudoers; restore_sleep; remove_app
say "Done"
