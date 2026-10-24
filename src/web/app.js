"use strict";

const REFRESH_INTERVAL = 5000;
const FAST_REFRESH_INTERVAL = 1000;
const FAST_REFRESH_PERIOD = 60 * 1000;
const REQUEST_SHOWN_FOR = 10 * 60 * 1000;
const PENDING_TIMEOUT = 20 * 1000;
const NOTICE_SHOWN_FOR = 15 * 1000;

// Detect base path: if loaded from /w/<secret>/, API calls use the same prefix
const BASE_PATH = (() => {
  const m = window.location.pathname.match(/^(\/w\/[^/]+)\//);
  return m ? m[1] : "";
})();

// DOM references
const dom = {
  statusBadge: document.getElementById("status-badge"),
  buddyName: document.getElementById("buddy-name"),
  uptime: document.getElementById("uptime"),
  build: document.getElementById("build"),
  foldersList: document.getElementById("folders-list"),
  foldersEmpty: document.getElementById("folders-empty"),
  buddiesList: document.getElementById("buddies-list"),
  buddiesEmpty: document.getElementById("buddies-empty"),
  logsContent: document.getElementById("logs-content"),
  logsContainer: document.getElementById("logs-container"),
  activitySummary: document.getElementById("activity-summary"),
  activityHistory: document.getElementById("activity-history"),
  activityHistoryTitle: document.getElementById("activity-history-title"),
  activityList: document.getElementById("activity-list"),
  syncRequests: document.getElementById("sync-requests"),
};

// API helpers
const api = {
  async get(endpoint) {
    const res = await fetch(BASE_PATH + endpoint);
    return res.json();
  },

  async post(endpoint, body = {}) {
    const res = await fetch(BASE_PATH + endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    return res.json();
  },

  async postResult(endpoint, body = {}) {
    const res = await fetch(BASE_PATH + endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    return { ok: res.ok, data: await res.json() };
  },

  async del(endpoint) {
    const res = await fetch(BASE_PATH + endpoint, { method: "DELETE" });
    return res.json();
  },
};

// Formatting. Dates arrive as UTC ISO 8601 and are shown in the browser's
// time zone, in the locale from the [gui] locale setting, else the browser's.
const makeFormatters = (locale) => {
  const tag = locale || undefined;
  return {
    locale: new Intl.DateTimeFormat(tag).resolvedOptions().locale,
    dateTime: new Intl.DateTimeFormat(tag, { dateStyle: "short", timeStyle: "medium" }),
    decimal: new Intl.NumberFormat(tag, { maximumFractionDigits: 1 }),
    integer: new Intl.NumberFormat(tag, { maximumFractionDigits: 0 }),
    relative: new Intl.RelativeTimeFormat(tag, { numeric: "auto" }),
  };
};

const isKnownLocale = (locale) => {
  if (!locale) return true;
  try {
    return Intl.DateTimeFormat.supportedLocalesOf([locale]).length > 0;
  } catch (e) {
    return false;
  }
};

let fmt = makeFormatters("");

const setLocale = (locale) => {
  fmt = makeFormatters(isKnownLocale(locale) ? locale : "");
};

const BYTE_UNITS = ["B", "KB", "MB", "GB", "TB"];

const formatBytes = (bytes, f = fmt) => {
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < BYTE_UNITS.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${(unit === 0 ? f.integer : f.decimal).format(value)} ${BYTE_UNITS[unit]}`;
};

const formatCount = (n) => fmt.integer.format(n || 0);

const formatTime = (iso, f = fmt) => (iso ? f.dateTime.format(new Date(iso)) : "");

const RELATIVE_STEPS = [
  ["second", 60],
  ["minute", 60],
  ["hour", 24],
  ["day", 7],
  ["week", Infinity],
];

const formatRelative = (iso, f = fmt) => {
  let value = (new Date(iso).getTime() - Date.now()) / 1000;
  for (const [unit, size] of RELATIVE_STEPS) {
    if (Math.abs(value) < size) return f.relative.format(Math.round(value), unit);
    value /= size;
  }
  return "";
};

const formatTimeAndAge = (iso) => (iso ? `${formatTime(iso)} (${formatRelative(iso)})` : "");

const formatUptime = (seconds) => {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return `${h}h ${m}m`;
};

// Render functions
let latestFolders = [];
let latestBuddies = [];

const buddyLabel = (id) => {
  const buddy = latestBuddies.find((b) => b.id === id);
  return buddy && buddy.name ? buddy.name : id.substring(0, 8) + "...";
};

const sharingText = (folder) => {
  const buddies = folder.buddies || [];
  const target = buddies.length === 0 ? "all buddies" : buddies.map(buddyLabel).join(", ");
  const traits = [folder.encrypted ? "encrypted" : "not encrypted"];
  if (folder.appendOnly) traits.push("append-only");
  return `Backed up to ${target} · ${traits.join(", ")}`;
};

const FOLDER_STATUS_TEXT = {
  idle: "Not synced yet",
  syncing: "Syncing",
  synced: "Synced",
  skipped: "Skipped",
  refused: "Refused",
  failed: "Sync did not finish",
};

const folderStatusLine = (status) => {
  const syncStatus = status.status || "idle";
  const parts = [FOLDER_STATUS_TEXT[syncStatus] || syncStatus];
  if (status.lastSync) {
    parts.push(`last synced ${formatTimeAndAge(status.lastSync)}`);
  }
  const totalBytes = status.totalBytes || 0;
  if (totalBytes > 0) {
    parts.push(`${formatBytes(status.syncedBytes || 0)} / ${formatBytes(totalBytes)} (${formatCount(status.fileCount)} files)`);
  }
  return parts.join(" · ");
};

const renderFolders = (folders) => {
  latestFolders = folders;
  dom.foldersList.innerHTML = "";
  dom.foldersEmpty.hidden = folders.length > 0;

  for (const folder of folders) {
    const status = folder.status || {};
    const totalBytes = status.totalBytes || 0;
    const syncedBytes = status.syncedBytes || 0;
    const syncStatus = status.status || "idle";
    const problem = ["skipped", "refused", "failed"].includes(syncStatus);
    const fraction = totalBytes > 0 ? (syncedBytes / totalBytes) * 100 : 0;

    const item = document.createElement("div");
    item.className = "list-item";
    item.innerHTML = `
      <div class="list-item-info">
        <div class="list-item-name">${escHtml(folder.name)}</div>
        <div class="list-item-detail">${escHtml(folder.path)}</div>
        <div class="list-item-detail">${escHtml(sharingText(folder))}</div>
        <div class="list-item-detail folder-status folder-status-${escAttr(syncStatus)}">${escHtml(folderStatusLine(status))}</div>
        ${problem && status.detail ? `<div class="list-item-detail folder-problem">${escHtml(status.detail)}</div>` : ""}
      </div>
      <div class="list-item-right">
        ${syncStatus === "syncing" && totalBytes > 0 ? `
          <div class="progress-bar">
            <div class="progress-bar-fill" style="width:${fraction}%"></div>
          </div>
        ` : ""}
        <button class="btn btn-small btn-sync" data-folder="${escAttr(folder.name)}">Sync</button>
        <button class="btn btn-small btn-edit-folder" data-folder-id="${escAttr(folder.id || "")}">Edit</button>
        <button class="btn btn-small btn-danger btn-remove-folder" data-folder="${escAttr(folder.name)}">Remove</button>
      </div>
    `;
    dom.foldersList.appendChild(item);
  }
};

let daemonRunning = false;

const formatMinutes = (minutes) => {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h && m) return `${h}h ${m}m`;
  return h ? `${h}h` : `${m}m`;
};

const scheduleText = (buddy) => {
  const when = buddy.syncWindow ? `between ${buddy.syncWindow}` : "any time";
  if (!daemonRunning || !buddy.intervalMinutes) {
    return `Syncs ${when}, ${buddy.syncIntervalText || ""}`;
  }
  let next = "";
  if (buddy.nextSync) {
    const at = new Date(Math.max(Date.parse(buddy.nextSync), Date.now())).toISOString();
    next = ` · next ${buddy.buddyDials ? "check" : "sync"} ${formatTimeAndAge(at)}`;
  }
  if (buddy.buddyDials) {
    return `${buddy.name || "This buddy"} dials this machine; we meet it at the relay ${when}, every ${formatMinutes(buddy.intervalMinutes)}${next}`;
  }
  return `Syncs ${when}, every ${formatMinutes(buddy.intervalMinutes)}${next}`;
};

const renderBuddies = (buddies, storage = []) => {
  latestBuddies = buddies;
  const storageById = {};
  for (const entry of storage) storageById[entry.buddyId] = entry;
  dom.buddiesList.innerHTML = "";
  dom.buddiesEmpty.hidden = buddies.length > 0;

  for (const buddy of buddies) {
    const state = buddy.state || "disconnected";
    const shortId = buddy.id ? buddy.id.substring(0, 16) + "..." : "";
    const latency = buddy.latencyMs >= 0 ? `${buddy.latencyMs}ms` : "";
    const stored = storageById[buddy.id];
    const storedText = stored
      ? `Storing ${formatCount(stored.files)} files (${formatBytes(stored.bytes)}) in ${stored.path}`
      : "";

    const item = document.createElement("div");
    item.className = "list-item";
    item.innerHTML = `
      <div class="list-item-info">
        <div class="list-item-name">${escHtml(buddy.name || "Unknown")}</div>
        <div class="list-item-detail">${escHtml(shortId)}</div>
        <div class="list-item-detail">${escHtml(scheduleText(buddy))}</div>
        ${storedText ? `<div class="list-item-detail">${escHtml(storedText)}</div>` : ""}
      </div>
      <div class="list-item-right">
        ${latency ? `<span class="dim">${latency}</span>` : ""}
        <span class="state-${state === "connected" ? "connected" : "disconnected"}">${escHtml(state)}</span>
        <button class="btn btn-small btn-edit-buddy" data-buddy="${escAttr(buddy.id)}">Edit</button>
        <button class="btn btn-small btn-danger btn-remove-buddy" data-buddy="${escAttr(buddy.id)}">Remove</button>
      </div>
    `;
    dom.buddiesList.appendChild(item);
  }
};


const formatDuration = (startIso, endIso) => {
  const seconds = Math.max(0, Math.round((new Date(endIso) - new Date(startIso)) / 1000));
  if (seconds < 60) return `${seconds} s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ${seconds % 60} s`;
  return `${Math.floor(seconds / 3600)} h ${Math.floor((seconds % 3600) / 60)} min`;
};

const fileCountText = (n) => `${formatCount(n)} file${n === 1 ? "" : "s"}`;

const sessionBuddy = (s) => s.buddyName || (s.buddyId || "").substring(0, 8) || "a buddy";

const dialText = (s) => {
  const name = sessionBuddy(s);
  if (s.via === "relay") return `connected with ${name} through the relay`;
  return s.dialedBy === "buddy" ? `${name} dialed us` : `we dialed ${name}`;
};

const transferText = (s, soFar = false) => {
  const name = sessionBuddy(s);
  const parts = [];
  if (s.filesSent || s.bytesSent) {
    parts.push(`sent ${fileCountText(s.filesSent)} (${formatBytes(s.bytesSent)}) to ${name}`);
  }
  if (s.filesReceived || s.bytesReceived) {
    parts.push(`received ${fileCountText(s.filesReceived)} (${formatBytes(s.bytesReceived)}) from ${name}`);
  }
  if (parts.length === 0) return soFar ? "no file data yet" : "no file data needed transferring";
  const text = parts.join(", ");
  return (soFar ? "so far " : "") + text.charAt(0).toUpperCase() + text.slice(1);
};

const outcomeText = (s) => {
  const name = sessionBuddy(s);
  switch (s.outcome) {
    case "ok": return "Finished";
    case "failed": return "Did not finish, see the log";
    case "interrupted": return "Cut off when the daemon stopped";
    case "running": return "Running";
    case "turned away":
      return s.dialedBy === "buddy"
        ? `turned away, a sync with ${name} was already running`
        : `dropped, a sync with ${name} was already running`;
    default: return s.outcome;
  }
};

const activityLine = (cls, html) => `<div class="activity-line ${cls}">${html}</div>`;

const outcomeSpan = (s) =>
  `<span class="activity-outcome-${escAttr(s.outcome.replace(" ", "-"))}">${escHtml(outcomeText(s))}</span>`;

const durationText = (s) =>
  s.outcome === "running" || s.outcome === "interrupted" || s.outcome === "turned away"
    ? ""
    : ` · took ${formatDuration(s.startedAt, s.endedAt)}`;

const renderActivity = (sessions) => {
  const running = sessions.filter((s) => s.outcome === "running");
  const finished = sessions.filter((s) => s.outcome !== "running" && s.outcome !== "turned away");
  const last = finished[0];
  const lines = [];

  for (const s of running) {
    lines.push(activityLine("activity-running",
      `<strong>Syncing with ${escHtml(sessionBuddy(s))}</strong> since ${escHtml(formatTime(s.startedAt))} · ${escHtml(dialText(s))}`));
    lines.push(activityLine("activity-detail", escHtml(transferText(s, true))));
  }

  if (last) {
    lines.push(activityLine("",
      `<strong>Last sync</strong> with ${escHtml(sessionBuddy(last))}: ${escHtml(formatTimeAndAge(last.startedAt))}` +
      `${escHtml(durationText(last))} · ${escHtml(dialText(last))} · ${outcomeSpan(last)}`));
    lines.push(activityLine("activity-detail", escHtml(transferText(last))));
  } else if (running.length === 0) {
    lines.push(activityLine("activity-detail", "No sync sessions yet."));
  }

  const turnedAway = sessions.find((s) => s.outcome === "turned away");
  if (turnedAway && (!last || new Date(turnedAway.startedAt) >= new Date(last.startedAt))) {
    lines.push(activityLine("activity-outcome-turned-away",
      `${escHtml(formatTime(turnedAway.startedAt))}: ${escHtml(dialText(turnedAway))} · ${escHtml(outcomeText(turnedAway))}`));
  }

  const totals = {};
  for (const s of sessions) {
    const name = sessionBuddy(s);
    const t = (totals[name] ||= { bytesSent: 0, bytesReceived: 0, filesSent: 0, filesReceived: 0, buddyName: name });
    t.bytesSent += s.bytesSent || 0;
    t.bytesReceived += s.bytesReceived || 0;
    t.filesSent += s.filesSent || 0;
    t.filesReceived += s.filesReceived || 0;
  }
  const totalTexts = Object.values(totals)
    .filter((t) => t.bytesSent || t.bytesReceived || t.filesSent || t.filesReceived)
    .map((t) => {
      const text = transferText(t);
      return text.charAt(0).toLowerCase() + text.slice(1);
    });
  if (sessions.length > 1 && totalTexts.length > 0) {
    lines.push(activityLine("activity-detail",
      `Over the last ${sessions.length} sessions: ${escHtml(totalTexts.join("; "))}`));
  }

  dom.activitySummary.innerHTML = lines.join("");

  dom.activityHistory.hidden = sessions.length === 0;
  dom.activityHistoryTitle.textContent = `Recent sessions (${sessions.length})`;
  dom.activityList.innerHTML = sessions.map((s) => {
    const transfer = s.outcome === "turned away" ? "" :
      `<div class="list-item-detail">${escHtml(transferText(s, s.outcome === "running"))}</div>`;
    return `
      <div class="list-item">
        <div class="list-item-info">
          <div class="list-item-name">${escHtml(formatTime(s.startedAt))} · ${escHtml(sessionBuddy(s))}</div>
          <div class="list-item-detail">${escHtml(dialText(s))}${escHtml(durationText(s))} · ${outcomeSpan(s)}</div>
          ${transfer}
        </div>
      </div>`;
  }).join("");
};

// Sync requests from the GUI: what the daemon did with them
let pendingRequest = null;
let requestNotice = null;
let fastRefreshUntil = 0;
let latestRequests = [];

const REQUEST_TEXT = {
  "looking up": "looking up the buddy's address...",
  "dialing": "connecting...",
  "connected": "connected, syncing",
  "already syncing": "a sync with this buddy is already running",
  "not found": "could not find the buddy",
  "unreachable": "could not connect",
};

const REQUEST_CLASS = {
  "looking up": "request-pending",
  "dialing": "request-pending",
  "connected": "activity-outcome-ok",
  "already syncing": "request-busy",
  "not found": "request-failed",
  "unreachable": "request-failed",
};

const showNotice = (text, cls) => {
  requestNotice = { text, cls, at: Date.now() };
  renderRequests(latestRequests);
};

const renderRequests = (requests) => {
  latestRequests = requests;
  const now = Date.now();
  const lines = [];

  if (requestNotice && now - requestNotice.at < NOTICE_SHOWN_FOR) {
    lines.push(activityLine(requestNotice.cls, escHtml(requestNotice.text)));
  }

  if (pendingRequest) {
    const picked = requests.some((r) =>
      pendingRequest.ids.includes(r.buddyId) &&
      (new Date(r.updatedAt).getTime() >= pendingRequest.at - 5000 || REQUEST_CLASS[r.state] === "request-pending"));
    if (picked) {
      pendingRequest = null;
    } else if (now - pendingRequest.at > PENDING_TIMEOUT) {
      lines.push(activityLine("request-failed",
        `Sync requested with ${escHtml(pendingRequest.names.join(", "))}, but the daemon has not picked it up. Is it running?`));
    } else {
      lines.push(activityLine("request-pending",
        `Sync requested with ${escHtml(pendingRequest.names.join(", "))}, waiting for the daemon...`));
    }
  }

  for (const r of requests) {
    const age = now - new Date(r.updatedAt).getTime();
    if (age > REQUEST_SHOWN_FOR || (r.state === "connected" && age > 60 * 1000)) continue;
    lines.push(activityLine(REQUEST_CLASS[r.state] || "",
      `Sync requested with <strong>${escHtml(r.buddyName || buddyLabel(r.buddyId))}</strong> at ${escHtml(formatTime(r.requestedAt))} · ${escHtml(REQUEST_TEXT[r.state] || r.state)}`));
    if (r.detail) lines.push(activityLine("activity-detail", escHtml(r.detail)));
  }

  dom.syncRequests.innerHTML = lines.join("");
  dom.syncRequests.hidden = lines.length === 0;
};

const requestSync = async (endpoint, button) => {
  const label = button.textContent;
  button.disabled = true;
  button.textContent = "Requesting...";
  try {
    const result = await api.postResult(endpoint);
    const data = result.data || {};
    const buddies = data.buddies || [];
    if (!result.ok) {
      showNotice(data.error || "Could not request a sync.", "request-failed");
    } else if (!data.daemonRunning) {
      showNotice("The daemon is not running, so nothing will sync until it is started.", "request-failed");
    } else if (data.folders === 0) {
      showNotice("There are no folders to sync. Add a folder first.", "request-busy");
    } else if (buddies.length === 0) {
      showNotice("No buddy to sync with. Pair with a buddy first.", "request-busy");
    } else {
      requestNotice = null;
      pendingRequest = {
        at: Date.now(),
        ids: buddies.map((b) => b.id),
        names: buddies.map((b) => b.name || b.id.substring(0, 8)),
      };
      fastRefreshUntil = Date.now() + FAST_REFRESH_PERIOD;
      renderRequests(latestRequests);
    }
    await refresh();
  } catch (e) {
    showNotice(`Could not reach BuddyDrive: ${e.message}`, "request-failed");
  } finally {
    setTimeout(() => {
      button.disabled = false;
      button.textContent = label;
    }, 1500);
  }
};

const renderStatus = (data) => {
  const running = data.running || false;
  const syncEnabled = data.syncEnabled !== false;
  const syncWindow = data.syncWindow || "always";

  let badgeText, badgeClass;
  if (!running) {
    badgeText = "Stopped";
    badgeClass = "badge-stopped";
  } else if (!syncEnabled) {
    badgeText = "Sync paused";
    badgeClass = "badge-paused";
  } else {
    badgeText = "Syncing";
    badgeClass = "badge-running";
  }
  dom.statusBadge.textContent = badgeText;
  dom.statusBadge.className = `badge ${badgeClass}`;

  const name = data.buddy?.name || "Unknown";
  dom.buddyName.textContent = name;

  const uptime = data.uptime || 0;
  dom.uptime.textContent = running ? formatUptime(uptime) : "";
  daemonRunning = running;

  const build = data.build;
  dom.build.textContent = build ? `v${build.version} · ${build.commit}` : "";
  dom.build.title = build ? `Built ${formatTime(build.builtAt)} · wire protocol ${build.protocolVersion}` : "";
};

const renderLogs = (logs) => {
  const lines = logs.map((l) => l.raw || "").join("\n");
  dom.logsContent.textContent = lines;
  dom.logsContainer.scrollTop = dom.logsContainer.scrollHeight;
};

// HTML escaping
const escHtml = (str) => {
  const d = document.createElement("div");
  d.textContent = str;
  return d.innerHTML;
};

const escAttr = (str) => escHtml(str).replace(/"/g, "&quot;");

// Refresh all data
const refresh = async () => {
  try {
    const [status, folders, buddies, storage, sessions] = await Promise.all([
      api.get("/status"),
      api.get("/folders"),
      api.get("/buddies"),
      api.get("/storage").catch(() => ({ storage: [] })),
      api.get("/sessions").catch(() => ({ sessions: [] })),
    ]);
    renderStatus(status);
    renderActivity(sessions.sessions || []);
    renderFolders(folders.folders || []);
    renderBuddies(buddies.buddies || [], storage.storage || []);
    renderRequests(sessions.requests || []);
  } catch (e) {
    console.error("Refresh failed:", e);
  }
};

const refreshLogs = async () => {
  try {
    const data = await api.get("/logs");
    renderLogs(data.logs || []);
  } catch (e) {
    console.error("Logs refresh failed:", e);
  }
};

// Dialog helpers
const openDialog = (id) => {
  const dialog = document.getElementById(id);
  dialog.showModal();
};

const closeDialog = (id) => {
  document.getElementById(id).close();
};

// Event handlers
const initEvents = () => {
  // Header buttons
  document.getElementById("btn-refresh").addEventListener("click", () => {
    refresh();
    refreshLogs();
  });

  document.getElementById("btn-settings").addEventListener("click", async () => {
    try {
      const data = await api.get("/config");
      document.getElementById("settings-name").value = data.buddy?.name || "";
      const net = data.network || {};
      document.getElementById("settings-port").value = net.listen_port || "";
      document.getElementById("settings-announce").value = net.announce_addr || "";
      document.getElementById("settings-relay-url").value = net.api_base_url || "";
      document.getElementById("settings-relay-region").value = net.relay_region || "";
      document.getElementById("settings-locale").value = data.gui?.locale || "";
    } catch (e) {
      // leave empty
    }
    updateLocalePreview();
    openDialog("dialog-settings");
  });

  const updateLocalePreview = () => {
    const value = document.getElementById("settings-locale").value.trim();
    const preview = document.getElementById("settings-locale-preview");
    if (!isKnownLocale(value)) {
      preview.textContent = `This browser does not know the locale "${value}".`;
      return;
    }
    const f = makeFormatters(value);
    const example = new Date(Date.now() - 5 * 60 * 1000).toISOString();
    preview.textContent = `${f.locale}: ${formatTime(example, f)} (${formatRelative(example, f)}) · ${formatBytes(1288490189, f)}`;
  };

  document.getElementById("settings-locale").addEventListener("input", updateLocalePreview);

  // Sync All
  document.getElementById("btn-sync-all").addEventListener("click", (e) => {
    requestSync("/sync", e.currentTarget);
  });

  // Per-folder sync and remove (delegated)
  dom.foldersList.addEventListener("click", async (e) => {
    const syncBtn = e.target.closest(".btn-sync");
    if (syncBtn) {
      await requestSync(`/sync/${encodeURIComponent(syncBtn.dataset.folder)}`, syncBtn);
      return;
    }

    const editBtn = e.target.closest(".btn-edit-folder");
    if (editBtn) {
      const folder = latestFolders.find((f) => f.id === editBtn.dataset.folderId);
      if (folder) openFolderDialog(folder);
      return;
    }

    const removeBtn = e.target.closest(".btn-remove-folder");
    if (removeBtn) {
      const name = removeBtn.dataset.folder;
      if (confirm(`Remove folder "${name}"?`)) {
        await api.del(`/folders/${encodeURIComponent(name)}`);
        await refresh();
      }
    }
  });

  // Per-buddy edit and remove (delegated)
  dom.buddiesList.addEventListener("click", async (e) => {
    const editBtn = e.target.closest(".btn-edit-buddy");
    if (editBtn) {
      const buddy = latestBuddies.find((b) => b.id === editBtn.dataset.buddy);
      if (buddy) openEditBuddyDialog(buddy);
      return;
    }

    const removeBtn = e.target.closest(".btn-remove-buddy");
    if (removeBtn) {
      const id = removeBtn.dataset.buddy;
      if (confirm("Remove this buddy?")) {
        await api.del(`/buddies/${encodeURIComponent(id)}`);
        await refresh();
      }
    }
  });

  // Add / Edit Folder dialog
  const openFolderDialog = (folder = null) => {
    const editing = folder !== null;
    document.getElementById("folder-dialog-title").textContent = editing ? "Edit Folder" : "Add Folder";
    document.getElementById("btn-submit-folder").textContent = editing ? "Save" : "Add";
    document.getElementById("folder-id").value = editing ? folder.id : "";
    document.getElementById("folder-name").value = editing ? folder.name : "";
    document.getElementById("folder-path").value = editing ? folder.path : "";
    const encrypt = document.getElementById("folder-encrypt");
    encrypt.checked = editing ? folder.encrypted : true;
    // Switching encryption on an existing folder would orphan its backup.
    encrypt.disabled = editing;
    document.getElementById("folder-append-only").checked = editing ? !!folder.appendOnly : false;
    document.getElementById("folder-error").hidden = true;

    const selected = new Set(editing ? folder.buddies || [] : []);
    const container = document.getElementById("folder-buddies");
    container.innerHTML = "";
    for (const buddy of latestBuddies) {
      const label = document.createElement("label");
      label.className = "checkbox-label";
      label.innerHTML = `<input type="checkbox" value="${escAttr(buddy.id)}" ${selected.has(buddy.id) ? "checked" : ""}> ${escHtml(buddy.name || buddy.id)}`;
      container.appendChild(label);
    }
    document.getElementById("folder-buddies-hint").textContent = latestBuddies.length > 0
      ? "None selected means all your buddies."
      : "No buddies paired yet. The folder will be backed up to every buddy you pair with.";
    openDialog("dialog-add-folder");
  };

  document.getElementById("btn-add-folder").addEventListener("click", () => openFolderDialog());

  document.getElementById("btn-cancel-folder").addEventListener("click", () => {
    closeDialog("dialog-add-folder");
  });

  document.getElementById("dialog-add-folder").addEventListener("close", async () => {
    const dialog = document.getElementById("dialog-add-folder");
    if (dialog.returnValue !== "default") return;
  });

  document.getElementById("btn-submit-folder").addEventListener("click", async (e) => {
    e.preventDefault();
    const id = document.getElementById("folder-id").value;
    const name = document.getElementById("folder-name").value.trim();
    const path = document.getElementById("folder-path").value.trim();
    const encrypted = document.getElementById("folder-encrypt").checked;
    const appendOnly = document.getElementById("folder-append-only").checked;
    const buddies = [...document.querySelectorAll("#folder-buddies input:checked")].map((input) => input.value);
    if (!name || !path) return;

    const result = id
      ? await api.postResult("/folders/update", { id, name, path, appendOnly, buddies })
      : await api.postResult("/folders", { name, path, encrypted, appendOnly, buddies });
    if (!result.ok) {
      const error = document.getElementById("folder-error");
      error.textContent = result.data.error || "Could not save the folder.";
      error.hidden = false;
      return;
    }
    closeDialog("dialog-add-folder");
    await refresh();
  });

  // Pair Buddy dialog
  document.getElementById("btn-pair-buddy").addEventListener("click", () => {
    document.getElementById("buddy-id").value = "";
    document.getElementById("buddy-pair-name").value = "";
    document.getElementById("buddy-code").value = "";
    document.getElementById("pair-error").hidden = true;
    document.getElementById("pair-hint").textContent =
      "Enter the code your buddy sent you, or generate one and send it to them. Both of you must use the same code.";
    openDialog("dialog-pair-buddy");
  });

  document.getElementById("btn-generate-code").addEventListener("click", async () => {
    const info = await api.post("/buddies/pairing-code");
    document.getElementById("buddy-code").value = info.pairingCode || "";
    document.getElementById("pair-hint").textContent =
      `Send your buddy your Buddy ID ${info.buddyId} and this code, then press Pair. ` +
      "They enter both in their own Pair dialog.";
  });

  document.getElementById("btn-cancel-pair").addEventListener("click", () => {
    closeDialog("dialog-pair-buddy");
  });

  document.getElementById("btn-submit-pair").addEventListener("click", async (e) => {
    e.preventDefault();
    const buddyId = document.getElementById("buddy-id").value.trim();
    const buddyName = document.getElementById("buddy-pair-name").value.trim();
    const code = document.getElementById("buddy-code").value.trim();
    const error = document.getElementById("pair-error");
    const missing = [];
    if (!buddyId) missing.push("the buddy's ID");
    if (!buddyName) missing.push("a name for the buddy");
    if (!code) missing.push("a pairing code");
    if (missing.length > 0) {
      error.textContent = `Enter ${missing.join(", ")}.`;
      error.hidden = false;
      return;
    }

    const result = await api.postResult("/buddies/pair", { buddyId, buddyName, code });
    if (!result.ok) {
      error.textContent = result.data.error || "Could not pair with the buddy.";
      error.hidden = false;
      return;
    }
    closeDialog("dialog-pair-buddy");
    await refresh();
  });

  // Edit Buddy dialog
  const openEditBuddyDialog = (buddy) => {
    document.getElementById("edit-buddy-id").value = buddy.id;
    document.getElementById("edit-buddy-uuid").textContent = `Buddy ID ${buddy.id}`;
    document.getElementById("edit-buddy-name").value = buddy.name || "";
    document.getElementById("edit-buddy-window").value = buddy.syncWindow || "";
    document.getElementById("edit-buddy-interval").value = buddy.syncInterval || "";
    document.getElementById("edit-buddy-error").hidden = true;
    openDialog("dialog-edit-buddy");
  };

  document.getElementById("btn-cancel-edit-buddy").addEventListener("click", () => {
    closeDialog("dialog-edit-buddy");
  });

  document.getElementById("btn-submit-edit-buddy").addEventListener("click", async (e) => {
    e.preventDefault();
    const id = document.getElementById("edit-buddy-id").value;
    const name = document.getElementById("edit-buddy-name").value.trim();
    const error = document.getElementById("edit-buddy-error");
    if (!name) {
      error.textContent = "Enter a name for the buddy.";
      error.hidden = false;
      return;
    }
    const result = await api.postResult("/buddies/update", {
      id,
      name,
      sync_window: document.getElementById("edit-buddy-window").value.trim(),
      sync_interval: document.getElementById("edit-buddy-interval").value.trim(),
    });
    if (!result.ok) {
      error.textContent = result.data.error || "Could not save the buddy.";
      error.hidden = false;
      return;
    }
    closeDialog("dialog-edit-buddy");
    await refresh();
  });

  // Settings dialog
  document.getElementById("btn-cancel-settings").addEventListener("click", () => {
    closeDialog("dialog-settings");
  });

  document.getElementById("btn-submit-settings").addEventListener("click", async (e) => {
    e.preventDefault();
    const locale = document.getElementById("settings-locale").value.trim();
    if (!isKnownLocale(locale)) {
      updateLocalePreview();
      return;
    }
    const body = { buddy: {}, network: {}, gui: { locale } };

    const name = document.getElementById("settings-name").value.trim();
    if (name) body.buddy.name = name;

    const port = document.getElementById("settings-port").value.trim();
    if (port) body.network.listen_port = parseInt(port, 10);

    const announce = document.getElementById("settings-announce").value.trim();
    if (announce) body.network.announce_addr = announce;

    const relayUrl = document.getElementById("settings-relay-url").value.trim();
    if (relayUrl) body.network.api_base_url = relayUrl;

    const relayRegion = document.getElementById("settings-relay-region").value.trim();
    if (relayRegion) body.network.relay_region = relayRegion;

    const result = await api.post("/config", body);
    setLocale(locale);
    closeDialog("dialog-settings");
    await refresh();
    if (result.restartRequired) {
      alert("Settings saved. A daemon restart is required for some changes to take effect.");
    }
  });

  // Logs refresh
  document.getElementById("btn-refresh-logs").addEventListener("click", refreshLogs);
};

// Init
const loadLocale = async () => {
  try {
    const data = await api.get("/config");
    setLocale(data.gui?.locale || "");
  } catch (e) {
    setLocale("");
  }
};

initEvents();
loadLocale().then(refresh);
refreshLogs();
setInterval(refresh, REFRESH_INTERVAL);
setInterval(() => {
  if (Date.now() < fastRefreshUntil) refresh();
}, FAST_REFRESH_INTERVAL);
