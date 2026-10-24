"use strict";

const REFRESH_INTERVAL = 5000;

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
  foldersList: document.getElementById("folders-list"),
  foldersEmpty: document.getElementById("folders-empty"),
  buddiesList: document.getElementById("buddies-list"),
  buddiesEmpty: document.getElementById("buddies-empty"),
  logsContent: document.getElementById("logs-content"),
  logsContainer: document.getElementById("logs-container"),
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

// Formatting
const formatBytes = (bytes) => {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.floor(bytes / 1024)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${Math.floor(bytes / (1024 * 1024))} MB`;
  return `${Math.floor(bytes / (1024 * 1024 * 1024))} GB`;
};

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

const renderFolders = (folders) => {
  latestFolders = folders;
  dom.foldersList.innerHTML = "";
  dom.foldersEmpty.hidden = folders.length > 0;

  for (const folder of folders) {
    const status = folder.status || {};
    const totalBytes = status.totalBytes || 0;
    const syncedBytes = status.syncedBytes || 0;
    const fileCount = status.fileCount || 0;
    const syncStatus = status.status || "idle";
    const fraction = totalBytes > 0 ? (syncedBytes / totalBytes) * 100 : 0;

    const item = document.createElement("div");
    item.className = "list-item";
    item.innerHTML = `
      <div class="list-item-info">
        <div class="list-item-name">${escHtml(folder.name)}</div>
        <div class="list-item-detail">${escHtml(folder.path)}</div>
        <div class="list-item-detail">${escHtml(sharingText(folder))}</div>
        <div class="list-item-detail">
          ${escHtml(syncStatus)} &mdash;
          ${formatBytes(syncedBytes)} / ${formatBytes(totalBytes)}
          (${fileCount} files)
        </div>
      </div>
      <div class="list-item-right">
        ${syncStatus === "syncing" ? `
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
      ? `Storing ${stored.files} files (${formatBytes(stored.bytes)}) in ${stored.path}`
      : "";

    const item = document.createElement("div");
    item.className = "list-item";
    item.innerHTML = `
      <div class="list-item-info">
        <div class="list-item-name">${escHtml(buddy.name || "Unknown")}</div>
        <div class="list-item-detail">${escHtml(shortId)}</div>
        ${storedText ? `<div class="list-item-detail">${escHtml(storedText)}</div>` : ""}
      </div>
      <div class="list-item-right">
        ${latency ? `<span class="dim">${latency}</span>` : ""}
        <span class="state-${state === "connected" ? "connected" : "disconnected"}">${escHtml(state)}</span>
        <button class="btn btn-small btn-danger btn-remove-buddy" data-buddy="${escAttr(buddy.id)}">Remove</button>
      </div>
    `;
    dom.buddiesList.appendChild(item);
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
    const [status, folders, buddies, storage] = await Promise.all([
      api.get("/status"),
      api.get("/folders"),
      api.get("/buddies"),
      api.get("/storage").catch(() => ({ storage: [] })),
    ]);
    renderStatus(status);
    renderFolders(folders.folders || []);
    renderBuddies(buddies.buddies || [], storage.storage || []);
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
      document.getElementById("settings-sync-start").value = net.sync_window_start || "";
      document.getElementById("settings-sync-end").value = net.sync_window_end || "";
    } catch (e) {
      // leave empty
    }
    openDialog("dialog-settings");
  });

  // Sync All
  document.getElementById("btn-sync-all").addEventListener("click", async () => {
    try {
      const data = await api.get("/folders");
      const folders = data.folders || [];
      await Promise.all(folders.map((f) => api.post(`/sync/${f.name}`)));
      await refresh();
    } catch (e) {
      console.error("Sync all failed:", e);
    }
  });

  // Per-folder sync and remove (delegated)
  dom.foldersList.addEventListener("click", async (e) => {
    const syncBtn = e.target.closest(".btn-sync");
    if (syncBtn) {
      const name = syncBtn.dataset.folder;
      await api.post(`/sync/${encodeURIComponent(name)}`);
      await refresh();
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

  // Per-buddy remove (delegated)
  dom.buddiesList.addEventListener("click", async (e) => {
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
    if (!buddyId || !code) return;

    await api.post("/buddies/pair", { buddyId, buddyName, code });
    closeDialog("dialog-pair-buddy");
    await refresh();
  });

  // Settings dialog
  document.getElementById("btn-cancel-settings").addEventListener("click", () => {
    closeDialog("dialog-settings");
  });

  document.getElementById("btn-submit-settings").addEventListener("click", async (e) => {
    e.preventDefault();
    const body = { buddy: {}, network: {} };

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

    body.network.sync_window_start = document.getElementById("settings-sync-start").value.trim();
    body.network.sync_window_end = document.getElementById("settings-sync-end").value.trim();

    const result = await api.post("/config", body);
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
initEvents();
refresh();
refreshLogs();
setInterval(refresh, REFRESH_INTERVAL);
