import Foundation

/// The status line wrapper installed at ~/Library/Application Support/Vigil/statusline.sh.
/// Contract: fast, never blocks on Vigil, ALWAYS exits 0. It prints exactly what the user's previous status line
/// command prints (same stdin), or a short usage line if there was none.
public enum StatusLineScript {
    public static func contents(weekLabel: String = L("week")) -> String {
        // The label is baked in when the script is written; keep it shell-safe.
        let week = weekLabel.filter { $0.isLetter || $0 == " " }
        return #"""
        #!/bin/sh
        # Vigil status line wrapper - installed and managed by Vigil.app.
        # Remove it in Vigil > Settings > Status line: that restores your previous status line exactly.
        # 1. Forwards Claude Code's status line JSON to Vigil (in the background, 1 s timeout, never blocks).
        # 2. Prints your previous status line command's output unchanged (same stdin), or, if there was none,
        #    a short usage line. Always exits 0.
        trap 'exit 0' EXIT INT TERM HUP
        DIR="$HOME/Library/Application Support/Vigil"
        SOCK="${VIGIL_SOCKET:-$DIR/vigil.sock}"
        CHAIN="${VIGIL_STATUSLINE_CHAIN:-$DIR/statusline.chain}"

        INPUT=$(cat)
        [ -n "$INPUT" ] || INPUT='{}'

        if [ -S "$SOCK" ]; then
          ONELINE=$(printf '%s' "$INPUT" | /usr/bin/tr '\n\r' '  ')
          ( printf '{"vigil_event":"StatusLine","payload":%s}\n' "$ONELINE" | /usr/bin/nc -U -w 1 "$SOCK" ) </dev/null >/dev/null 2>&1 &
        fi

        # The self-test sets VIGIL_STATUSLINE_SELFTEST so it never runs your own command with fake data.
        if [ -z "$VIGIL_STATUSLINE_SELFTEST" ] && [ -s "$CHAIN" ]; then
          CMD=$(cat "$CHAIN")
          printf '%s\n' "$INPUT" | /bin/sh -c "$CMD"
          exit 0
        fi

        get() { printf '%s' "$INPUT" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
        pct() { LC_ALL=C /usr/bin/printf '%.0f' "$1" 2>/dev/null; }   # C locale: "42.4" must parse under any language
        FIVE=$(get rate_limits.five_hour.used_percentage)
        WEEK=$(get rate_limits.seven_day.used_percentage)
        LINE="Claude"
        if [ -n "$FIVE" ]; then
          LINE="Claude $(pct "$FIVE") %"
          [ -n "$WEEK" ] && LINE="$LINE · \#(week) $(pct "$WEEK") %"
        else
          MODEL=$(get model.display_name)
          [ -n "$MODEL" ] && LINE="Claude · $MODEL"
        fi
        printf '%s\n' "$LINE"
        exit 0
        """#
    }
}
