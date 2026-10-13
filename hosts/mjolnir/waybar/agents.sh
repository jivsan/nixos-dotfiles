#!/usr/bin/env sh
# Number of agent sessions running on this box (claude, codex, hermes), for
# the bar. Same count as tyr's bar: it matches the program name only, so
# helper processes are not counted.
n=$(pgrep -fc '(^|/)(claude|codex|hermes)( |$)' 2>/dev/null)
printf '{"text":"%s","tooltip":"agent sessions running (claude, codex, hermes)"}\n' "${n:-0}"
