#!/bin/bash
# ◆ Claude Monitor — one-time setup
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/.build/claude-widget-window"
PYTHON="$(command -v python3)"
AGENTS_DIR="$HOME/Library/LaunchAgents"
SERVER_PLIST="$AGENTS_DIR/com.claudewidget.server.plist"
WINDOW_PLIST="$AGENTS_DIR/com.claudewidget.window.plist"

echo ""
echo "  ◆ CLAUDE MONITOR — install"
echo "  ─────────────────────────────────────"
echo ""

# ── 1. Permissions ────────────────────────────────────────────────────────────
chmod +x "$SCRIPT_DIR/run.sh" "$SCRIPT_DIR/launch.sh"
echo "  ✓ Scripts marked executable"

# ── 2. Check swiftc ───────────────────────────────────────────────────────────
if ! command -v swiftc &>/dev/null; then
  echo ""
  echo "  ✗ Xcode Command Line Tools not found."
  echo "    Run this and then re-run install.sh:"
  echo ""
  echo "      xcode-select --install"
  echo ""
  exit 1
fi
echo "  ✓ Swift compiler found"

# ── 3. Compile native window ──────────────────────────────────────────────────
mkdir -p "$SCRIPT_DIR/.build"
echo "  ◌ Compiling widget window (first time takes ~10s)..."
swiftc "$SCRIPT_DIR/widget-window.swift" -o "$SCRIPT_DIR/.build/claude-widget-window" 2>&1
echo "  ✓ Native window compiled"

# ── 4. LaunchAgents — auto-start on login + crash recovery ───────────────────
# Two agents managed directly by launchd:
#   server  → always kept alive (it's a daemon)
#   window  → restarted only on crash; a clean quit ("close" button) stays closed
mkdir -p "$AGENTS_DIR"

# Tear down any previous install (old single agent + these two)
for old in com.claudewidget com.claudewidget.server com.claudewidget.window; do
  launchctl unload "$AGENTS_DIR/$old.plist" 2>/dev/null || true
done
rm -f "$AGENTS_DIR/com.claudewidget.plist"

cat > "$SERVER_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudewidget.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$SCRIPT_DIR/server.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/claude-widget.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-widget.log</string>
</dict>
</plist>
PLIST

cat > "$WINDOW_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claudewidget.window</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/claude-widget.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-widget.log</string>
</dict>
</plist>
PLIST

# Stop anything we launched manually so launchd owns the processes
lsof -ti:2727 | xargs kill -9 2>/dev/null || true
pkill -f claude-widget-window 2>/dev/null || true
sleep 0.3

launchctl load "$SERVER_PLIST"
launchctl load "$WINDOW_PLIST"
echo "  ✓ Auto-start on login + crash recovery enabled"

echo ""
echo "  ─────────────────────────────────────"
echo "  ◆ Claude Monitor is running!"
echo ""
echo "  Hotkey  ⌥⌘C   — show / hide from anywhere"
echo "  Connect       — install the browser extension once for live data:"
echo "                  chrome://extensions → Developer mode → Load unpacked"
echo "                  → select: $SCRIPT_DIR/extension"
echo ""
