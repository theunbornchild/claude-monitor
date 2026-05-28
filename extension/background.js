// ◆ Claude Monitor Connector — background service worker
//
// Polls claude.ai usage (using your logged-in session cookies) every 60s and
// pushes it to the local Claude Monitor widget server. Runs with NO tab open —
// the chrome alarm wakes the worker on a schedule even after it's been suspended.

const WIDGET_URL = "http://localhost:2727/api/data";
// chrome.alarms works in minutes; 1 (= 60s) is the shortest interval Chrome
// reliably honors — anything smaller gets clamped.
const POLL_MINUTES = 1;

async function poll() {
  try {
    const b = await fetch("https://claude.ai/api/bootstrap", {
      credentials: "include",
      headers: { Accept: "application/json" },
    }).then((r) => r.json());

    const orgs = (b.account?.memberships || []).map((m) => m.organization);
    if (!orgs.length) throw new Error("no organizations (not logged in?)");

    const org =
      orgs.find((o) => (o.rate_limit_tier || "").includes("max")) ||
      orgs[orgs.length - 1];

    const usage = await fetch(
      "https://claude.ai/api/organizations/" + org.uuid + "/usage",
      { credentials: "include", headers: { Accept: "application/json" } }
    ).then((r) => r.json());

    await fetch(WIDGET_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ plan: org.rate_limit_tier, usage }),
    });
  } catch (e) {
    // Most common cause: not logged into claude.ai, or widget server not running.
    console.warn("[claude-monitor]", e.message);
  }
}

function ensureAlarm() {
  chrome.alarms.create("poll", { periodInMinutes: POLL_MINUTES });
}

chrome.runtime.onInstalled.addListener(() => {
  ensureAlarm();
  poll();
});

chrome.runtime.onStartup.addListener(() => {
  ensureAlarm();
  poll();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "poll") poll();
});
