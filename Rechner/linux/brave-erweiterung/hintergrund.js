// HeimAudio Tabs: answers requests from the bridge (brave-bruecke.py).
// Brave starts the bridge itself as soon as this extension connects.
// As long as the connection is open, the extension stays awake.

const BRIDGE = "com.heimaudio.brave";
let port = null;

function connect() {
  if (port) return;
  port = chrome.runtime.connectNative(BRIDGE);
  port.onMessage.addListener(handleRequest);
  port.onDisconnect.addListener(() => {
    // Most common reason: tabs-einrichten.sh has not been run yet.
    console.warn("HeimAudio: bridge disconnected:", chrome.runtime.lastError?.message);
    port = null;
    setTimeout(connect, 5000);
  });
}

async function listTabs() {
  const windows = await chrome.windows.getAll({ populate: true, windowTypes: ["normal"] });
  // The most recently used window first, like on the Mac.
  windows.sort((a, b) => Number(b.focused) - Number(a.focused));
  const tabs = [];
  windows.forEach((browserWindow, index) => {
    for (const tab of browserWindow.tabs ?? []) {
      tabs.push({
        id: tab.id,
        title: tab.title ?? "",
        url: tab.url || tab.pendingUrl || "",
        window: index + 1,
        active: tab.active,
      });
    }
  });
  return tabs;
}

// Error messages are shown to the user in the app and are therefore German.
async function handleRequest(request) {
  let answer;
  try {
    if (request.type === "list") {
      answer = { tabs: await listTabs() };
    } else if (request.type === "close" && Number.isInteger(request.tab)) {
      try {
        await chrome.tabs.remove(request.tab);
      } catch {
        answer = { error: "Diesen Tab gibt es nicht mehr", status: 404 };
      }
      answer ??= { ok: true };
    } else {
      answer = { error: "Unbekannter Auftrag", status: 400 };
    }
  } catch (error) {
    answer = { error: String(error?.message ?? error) };
  }
  port?.postMessage({ requestId: request.requestId, ...answer });
}

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
// Wakes the extension every minute. If the connection is missing (e.g. because the bridge
// was set up later), this re-establishes it.
chrome.alarms.create("connect", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(connect);
connect();
