import Foundation

/// The forwarder installed at ~/Library/Application Support/Vigil/hook.sh.
/// Contract: ALWAYS exit 0, print nothing, stay fast, never block Claude Code (even if Vigil is not running).
public enum HookScript {
    public static let contents = #"""
    #!/bin/sh
    # Vigil hook forwarder - installed and managed by Vigil.app. Safe to delete (re-installed on demand).
    # Reads Claude Code's hook JSON on stdin, adds the event name and the Claude PID and hands it to the
    # Vigil app over a Unix domain socket. Always exits 0 and prints nothing.
    exec >/dev/null 2>&1
    trap 'exit 0' EXIT INT TERM HUP

    EVENT="$1"
    case "$EVENT" in ""|*[!A-Za-z]*) cat >/dev/null; exit 0 ;; esac

    SOCK="${VIGIL_SOCKET:-$HOME/Library/Application Support/Vigil/vigil.sock}"
    if [ ! -S "$SOCK" ]; then
      cat >/dev/null   # Vigil is not running: drain stdin and do nothing.
      exit 0
    fi

    # Walk up the process tree to find the Claude process (claude / node). Costs ~7 ms.
    PID=0
    set -f
    p=$$
    i=0
    while [ "$i" -lt 12 ] && [ "$p" -gt 1 ] 2>/dev/null; do
      line=$(/bin/ps -o ppid=,comm= -p "$p" 2>/dev/null) || break
      set -- $line
      ppid=$1
      shift
      name="$*"
      name=${name##*/}
      case "$name" in
        claude|claude-code|node) PID=$p; break ;;
      esac
      p=$ppid
      i=$((i + 1))
    done
    set +f

    PAYLOAD=$(cat | /usr/bin/tr '\n\r' '  ')
    [ -n "$PAYLOAD" ] || PAYLOAD='{}'

    printf '{"vigil_event":"%s","pid":%s,"payload":%s}\n' "$EVENT" "$PID" "$PAYLOAD" \
      | /usr/bin/nc -U -w 1 "$SOCK"
    exit 0
    """#
}
