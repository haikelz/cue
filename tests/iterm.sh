#!/bin/sh
# Drive iTerm2 sessions by unique id, for tests/e2e.sh.
# usage: iterm.sh new | type <id> <text> | key <id> <ascii-code>... | screen <id> | close <id>
cmd=$1; shift
if [ "$cmd" = new ]; then
  exec osascript -e 'tell application "iTerm2" to return id of current session of (create window with default profile)'
fi
exec osascript - "$cmd" "$@" <<'AS'
on run argv
  set cmd to item 1 of argv
  set sid to item 2 of argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if id of s is sid then
            if cmd is "type" then
              tell s to write text (item 3 of argv) newline no
            else if cmd is "key" then
              set k to ""
              repeat with i from 3 to count of argv
                set k to k & (ASCII character ((item i of argv) as integer))
              end repeat
              tell s to write text k newline no
            else if cmd is "screen" then
              return contents of s
            else if cmd is "close" then
              tell s to close
            end if
            return "ok"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "missing"
end run
AS
