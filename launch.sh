#!/bin/bash
# ◆ Claude Monitor — background launcher (for shortcuts / login items)
# Exits immediately after starting everything. No Ctrl+C needed.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/.build/claude-widget-window"

# ── Kill any existing instance ────────────────────────────────────────────────
lsof -ti:2727 | xargs kill -9 2>/dev/null
pkill -f claude-widget-window 2>/dev/null
sleep 0.2

# ── Compile if missing or stale ───────────────────────────────────────────────
if [ ! -x "$BINARY" ] || [ "$SCRIPT_DIR/widget-window.swift" -nt "$BINARY" ]; then
  mkdir -p "$SCRIPT_DIR/.build"
  swiftc "$SCRIPT_DIR/widget-window.swift" -o "$BINARY" 2>/dev/null
fi

# ── Start server (detached) ───────────────────────────────────────────────────
nohup python3 "$SCRIPT_DIR/server.py" > /tmp/claude-widget.log 2>&1 &
echo $! > /tmp/claude-widget.pid
sleep 0.5

# ── Open native window (detached) ────────────────────────────────────────────
nohup "$BINARY" > /dev/null 2>&1 &
