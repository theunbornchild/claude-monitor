#!/usr/bin/env python3
"""
Claude Monitor — HTTP server

Data flow:
  1. The browser extension (or the fallback console snippet) fetches live usage
     from claude.ai using the user's session.
  2. It POSTs the JSON to POST /api/data here, every 60s.
  3. This server caches it (in memory + /tmp) and serves it from GET /api/usage.

If no live data has arrived yet, GET /api/usage returns {"setup": true}.
"""
import json
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SCRIPT_DIR  = Path(__file__).parent.resolve()
WIDGET_HTML = SCRIPT_DIR / "widget.html"
CACHE_FILE  = Path("/tmp/claude-widget-cache.json")   # persists across restarts

# In-memory cache populated by POST /api/data
_live_payload: dict | None = None
_live_ts: float = 0.0
LIVE_TTL: float = 300.0   # seconds — treat as stale after 5 min

def _load_cache() -> None:
    """Warm the in-memory cache from disk on startup."""
    global _live_payload, _live_ts
    try:
        if CACHE_FILE.exists():
            _live_payload = json.loads(CACHE_FILE.read_text())
            _live_ts = 0.0   # force stale so widget shows badge, not fresh
    except Exception:
        pass

_load_cache()

DEMO_DATA = {
    "demo": True,
    "plan": "MAX 5x",
    "session": {"pct": 0, "resets": "4h 49min"},
    "weekly": [
        {"name": "ALL MODELS",    "pct": 28, "resets": "11h 29min"},
        {"name": "SONNET ONLY",   "pct": 32, "resets": "11h 29min"},
        {"name": "CLAUDE DESIGN", "pct": 0,  "resets": None},
    ],
}

BROWSER_APPS = {
    "Chrome": "/Applications/Google Chrome.app",
    "Arc":    "/Applications/Arc.app",
    "Brave":  "/Applications/Brave Browser.app",
    "Edge":   "/Applications/Microsoft Edge.app",
}

# ── Snippet served to the setup screen ───────────────────────────────────────
# Fallback for users who don't install the extension: paste once in the
# claude.ai DevTools console. It fetches real usage, POSTs it to our local
# server, then re-runs every 60s (until the tab is closed).
CONNECT_SNIPPET = r"""(async function claudeWidget() {
  try {
    var b = await fetch('/api/bootstrap', {credentials:'include',
      headers:{Accept:'application/json'}}).then(function(r){return r.json();});
    var orgs = b.account.memberships.map(function(m){return m.organization;});
    var org = orgs.find(function(o){return (o.rate_limit_tier||'').indexOf('max')!==-1;})
              || orgs[orgs.length-1];
    var u = await fetch('/api/organizations/'+org.uuid+'/usage', {credentials:'include',
      headers:{Accept:'application/json'}}).then(function(r){return r.json();});
    await fetch('http://localhost:2727/api/data', {method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify({plan:org.rate_limit_tier, usage:u})});
  } catch(e) { console.warn('[claude-widget]', e.message); }
  setTimeout(claudeWidget, 60000);
})();"""

# ── Helpers ────────────────────────────────────────────────────────────────────

def iso_to_relative(ts: str | None) -> str | None:
    if not ts:
        return None
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        secs = int((dt - datetime.now(timezone.utc)).total_seconds())
        if secs <= 0:
            return None
        h, m = divmod(secs, 3600)
        return f"{h}h {m // 60}min"
    except Exception:
        return None

PLAN_MAP = {
    "default_claude_max_5x": "MAX 5x",
    "default_claude_max":    "MAX",
    "default_claude_pro":    "Pro",
    "claude_pro":            "Pro",
}

def tier_to_plan(tier: str) -> str:
    if not tier:
        return "UNKNOWN"
    return PLAN_MAP.get(tier, tier.replace("default_", "").replace("_", " ").upper())

def normalize(raw: dict) -> dict:
    """Convert {plan, usage} from the real API into our widget format."""
    usage = raw.get("usage") or {}
    five_hour = usage.get("five_hour") or {}

    weekly = []
    for key, label in [
        ("seven_day",          "ALL MODELS"),
        ("seven_day_sonnet",   "SONNET ONLY"),
        ("seven_day_omelette", "CLAUDE DESIGN"),
    ]:
        row = usage.get(key)
        if row is not None:
            weekly.append({
                "name":   label,
                "pct":    int(row.get("utilization", 0)) if isinstance(row, dict) else 0,
                "resets": iso_to_relative(row.get("resets_at") if isinstance(row, dict) else None),
            })

    return {
        "demo":    False,
        "plan":    tier_to_plan(raw.get("plan", "")),
        "session": {
            "pct":    int(five_hour.get("utilization", 0)),
            "resets": iso_to_relative(five_hour.get("resets_at")),
        },
        "weekly": weekly,
    }

def detect_browsers() -> dict:
    return {name: Path(path).exists() for name, path in BROWSER_APPS.items()}

def get_usage_data() -> dict:
    global _live_payload, _live_ts
    if _live_payload:
        age = time.monotonic() - _live_ts
        if age < LIVE_TTL:
            return _live_payload
        # Data exists but is stale — return it with a flag instead of
        # reverting to the setup screen
        return {**_live_payload, "stale": True}
    return {
        "setup": True,
        "snippet": CONNECT_SNIPPET,
        "browsers": detect_browsers(),
        "ext_path": str(SCRIPT_DIR / "extension"),
    }


# ── HTTP handler ───────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        pass

    def do_GET(self):
        if self.path == "/":
            self._serve_html()
        elif self.path == "/api/usage":
            self._serve_usage()
        elif self.path == "/api/snippet":
            self._serve_snippet()
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/api/data":
            self._receive_data()
        else:
            self.send_error(404)

    def do_OPTIONS(self):
        # Pre-flight for the POST from claude.ai
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    # ── routes ──────────────────────────────────────────────────────────────

    def _serve_html(self):
        try:
            content = WIDGET_HTML.read_bytes()
        except OSError:
            self.send_error(500, "widget.html not found")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def _serve_snippet(self):
        body = json.dumps({"snippet": CONNECT_SNIPPET}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_usage(self):
        data = get_usage_data()
        body = json.dumps(data).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _receive_data(self):
        """Accept pushed usage data from the connect-snippet running at claude.ai."""
        global _live_payload, _live_ts
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            raw = json.loads(body.decode("utf-8"))
            _live_payload = normalize(raw)
            _live_ts = time.monotonic()
            # Persist to disk so next restart shows last known data
            try:
                CACHE_FILE.write_text(json.dumps(_live_payload))
            except Exception:
                pass
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
        except Exception:
            self.send_error(400)


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 2727), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
