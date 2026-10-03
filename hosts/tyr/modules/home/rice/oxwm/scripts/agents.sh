#!/usr/bin/env sh
# Number of agent sessions running on this box (claude, codex, hermes).
# Matches the program name only, so helper processes are not counted.
n=$(pgrep -fc '(^|/)(claude|codex|hermes)( |$)' 2>/dev/null)
echo "${n:-0}"
