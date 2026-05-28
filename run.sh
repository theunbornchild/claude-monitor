#!/bin/bash
# ◆ Claude Monitor launcher

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/.build/claude-widget-window"

# ── Kill any existing instance ────────────────────────────────────────────────
lsof -ti:2727 | xargs kill -9 2>/dev/null
pkill -f claude-widget-window 2>/dev/null
sleep 0.2

# ── Compile if missing or stale ───────────────────────────────────────────────
if [ ! -x "$BINARY" ] || [ "$SCRIPT_DIR/widget-window.swift" -nt "$BINARY" ]; then
  if ! command -v swiftc &>/dev/null; then
    echo "✗ swiftc not found. Run: xcode-select --install"
    exit 1
  fi
  echo "◆ Building widget window…"
  mkdir -p "$SCRIPT_DIR/.build"
  swiftc "$SCRIPT_DIR/widget-window.swift" -o "$BINARY"
fi

# ── Start server ──────────────────────────────────────────────────────────────
python3 "$SCRIPT_DIR/server.py" &
echo $! > /tmp/claude-widget.pid
sleep 0.5

# ── Open native window ────────────────────────────────────────────────────────
"$BINARY" &>/dev/null &

echo "◆ Claude Monitor running on http://localhost:2727"
echo "  Press Ctrl+C to stop"

wait $(cat /tmp/claude-widget.pid)
