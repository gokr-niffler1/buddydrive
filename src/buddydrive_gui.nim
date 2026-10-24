import std/[os, json, httpclient, options, osproc, strutils, times]
import chronos
import buddydrive/[cli, config as buddyconfig, control, recovery, sync/config_sync, types]

{.passl: gorge("pkg-config --libs gtk4").}

type
  GtkWidget* = pointer
  GtkWindow* = pointer
  GtkButton* = pointer
  GtkBox* = pointer
  GtkLabel* = pointer
  GtkListBox* = pointer
  GtkListBoxRow* = pointer
  GtkProgressBar* = pointer
  GtkApplication* = pointer
  GtkApplicationWindow* = pointer
  GtkScrolledWindow* = pointer
  GtkGrid* = pointer
  GtkSeparator* = pointer
  GApplication* = pointer
  GObject* = pointer
  GCallback* = pointer
  GApplicationFlags* = cint
  GConnectFlags* = cint
  GSourceFunc* = proc(data: pointer): cint {.cdecl.}

const
  GAPPLICATIONFLAGSNONE* = 0.GApplicationFlags
  GTKORIENTATIONHORIZONTAL* = 0.cint
  GTKORIENTATIONVERTICAL* = 1.cint

proc gtkInit*() {.cdecl, importc: "gtk_init".}
proc gtkWindowNew*(): GtkWindow {.cdecl, importc: "gtk_window_new".}
proc gtkWindowSetTitle*(window: GtkWindow, title: cstring) {.cdecl, importc: "gtk_window_set_title".}
proc gtkWindowSetDefaultSize*(window: GtkWindow, width: cint, height: cint) {.cdecl, importc: "gtk_window_set_default_size".}
proc gtkWindowSetChild*(window: GtkWindow, child: GtkWidget) {.cdecl, importc: "gtk_window_set_child".}
proc gtkWidgetShow*(widget: GtkWidget) {.cdecl, importc: "gtk_widget_show".}
proc gtkWidgetSetVisible*(widget: GtkWidget, visible: cint) {.cdecl, importc: "gtk_widget_set_visible".}
proc gtkBoxNew*(orientation: cint, spacing: cint): GtkBox {.cdecl, importc: "gtk_box_new".}
proc gtkBoxAppend*(box: GtkBox, child: GtkWidget) {.cdecl, importc: "gtk_box_append".}
proc gtkBoxPrepend*(box: GtkBox, child: GtkWidget) {.cdecl, importc: "gtk_box_prepend".}
proc gtkLabelNew*(text: cstring): GtkLabel {.cdecl, importc: "gtk_label_new".}
proc gtkLabelSetText*(label: GtkLabel, text: cstring) {.cdecl, importc: "gtk_label_set_text".}
proc gtkButtonNewWithLabel*(label: cstring): GtkButton {.cdecl, importc: "gtk_button_new_with_label".}
proc gtkButtonSetLabel*(button: GtkButton, label: cstring) {.cdecl, importc: "gtk_button_set_label".}
proc gtkApplicationNew*(applicationId: cstring, flags: GApplicationFlags): GtkApplication {.cdecl, importc: "gtk_application_new".}
proc gApplicationRun*(app: GApplication, argc: cint, argv: pointer): cint {.cdecl, importc: "g_application_run".}
proc gSignalConnectData*(instance: GObject, detailedSignal: cstring, cHandler: GCallback, data: pointer, destroyData: pointer, connectFlags: GConnectFlags): culong {.cdecl, importc: "g_signal_connect_data".}
proc gtkApplicationWindowNew*(app: GtkApplication): GtkWindow {.cdecl, importc: "gtk_application_window_new".}
proc gtkWidgetAddCssClass*(widget: GtkWidget, cssClass: cstring) {.cdecl, importc: "gtk_widget_add_css_class".}
proc gtkWidgetSetMarginStart*(widget: GtkWidget, margin: cint) {.cdecl, importc: "gtk_widget_set_margin_start".}
proc gtkWidgetSetMarginEnd*(widget: GtkWidget, margin: cint) {.cdecl, importc: "gtk_widget_set_margin_end".}
proc gtkWidgetSetMarginTop*(widget: GtkWidget, margin: cint) {.cdecl, importc: "gtk_widget_set_margin_top".}
proc gtkWidgetSetMarginBottom*(widget: GtkWidget, margin: cint) {.cdecl, importc: "gtk_widget_set_margin_bottom".}
proc gtkWidgetSetHexpand*(widget: GtkWidget, expand: cint) {.cdecl, importc: "gtk_widget_set_hexpand".}
proc gtkWidgetSetVexpand*(widget: GtkWidget, expand: cint) {.cdecl, importc: "gtk_widget_set_vexpand".}
proc gtkListBoxNew*(): GtkListBox {.cdecl, importc: "gtk_list_box_new".}
proc gtkListBoxAppend*(list: GtkListBox, row: GtkWidget) {.cdecl, importc: "gtk_list_box_append".}
proc gtkListBoxRemove*(list: GtkListBox, row: GtkWidget) {.cdecl, importc: "gtk_list_box_remove".}
proc gtkWidgetGetFirstChild*(widget: GtkWidget): GtkWidget {.cdecl, importc: "gtk_widget_get_first_child".}
proc gtkWidgetGetNextSibling*(widget: GtkWidget): GtkWidget {.cdecl, importc: "gtk_widget_get_next_sibling".}
proc gtkProgressBarNew*(): GtkProgressBar {.cdecl, importc: "gtk_progress_bar_new".}
proc gtkProgressBarSetFraction*(bar: GtkProgressBar, fraction: cdouble) {.cdecl, importc: "gtk_progress_bar_set_fraction".}
proc gtkProgressBarSetText*(bar: GtkProgressBar, text: cstring) {.cdecl, importc: "gtk_progress_bar_set_text".}
proc gtkProgressBarSetShowText*(bar: GtkProgressBar, showText: cint) {.cdecl, importc: "gtk_progress_bar_set_show_text".}
proc gtkScrolledWindowNew*(): GtkScrolledWindow {.cdecl, importc: "gtk_scrolled_window_new".}
proc gtkScrolledWindowSetChild*(window: GtkScrolledWindow, child: GtkWidget) {.cdecl, importc: "gtk_scrolled_window_set_child".}
proc gtkScrolledWindowSetPolicy*(window: GtkScrolledWindow, hscrollbar: cint, vscrollbar: cint) {.cdecl, importc: "gtk_scrolled_window_set_policy".}
proc gtkGridNew*(): GtkGrid {.cdecl, importc: "gtk_grid_new".}
proc gtkGridAttach*(grid: GtkGrid, child: GtkWidget, left: cint, top: cint, width: cint, height: cint) {.cdecl, importc: "gtk_grid_attach".}
proc gtkGridColumnSetSpacing*(grid: GtkGrid, spacing: cint) {.cdecl, importc: "gtk_grid_set_column_spacing".}
proc gtkGridRowSetSpacing*(grid: GtkGrid, spacing: cint) {.cdecl, importc: "gtk_grid_set_row_spacing".}
proc gtkWidgetSetHalign*(widget: GtkWidget, align: cint) {.cdecl, importc: "gtk_widget_set_halign".}
proc gtkLabelSetWrap*(label: GtkLabel, wrap: cint) {.cdecl, importc: "gtk_label_set_wrap".}
proc gtkLabelSetWrapMode*(label: GtkLabel, mode: cint) {.cdecl, importc: "gtk_label_set_wrap_mode".}
proc gTimeoutAdd*(interval: cuint, function: GSourceFunc, data: pointer): cuint {.cdecl, importc: "g_timeout_add".}
proc gtkSeparatorNew*(orientation: cint): GtkSeparator {.cdecl, importc: "gtk_separator_new".}

proc gSignalConnect*(instance: GObject, signal: cstring, cHandler: GCallback, data: pointer): culong =
  gSignalConnectData(instance, signal, cHandler, data, nil, 0.GConnectFlags)

proc gtkWindowSetDefaultIconName*(name: cstring) {.cdecl, importc: "gtk_window_set_default_icon_name".}

# Additional GTK imports for dialogs
proc gtkDialogNew*(): GtkWindow {.cdecl, importc: "gtk_dialog_new".}
proc gtkDialogAddButton*(dialog: GtkWindow, buttonText: cstring, responseId: cint): GtkButton {.cdecl, importc: "gtk_dialog_add_button".}
proc gtkDialogGetContentArea*(dialog: GtkWindow): GtkBox {.cdecl, importc: "gtk_dialog_get_content_area".}
proc gtkEntryNew*(): pointer {.cdecl, importc: "gtk_entry_new".}
proc gtkEditableGetText*(entry: pointer): cstring {.cdecl, importc: "gtk_editable_get_text".}
proc gtkEditableSetText*(entry: pointer, text: cstring) {.cdecl, importc: "gtk_editable_set_text".}
proc gtkEntrySetPlaceholderText*(entry: pointer, text: cstring) {.cdecl, importc: "gtk_entry_set_placeholder_text".}
proc gtkCheckButtonNew*(): pointer {.cdecl, importc: "gtk_check_button_new".}
proc gtkCheckButtonGetActive*(button: pointer): cint {.cdecl, importc: "gtk_check_button_get_active".}
proc gtkCheckButtonSetActive*(button: pointer, active: cint) {.cdecl, importc: "gtk_check_button_set_active".}
proc gtkCheckButtonSetLabel*(button: pointer, label: cstring) {.cdecl, importc: "gtk_check_button_set_label".}
proc gtkWidgetGrabFocus*(widget: GtkWidget) {.cdecl, importc: "gtk_widget_grab_focus".}
proc gtkWindowSetTransientFor*(window: GtkWindow, parent: GtkWindow) {.cdecl, importc: "gtk_window_set_transient_for".}
proc gtkWindowSetModal*(window: GtkWindow, modal: cint) {.cdecl, importc: "gtk_window_set_modal".}

const
  GTK_RESPONSE_OK = -5.cint
  GTK_RESPONSE_CANCEL = -6.cint

const
  AppId = "org.buddydrive.app"
type
  AppState = object
    window: GtkWindow
    client: HttpClient
    foldersList: GtkListBox
    buddiesList: GtkListBox
    statusLabel: GtkLabel
    messageLabel: GtkLabel
    buddyNameLabel: GtkLabel
    uptimeLabel: GtkLabel
    recoveryStatusLabel: GtkLabel
    running: bool
    controlAvailable: bool
    daemonProcess: Process

var
  app: GtkApplication
  state: AppState

proc apiBase(): string =
  let portPath = buddyconfig.getDataDir() / "port"
  if fileExists(portPath):
    let port = readFile(portPath).strip()
    if port.len > 0:
      return "http://127.0.0.1:" & port
  "http://127.0.0.1:" & $DefaultControlPort

proc currentConfig(): AppConfig =
  if buddyconfig.configExists():
    return buddyconfig.loadConfig()
  newAppConfig(newBuddyId("", ""))

proc resolveCliBinary(): string =
  let envPath = getEnv("BUDDYDRIVE_CLI", "").strip()
  if envPath.len > 0 and fileExists(envPath):
    return envPath
  let sibling = getAppDir() / "buddydrive"
  if fileExists(sibling):
    return sibling
  findExe("buddydrive")

proc setMessage(text: string) =
  gtkLabelSetText(state.messageLabel, cstring(text))

proc showMessageDialog(title, message: string) =
  let dialog = gtkDialogNew()
  gtkWindowSetTitle(dialog, cstring(title))
  gtkWindowSetModal(dialog, 1)
  gtkWindowSetTransientFor(dialog, state.window)
  gtkWindowSetDefaultSize(dialog, 520, 240)
  discard gtkDialogAddButton(dialog, "OK", GTK_RESPONSE_OK)
  let content = gtkDialogGetContentArea(dialog)
  gtkWidgetSetMarginStart(content, 16)
  gtkWidgetSetMarginEnd(content, 16)
  gtkWidgetSetMarginTop(content, 16)
  gtkWidgetSetMarginBottom(content, 16)
  let label = gtkLabelNew(cstring(message))
  gtkLabelSetWrap(label, 1)
  gtkBoxAppend(content, label)

  proc onMessageResponse(w: GtkWindow, responseId: cint, userData: pointer) {.cdecl.} =
    gtkWidgetSetVisible(w, 0)

  discard gSignalConnect(cast[GObject](dialog), "response", cast[GCallback](onMessageResponse), nil)
  gtkWidgetShow(dialog)

proc sharedString(value: string): pointer =
  result = allocShared0(value.len + 1)
  if value.len > 0:
    copyMem(result, unsafeAddr value[0], value.len)

proc readSharedString(data: pointer): string =
  if data == nil:
    return ""
  $cast[cstring](data)

proc apiGet(endpoint: string): JsonNode =
  try:
    let resp = state.client.getContent(apiBase() & endpoint)
    result = parseJson(resp)
  except:
    result = %*{"error": getCurrentExceptionMsg()}

proc apiPost(endpoint: string, body: JsonNode = %*{}): JsonNode =
  try:
    let resp = state.client.postContent(apiBase() & endpoint, $body)
    result = parseJson(resp)
  except:
    result = %*{"error": getCurrentExceptionMsg()}

proc localConfigJson(): JsonNode =
  if not buddyconfig.configExists():
    return %*{"buddy": {}, "network": {}, "folders": [], "buddies": []}
  let cfg = buddyconfig.loadConfig()
  var folders: seq[JsonNode] = @[]
  for folder in cfg.folders:
    folders.add(%*{
      "name": folder.name,
      "path": folder.path,
      "encrypted": folder.encrypted,
      "append_only": folder.appendOnly,
      "buddies": folder.buddies
    })
  var buddies: seq[JsonNode] = @[]
  for buddy in cfg.buddies:
    buddies.add(%*{
      "id": buddy.id.uuid,
      "name": buddy.id.name,
      "pairing_code": buddy.pairingCode,
      "sync_time": buddy.syncTime,
      "addedAt": buddy.addedAt.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    })
  %*{
    "buddy": {
      "name": cfg.buddy.name,
      "id": cfg.buddy.uuid
    },
    "network": {
      "listen_port": cfg.listenPort,
      "announce_addr": cfg.announceAddr,
      "api_base_url": cfg.apiBaseUrl,
      "relay_region": cfg.relayRegion,
      "storage_base_path": cfg.storageBasePath,
      "bandwidth_limit_kbps": cfg.bandwidthLimitKBps
    },
    "folders": folders,
    "buddies": buddies
  }

proc localFoldersJson(): JsonNode =
  let cfgJson = localConfigJson()
  var folders: seq[JsonNode] = @[]
  for folder in cfgJson{"folders"}.getElems():
    folders.add(%*{
      "name": folder{"name"}.getStr(""),
      "path": folder{"path"}.getStr(""),
      "encrypted": folder{"encrypted"}.getBool(true),
      "appendOnly": folder{"append_only"}.getBool(false),
      "buddies": folder{"buddies"},
      "status": {
        "totalBytes": 0,
        "syncedBytes": 0,
        "fileCount": 0,
        "syncedFiles": 0,
        "status": "idle"
      }
    })
  %*{"folders": folders}

proc localBuddiesJson(): JsonNode =
  let cfgJson = localConfigJson()
  var buddies: seq[JsonNode] = @[]
  for buddy in cfgJson{"buddies"}.getElems():
    buddies.add(%*{
      "id": buddy{"id"}.getStr(""),
      "name": buddy{"name"}.getStr(""),
      "pairingCode": buddy{"pairing_code"}.getStr(""),
      "syncTime": buddy{"sync_time"}.getStr(""),
      "state": "disconnected",
      "latencyMs": -1,
      "lastSync": buddy{"addedAt"}.getStr("")
    })
  %*{"buddies": buddies}

proc refreshUI(userData: pointer): cint {.cdecl.}

proc saveConfigAndRefresh(cfg: AppConfig) =
  buddyconfig.saveConfig(cfg)
  if state.controlAvailable:
    discard apiPost("/config/reload")
  discard refreshUI(nil)

proc splitBuddyIds(value: string): seq[string] =
  for part in value.split(','):
    let trimmed = part.strip()
    if trimmed.len > 0:
      result.add(trimmed)

proc updateFolderConfig(originalName, newName, newPath: string, encrypted, appendOnly: bool, buddyIds: seq[string]): bool =
  if not buddyconfig.configExists():
    return false
  var cfg = currentConfig()
  let idx = cfg.getFolder(originalName)
  if idx < 0:
    return false
  cfg.folders[idx].name = newName
  cfg.folders[idx].path = newPath
  cfg.folders[idx].encrypted = encrypted
  cfg.folders[idx].appendOnly = appendOnly
  cfg.folders[idx].buddies = buddyIds
  saveConfigAndRefresh(cfg)
  true

proc updateBuddyConfig(originalId, name, pairingCode, syncTime: string): bool =
  if not buddyconfig.configExists():
    return false
  var cfg = currentConfig()
  let idx = cfg.getBuddy(originalId)
  if idx < 0:
    return false
  cfg.buddies[idx].id.name = name
  cfg.buddies[idx].pairingCode = pairingCode
  cfg.buddies[idx].syncTime = syncTime
  saveConfigAndRefresh(cfg)
  true

proc removeFolderLocal(name: string): bool =
  if not buddyconfig.configExists():
    return false
  var cfg = currentConfig()
  result = cfg.removeFolder(name)
  discard refreshUI(nil)

proc removeBuddyLocal(id: string): bool =
  if not buddyconfig.configExists():
    return false
  var cfg = currentConfig()
  result = cfg.removeBuddy(id)
  discard refreshUI(nil)

proc showAddFolderDialog(originalName, currentName, currentPath: string, encrypted, appendOnly: bool, buddies: seq[string])
proc showPairBuddyDialog(originalId, buddyId, buddyName, code, syncTime: string)

proc formatBytes(bytes: int64): string =
  if bytes < 1024:
    $bytes & " B"
  elif bytes < 1024 * 1024:
    $(bytes div 1024) & " KB"
  elif bytes < 1024 * 1024 * 1024:
    $(bytes div (1024 * 1024)) & " MB"
  else:
    $(bytes div (1024 * 1024 * 1024)) & " GB"

proc onFolderSyncClick(btn: GtkButton, userData: pointer) {.cdecl.} =
  let folderName = readSharedString(userData)
  if folderName.len > 0 and state.controlAvailable:
    discard apiPost("/sync/" & folderName)
    setMessage("Sync requested for folder '" & folderName & "'.")
  else:
    setMessage("Daemon is not running; cannot trigger sync.")
  deallocShared(userData)

proc onFolderEditClick(btn: GtkButton, userData: pointer) {.cdecl.} =
  let folderName = readSharedString(userData)
  let cfg = currentConfig()
  let idx = cfg.getFolder(folderName)
  if idx >= 0:
    let folder = cfg.folders[idx]
    showAddFolderDialog(folder.name, folder.name, folder.path, folder.encrypted, folder.appendOnly, folder.buddies)
  deallocShared(userData)

proc onFolderRemoveClick(btn: GtkButton, userData: pointer) {.cdecl.} =
  let folderName = readSharedString(userData)
  if removeFolderLocal(folderName):
    setMessage("Removed folder '" & folderName & "'.")
  else:
    setMessage("Folder not found: " & folderName)
  deallocShared(userData)

proc onBuddyEditClick(btn: GtkButton, userData: pointer) {.cdecl.} =
  let buddyId = readSharedString(userData)
  let cfg = currentConfig()
  let idx = cfg.getBuddy(buddyId)
  if idx >= 0:
    let buddy = cfg.buddies[idx]
    showPairBuddyDialog(buddy.id.uuid, buddy.id.uuid, buddy.id.name, buddy.pairingCode, buddy.syncTime)
  deallocShared(userData)

proc onBuddyRemoveClick(btn: GtkButton, userData: pointer) {.cdecl.} =
  let buddyId = readSharedString(userData)
  if removeBuddyLocal(buddyId):
    setMessage("Removed buddy '" & buddyId & "'.")
  else:
    setMessage("Buddy not found: " & buddyId)
  deallocShared(userData)

proc createSectionCard(title: string): tuple[box: GtkBox, content: GtkBox] =
  let card = gtkBoxNew(GTKORIENTATIONVERTICAL, 8)
  gtkWidgetAddCssClass(card, "card")
  gtkWidgetSetMarginStart(card, 12)
  gtkWidgetSetMarginEnd(card, 12)
  gtkWidgetSetMarginTop(card, 12)
  gtkWidgetSetMarginBottom(card, 12)
  
  let titleLabel = gtkLabelNew(cstring(title))
  gtkWidgetAddCssClass(titleLabel, "title-4")
  gtkWidgetSetMarginBottom(titleLabel, 8)
  gtkBoxAppend(card, titleLabel)
  
  let content = gtkBoxNew(GTKORIENTATIONVERTICAL, 4)
  gtkBoxAppend(card, content)
  
  result = (card, content)

proc createFolderRow(folder: JsonNode): GtkBox =
  let row = gtkBoxNew(GTKORIENTATIONHORIZONTAL, 12)
  gtkWidgetSetMarginStart(row, 8)
  gtkWidgetSetMarginEnd(row, 8)
  gtkWidgetSetMarginTop(row, 8)
  gtkWidgetSetMarginBottom(row, 8)
  
  let leftBox = gtkBoxNew(GTKORIENTATIONVERTICAL, 4)
  gtkWidgetSetHexpand(leftBox, 1)
  
  let nameText = folder{"name"}.getStr("Unknown")
  let nameLabel = gtkLabelNew(cstring(nameText))
  gtkWidgetAddCssClass(nameLabel, "title")
  gtkWidgetSetHexpand(nameLabel, 1)
  gtkBoxAppend(leftBox, nameLabel)
  
  let pathText = folder{"path"}.getStr("")
  let pathLabel = gtkLabelNew(cstring(pathText))
  gtkWidgetAddCssClass(pathLabel, "dim-label")
  gtkWidgetAddCssClass(pathLabel, "caption")
  gtkBoxAppend(leftBox, pathLabel)
  
  let status = folder{"status"}
  let appendOnly = folder{"appendOnly"}.getBool(folder{"append_only"}.getBool(false))
  let totalBytes = status{"totalBytes"}.getInt(0)
  let syncedBytes = status{"syncedBytes"}.getInt(0)
  let fileCount = status{"fileCount"}.getInt(0)
  let syncStatus = status{"status"}.getStr("idle")
  
  let statusText = syncStatus & " - " & formatBytes(syncedBytes) & " / " & formatBytes(totalBytes) & " (" & $fileCount & " files)"
  let statusLabel = gtkLabelNew(cstring(statusText))
  gtkWidgetAddCssClass(statusLabel, "caption")
  gtkBoxAppend(leftBox, statusLabel)

  let detailsLabel = gtkLabelNew(cstring("Encrypted: " & $folder{"encrypted"}.getBool(true) & " | Append-only: " & $appendOnly))
  gtkWidgetAddCssClass(detailsLabel, "caption")
  gtkBoxAppend(leftBox, detailsLabel)
  
  gtkBoxAppend(row, leftBox)

  let actions = gtkBoxNew(GTKORIENTATIONHORIZONTAL, 6)
  let syncBtn = gtkButtonNewWithLabel("Sync")
  let editBtn = gtkButtonNewWithLabel("Edit")
  let removeBtn = gtkButtonNewWithLabel("Remove")
  gtkBoxAppend(actions, syncBtn)
  gtkBoxAppend(actions, editBtn)
  gtkBoxAppend(actions, removeBtn)
  let folderNameData1 = sharedString(nameText)
  let folderNameData2 = sharedString(nameText)
  let folderNameData3 = sharedString(nameText)
  discard gSignalConnect(cast[GObject](syncBtn), "clicked", cast[GCallback](onFolderSyncClick), folderNameData1)
  discard gSignalConnect(cast[GObject](editBtn), "clicked", cast[GCallback](onFolderEditClick), folderNameData2)
  discard gSignalConnect(cast[GObject](removeBtn), "clicked", cast[GCallback](onFolderRemoveClick), folderNameData3)
  gtkBoxAppend(row, actions)
  
  if syncStatus == "syncing":
    let progress = gtkProgressBarNew()
    let fraction = if totalBytes > 0: syncedBytes.float / totalBytes.float else: 0.0
    gtkProgressBarSetFraction(progress, fraction.cdouble)
    gtkProgressBarSetShowText(progress, 1)
    gtkBoxAppend(row, progress)
  
  result = row

proc createBuddyRow(buddy: JsonNode): GtkBox =
  let row = gtkBoxNew(GTKORIENTATIONHORIZONTAL, 12)
  gtkWidgetSetMarginStart(row, 8)
  gtkWidgetSetMarginEnd(row, 8)
  gtkWidgetSetMarginTop(row, 8)
  gtkWidgetSetMarginBottom(row, 8)
  
  let leftBox = gtkBoxNew(GTKORIENTATIONVERTICAL, 4)
  gtkWidgetSetHexpand(leftBox, 1)
  
  let nameText = buddy{"name"}.getStr("Unknown")
  let nameLabel = gtkLabelNew(cstring(nameText))
  gtkWidgetAddCssClass(nameLabel, "title")
  gtkWidgetSetHexpand(nameLabel, 1)
  gtkBoxAppend(leftBox, nameLabel)
  
  let buddyId = buddy{"id"}.getStr("")
  let shortBuddyId =
    if buddyId.len == 0: ""
    elif buddyId.len <= 16: buddyId
    else: buddyId[0 .. 15] & "..."
  let idLabel = gtkLabelNew(cstring(shortBuddyId))
  gtkWidgetAddCssClass(idLabel, "dim-label")
  gtkWidgetAddCssClass(idLabel, "caption")
  gtkBoxAppend(leftBox, idLabel)

  let pairingCode = buddy{"pairingCode"}.getStr(buddy{"pairing_code"}.getStr(""))
  let syncTime = buddy{"syncTime"}.getStr(buddy{"sync_time"}.getStr(""))
  let detailsText =
    if pairingCode.len > 0 or syncTime.len > 0:
      "Code: " & pairingCode & (if syncTime.len > 0: " | Sync time: " & syncTime else: "")
    else:
      ""
  if detailsText.len > 0:
    let detailsLabel = gtkLabelNew(cstring(detailsText))
    gtkWidgetAddCssClass(detailsLabel, "caption")
    gtkBoxAppend(leftBox, detailsLabel)

  if buddyId.len > 0 and buddyconfig.configExists():
    try:
      let storageText = "Storage: " & buddyconfig.loadConfig().buddyStorageRoot(buddyId)
      let storageLabel = gtkLabelNew(cstring(storageText))
      gtkWidgetAddCssClass(storageLabel, "caption")
      gtkWidgetAddCssClass(storageLabel, "dim-label")
      gtkBoxAppend(leftBox, storageLabel)
    except CatchableError:
      discard
  
  gtkBoxAppend(row, leftBox)

  let actions = gtkBoxNew(GTKORIENTATIONHORIZONTAL, 6)
  let editBtn = gtkButtonNewWithLabel("Edit")
  let removeBtn = gtkButtonNewWithLabel("Remove")
  gtkBoxAppend(actions, editBtn)
  gtkBoxAppend(actions, removeBtn)
  let buddyIdData1 = sharedString(buddyId)
  let buddyIdData2 = sharedString(buddyId)
  discard gSignalConnect(cast[GObject](editBtn), "clicked", cast[GCallback](onBuddyEditClick), buddyIdData1)
  discard gSignalConnect(cast[GObject](removeBtn), "clicked", cast[GCallback](onBuddyRemoveClick), buddyIdData2)
  gtkBoxAppend(row, actions)
  
  let stateText = buddy{"state"}.getStr("disconnected")
  let stateLabel = gtkLabelNew(cstring(stateText))
  let cssClass = if stateText == "connected": "success" else: "warning"
  gtkWidgetAddCssClass(stateLabel, cstring(cssClass))
  gtkBoxAppend(row, stateLabel)
  
  result = row

proc clearListBox(list: GtkListBox) =
  var child = gtkWidgetGetFirstChild(list)
  while child != nil:
    let next = gtkWidgetGetNextSibling(child)
    gtkListBoxRemove(list, child)
    child = next

proc refreshUI(userData: pointer): cint {.cdecl.} =
  let statusJson = apiGet("/status")
  state.controlAvailable = not statusJson.hasKey("error")

  let fallbackConfig = localConfigJson()
  let effectiveStatus = if state.controlAvailable: statusJson else: %*{
    "buddy": {
      "name": fallbackConfig{"buddy"}{"name"}.getStr("Unknown"),
      "id": fallbackConfig{"buddy"}{"id"}.getStr("")
    },
    "running": false,
    "uptime": 0
  }

  state.running = effectiveStatus{"running"}.getBool(false)

  let buddyName = effectiveStatus{"buddy"}{"name"}.getStr("Unknown")
  let nameText = "Identity: " & buddyName
  gtkLabelSetText(state.buddyNameLabel, cstring(nameText))
  
  let uptime = effectiveStatus{"uptime"}.getInt(0)
  let hours = uptime div 3600
  let mins = (uptime mod 3600) div 60
  let uptimeText = "Uptime: " & $hours & "h " & $mins & "m"
  gtkLabelSetText(state.uptimeLabel, cstring(uptimeText))
  
  let statusText = if state.running: "Running" else: "Stopped"
  gtkLabelSetText(state.statusLabel, cstring(statusText))
  
  let recoveryEnabled = if buddyconfig.configExists(): currentConfig().recovery.enabled else: false
  let recoveryText = if recoveryEnabled: "Recovery enabled" else: "Not set up"
  gtkLabelSetText(state.recoveryStatusLabel, cstring(recoveryText))

  let foldersJson = if state.controlAvailable: apiGet("/folders") else: localFoldersJson()
  let folders = foldersJson{"folders"}.getElems()

  clearListBox(state.foldersList)
  for folder in folders:
    let row = createFolderRow(folder)
    gtkListBoxAppend(state.foldersList, row)

  let buddiesJson = if state.controlAvailable: apiGet("/buddies") else: localBuddiesJson()
  let buddies = buddiesJson{"buddies"}.getElems()

  clearListBox(state.buddiesList)
  for buddy in buddies:
    let row = createBuddyRow(buddy)
    gtkListBoxAppend(state.buddiesList, row)

  if not buddyconfig.configExists():
    setMessage("Initialize BuddyDrive to get started.")
  elif state.controlAvailable and not state.running:
    setMessage("Config loaded. Daemon is not running.")
  elif not state.controlAvailable:
    setMessage("Control API unavailable. Showing local config only.")
  else:
    setMessage("")
  
  result = 1

# Dialog helper procs
type
  AddFolderData = object
    dialog: GtkWindow
    nameEntry: pointer
    pathEntry: pointer
    encryptCheck: pointer
    appendOnlyCheck: pointer
    buddiesEntry: pointer
    originalName: string
  
  PairBuddyData = object
    dialog: GtkWindow
    idEntry: pointer
    nameEntry: pointer
    codeEntry: pointer
    syncTimeEntry: pointer
    originalId: string
   
  SettingsData = object
    dialog: GtkWindow
    nameEntry: pointer
    portEntry: pointer
    announceEntry: pointer
    relayUrlEntry: pointer
    relayRegionEntry: pointer
    storageBaseEntry: pointer
    bandwidthEntry: pointer

  SetupRecoveryData = object
    dialog: GtkWindow
    wordEntries: ptr UncheckedArray[pointer]
    verifyLabel: GtkLabel
    expectedWords: seq[string]
    recoveryCfg: RecoveryConfig

  RecoverData = object
    dialog: GtkWindow
    wordEntries: ptr UncheckedArray[pointer]

proc onAddFolderResponse(w: GtkWindow, responseId: cint, userData: pointer) {.cdecl.} =
  let data = cast[ptr AddFolderData](userData)
  if responseId == GTK_RESPONSE_OK:
    let name = $gtkEditableGetText(data.nameEntry)
    let path = $gtkEditableGetText(data.pathEntry)
    let encrypted = gtkCheckButtonGetActive(data.encryptCheck) == 1
    let appendOnly = gtkCheckButtonGetActive(data.appendOnlyCheck) == 1
    let buddyIds = splitBuddyIds($gtkEditableGetText(data.buddiesEntry))

    if name.len > 0 and path.len > 0:
      if data.originalName.len == 0:
        var cfg = currentConfig()
        var folder = newSyncFolder(name, path, encrypted)
        folder.appendOnly = appendOnly
        folder.buddies = buddyIds
        cfg.addFolder(folder)
        discard refreshUI(nil)
      else:
        discard updateFolderConfig(data.originalName, name, path, encrypted, appendOnly, buddyIds)
  
  gtkWidgetSetVisible(data.dialog, 0)
  deallocShared(userData)

proc onPairBuddyResponse(w: GtkWindow, responseId: cint, userData: pointer) {.cdecl.} =
  let data = cast[ptr PairBuddyData](userData)
  if responseId == GTK_RESPONSE_OK:
    let buddyId = $gtkEditableGetText(data.idEntry)
    let buddyName = $gtkEditableGetText(data.nameEntry)
    let code = $gtkEditableGetText(data.codeEntry)
    let syncTime = $gtkEditableGetText(data.syncTimeEntry)

    if data.originalId.len > 0:
      discard updateBuddyConfig(data.originalId, buddyName, code, syncTime)
    elif buddyId.len > 0 and code.len > 0:
      var cfg = currentConfig()
      var buddy: BuddyInfo
      buddy.id = newBuddyId(buddyId, buddyName)
      buddy.pairingCode = code
      buddy.syncTime = syncTime
      buddy.addedAt = getTime()
      cfg.addBuddy(buddy)
      discard refreshUI(nil)
  
  gtkWidgetSetVisible(data.dialog, 0)
  deallocShared(userData)

proc onSettingsResponse(w: GtkWindow, responseId: cint, userData: pointer) {.cdecl.} =
  let data = cast[ptr SettingsData](userData)
  if responseId == GTK_RESPONSE_OK:
    var cfg = currentConfig()

    let name = $gtkEditableGetText(data.nameEntry)
    if name.len > 0:
      cfg.buddy.name = name
    
    let portStr = $gtkEditableGetText(data.portEntry)
    if portStr.len > 0:
      try:
        cfg.listenPort = portStr.parseInt()
      except:
        discard
    
    let announce = $gtkEditableGetText(data.announceEntry)
    cfg.announceAddr = announce
    
    let relayUrl = $gtkEditableGetText(data.relayUrlEntry)
    cfg.apiBaseUrl = relayUrl
    
    let relayRegion = $gtkEditableGetText(data.relayRegionEntry)
    cfg.relayRegion = relayRegion

    let storageBasePath = $gtkEditableGetText(data.storageBaseEntry)
    cfg.storageBasePath = storageBasePath

    let bandwidth = $gtkEditableGetText(data.bandwidthEntry)
    if bandwidth.len > 0:
      try:
        cfg.bandwidthLimitKBps = bandwidth.parseInt()
      except ValueError:
        discard
    
    saveConfigAndRefresh(cfg)
  
  gtkWidgetSetVisible(data.dialog, 0)
  deallocShared(userData)

proc showAddFolderDialog() =
  showAddFolderDialog("", "", "", true, false, @[])

proc showAddFolderDialog(originalName, currentName, currentPath: string, encrypted, appendOnly: bool, buddies: seq[string]) =
  let dialog = gtkDialogNew()
  gtkWindowSetTitle(dialog, cstring(if originalName.len == 0: "Add Folder" else: "Edit Folder"))
  gtkWindowSetModal(dialog, 1)
  gtkWindowSetTransientFor(dialog, state.window)
  gtkWindowSetDefaultSize(dialog, 450, 250)
  
  discard gtkDialogAddButton(dialog, "Cancel", GTK_RESPONSE_CANCEL)
  discard gtkDialogAddButton(dialog, "Add", GTK_RESPONSE_OK)
  
  let content = gtkDialogGetContentArea(dialog)
  gtkWidgetSetMarginStart(content, 16)
  gtkWidgetSetMarginEnd(content, 16)
  gtkWidgetSetMarginTop(content, 16)
  gtkWidgetSetMarginBottom(content, 16)
  
  let nameLabel = gtkLabelNew("Folder name:")
  gtkWidgetSetHexpand(nameLabel, 1)
  gtkBoxAppend(content, nameLabel)
  
  let nameEntry = gtkEntryNew()
  gtkEntrySetPlaceholderText(nameEntry, "My Documents")
  if currentName.len > 0:
    gtkEditableSetText(nameEntry, currentName.cstring)
  gtkWidgetSetMarginBottom(nameEntry, 12)
  gtkBoxAppend(content, nameEntry)
  
  let pathLabel = gtkLabelNew("Folder path:")
  gtkBoxAppend(content, pathLabel)
  
  let pathEntry = gtkEntryNew()
  gtkEntrySetPlaceholderText(pathEntry, "/home/user/Documents")
  if currentPath.len > 0:
    gtkEditableSetText(pathEntry, currentPath.cstring)
  gtkWidgetSetMarginBottom(pathEntry, 12)
  gtkBoxAppend(content, pathEntry)
  
  let encryptCheck = gtkCheckButtonNew()
  gtkCheckButtonSetLabel(encryptCheck, "Encrypt folder contents")
  if encrypted:
    gtkCheckButtonSetActive(encryptCheck, 1)
  gtkWidgetSetMarginBottom(encryptCheck, 8)
  gtkBoxAppend(content, encryptCheck)

  let appendOnlyCheck = gtkCheckButtonNew()
  gtkCheckButtonSetLabel(appendOnlyCheck, "Append-only")
  if appendOnly:
    gtkCheckButtonSetActive(appendOnlyCheck, 1)
  gtkWidgetSetMarginBottom(appendOnlyCheck, 8)
  gtkBoxAppend(content, appendOnlyCheck)

  let buddiesLabel = gtkLabelNew("Buddy IDs (comma-separated, optional):")
  gtkBoxAppend(content, buddiesLabel)

  let buddiesEntry = gtkEntryNew()
  if buddies.len > 0:
    gtkEditableSetText(buddiesEntry, buddies.join(", ").cstring)
  gtkWidgetSetMarginBottom(buddiesEntry, 12)
  gtkBoxAppend(content, buddiesEntry)
  
  let data = cast[ptr AddFolderData](allocShared0(sizeof(AddFolderData)))
  data.dialog = dialog
  data.nameEntry = nameEntry
  data.pathEntry = pathEntry
  data.encryptCheck = encryptCheck
  data.appendOnlyCheck = appendOnlyCheck
  data.buddiesEntry = buddiesEntry
  data.originalName = originalName
  
  discard gSignalConnect(cast[GObject](dialog), "response", cast[GCallback](onAddFolderResponse), cast[pointer](data))
  
  gtkWidgetShow(dialog)
  gtkWidgetGrabFocus(nameEntry)

proc showPairBuddyDialog() =
  showPairBuddyDialog("", "", "", "", "")

proc onGenerateCodeClick(btn: GtkButton, userData: pointer) {.cdecl.} =
  gtkEditableSetText(userData, generatePairingCode().cstring)

proc showPairBuddyDialog(originalId, buddyId, buddyName, code, syncTime: string) =
  let dialog = gtkDialogNew()
  gtkWindowSetTitle(dialog, cstring(if originalId.len == 0: "Pair with Buddy" else: "Edit Buddy"))
  gtkWindowSetModal(dialog, 1)
  gtkWindowSetTransientFor(dialog, state.window)
  gtkWindowSetDefaultSize(dialog, 450, 280)
  
  discard gtkDialogAddButton(dialog, "Cancel", GTK_RESPONSE_CANCEL)
  discard gtkDialogAddButton(dialog, "Pair", GTK_RESPONSE_OK)
  
  let content = gtkDialogGetContentArea(dialog)
  gtkWidgetSetMarginStart(content, 16)
  gtkWidgetSetMarginEnd(content, 16)
  gtkWidgetSetMarginTop(content, 16)
  gtkWidgetSetMarginBottom(content, 16)
  
  let infoLabel = gtkLabelNew("Enter your buddy's information:")
  gtkWidgetSetMarginBottom(infoLabel, 12)
  gtkBoxAppend(content, infoLabel)
  
  let idLabel = gtkLabelNew("Buddy ID:")
  gtkBoxAppend(content, idLabel)
  
  let idEntry = gtkEntryNew()
  gtkEntrySetPlaceholderText(idEntry, "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
  if buddyId.len > 0:
    gtkEditableSetText(idEntry, buddyId.cstring)
  gtkWidgetSetMarginBottom(idEntry, 8)
  gtkBoxAppend(content, idEntry)
  
  let nameLabel = gtkLabelNew("Buddy name (optional):")
  gtkBoxAppend(content, nameLabel)
  
  let nameEntry = gtkEntryNew()
  gtkEntrySetPlaceholderText(nameEntry, "Alice")
  if buddyName.len > 0:
    gtkEditableSetText(nameEntry, buddyName.cstring)
  gtkWidgetSetMarginBottom(nameEntry, 8)
  gtkBoxAppend(content, nameEntry)
  
  let codeLabel = gtkLabelNew("Pairing code:")
  gtkBoxAppend(content, codeLabel)
  
  let codeRow = gtkBoxNew(GTKORIENTATIONHORIZONTAL, 6)
  let codeEntry = gtkEntryNew()
  gtkEntrySetPlaceholderText(codeEntry, "ABCD-EFGH")
  if code.len > 0:
    gtkEditableSetText(codeEntry, code.cstring)
  gtkWidgetSetHexpand(codeEntry, 1)
  gtkBoxAppend(codeRow, codeEntry)
  let generateBtn = gtkButtonNewWithLabel("Generate")
  gtkBoxAppend(codeRow, generateBtn)
  discard gSignalConnect(cast[GObject](generateBtn), "clicked", cast[GCallback](onGenerateCodeClick), codeEntry)
  gtkBoxAppend(content, codeRow)

  let codeHint = gtkLabelNew(cstring(
    "Enter the code your buddy sent you, or generate one and send it to them " &
    "together with your Buddy ID: " & currentConfig().buddy.uuid & ". Both of you must use the same code."))
  gtkLabelSetWrap(codeHint, 1)
  gtkWidgetAddCssClass(codeHint, "caption")
  gtkWidgetAddCssClass(codeHint, "dim-label")
  gtkWidgetSetMarginBottom(codeHint, 8)
  gtkBoxAppend(content, codeHint)

  let syncTimeLabel = gtkLabelNew("Sync time (optional, HH:MM):")
  gtkBoxAppend(content, syncTimeLabel)

  let syncTimeEntry = gtkEntryNew()
  gtkEntrySetPlaceholderText(syncTimeEntry, "03:00")
  if syncTime.len > 0:
    gtkEditableSetText(syncTimeEntry, syncTime.cstring)
  gtkBoxAppend(content, syncTimeEntry)
  
  let data = cast[ptr PairBuddyData](allocShared0(sizeof(PairBuddyData)))
  data.dialog = dialog
  data.idEntry = idEntry
  data.nameEntry = nameEntry
  data.codeEntry = codeEntry
  data.syncTimeEntry = syncTimeEntry
  data.originalId = originalId
  
  discard gSignalConnect(cast[GObject](dialog), "response", cast[GCallback](onPairBuddyResponse), cast[pointer](data))
  
  gtkWidgetShow(dialog)
  gtkWidgetGrabFocus(idEntry)

proc showSettingsDialog() =
  if not buddyconfig.configExists():
    showMessageDialog("Settings", "Initialize BuddyDrive first.")
    return
  let configJson = localConfigJson()
  
  let dialog = gtkDialogNew()
  gtkWindowSetTitle(dialog, "Settings")
  gtkWindowSetModal(dialog, 1)
  gtkWindowSetTransientFor(dialog, state.window)
  gtkWindowSetDefaultSize(dialog, 500, 450)
  
  discard gtkDialogAddButton(dialog, "Cancel", GTK_RESPONSE_CANCEL)
  discard gtkDialogAddButton(dialog, "Save", GTK_RESPONSE_OK)
  
  let content = gtkDialogGetContentArea(dialog)
  gtkWidgetSetMarginStart(content, 16)
  gtkWidgetSetMarginEnd(content, 16)
  gtkWidgetSetMarginTop(content, 16)
  gtkWidgetSetMarginBottom(content, 16)
  
  # Identity section
  let identityLabel = gtkLabelNew("Identity")
  gtkWidgetAddCssClass(identityLabel, "title-3")
  gtkWidgetSetMarginBottom(identityLabel, 8)
  gtkBoxAppend(content, identityLabel)
  
  let nameLabel = gtkLabelNew("Your name:")
  gtkBoxAppend(content, nameLabel)
  
  let nameEntry = gtkEntryNew()
  let currentName = configJson{"buddy"}{"name"}.getStr("")
  if currentName.len > 0:
    gtkEditableSetText(nameEntry, currentName.cstring)
  gtkWidgetSetMarginBottom(nameEntry, 16)
  gtkBoxAppend(content, nameEntry)
  
  # Network section
  let networkLabel = gtkLabelNew("Network")
  gtkWidgetAddCssClass(networkLabel, "title-3")
  gtkWidgetSetMarginBottom(networkLabel, 8)
  gtkBoxAppend(content, networkLabel)
  
  let portLabel = gtkLabelNew("Listen port:")
  gtkBoxAppend(content, portLabel)
  
  let portEntry = gtkEntryNew()
  let currentPort = configJson{"network"}{"listen_port"}.getInt(41721)
  gtkEditableSetText(portEntry, cstring($currentPort))
  gtkWidgetSetMarginBottom(portEntry, 8)
  gtkBoxAppend(content, portEntry)
  
  let announceLabel = gtkLabelNew("Announce address (optional):")
  gtkBoxAppend(content, announceLabel)
  
  let announceEntry = gtkEntryNew()
  gtkEntrySetPlaceholderText(announceEntry, "/ip4/203.0.113.10/tcp/41721")
  let currentAnnounce = configJson{"network"}{"announce_addr"}.getStr("")
  if currentAnnounce.len > 0:
    gtkEditableSetText(announceEntry, currentAnnounce.cstring)
  gtkWidgetSetMarginBottom(announceEntry, 16)
  gtkBoxAppend(content, announceEntry)
  
  # Relay section
  let relayLabel = gtkLabelNew("Relay Fallback")
  gtkWidgetAddCssClass(relayLabel, "title-3")
  gtkWidgetSetMarginBottom(relayLabel, 8)
  gtkBoxAppend(content, relayLabel)
  
  let relayUrlLabel = gtkLabelNew("Relay base URL:")
  gtkBoxAppend(content, relayUrlLabel)
  
  let relayUrlEntry = gtkEntryNew()
  gtkEntrySetPlaceholderText(relayUrlEntry, "https://api.buddydrive.org")
  let currentRelayUrl = configJson{"network"}{"api_base_url"}.getStr("")
  if currentRelayUrl.len > 0:
    gtkEditableSetText(relayUrlEntry, currentRelayUrl.cstring)
  gtkWidgetSetMarginBottom(relayUrlEntry, 8)
  gtkBoxAppend(content, relayUrlEntry)
  
  let relayRegionLabel = gtkLabelNew("Relay region:")
  gtkBoxAppend(content, relayRegionLabel)
  
  let relayRegionEntry = gtkEntryNew()
  gtkEntrySetPlaceholderText(relayRegionEntry, "eu")
  let currentRelayRegion = configJson{"network"}{"relay_region"}.getStr("")
  if currentRelayRegion.len > 0:
    gtkEditableSetText(relayRegionEntry, currentRelayRegion.cstring)
  gtkWidgetSetMarginBottom(relayRegionEntry, 16)
  gtkBoxAppend(content, relayRegionEntry)

  let storageBaseLabel = gtkLabelNew("Incoming buddy storage base path:")
  gtkBoxAppend(content, storageBaseLabel)

  let storageBaseEntry = gtkEntryNew()
  gtkEntrySetPlaceholderText(storageBaseEntry, "/home/user/BuddyDriveStorage")
  let currentStorageBase = configJson{"network"}{"storage_base_path"}.getStr("")
  if currentStorageBase.len > 0:
    gtkEditableSetText(storageBaseEntry, currentStorageBase.cstring)
  gtkWidgetSetMarginBottom(storageBaseEntry, 16)
  gtkBoxAppend(content, storageBaseEntry)

  let storageBaseHint = gtkLabelNew("Incoming buddy files are stored as <storage base>/<buddy id>/<folder name>/...")
  gtkLabelSetWrap(storageBaseHint, 1)
  gtkWidgetAddCssClass(storageBaseHint, "caption")
  gtkWidgetSetMarginBottom(storageBaseHint, 12)
  gtkBoxAppend(content, storageBaseHint)

  let bandwidthLabel = gtkLabelNew("Bandwidth limit (KB/s, 0 = unlimited):")
  gtkBoxAppend(content, bandwidthLabel)

  let bandwidthEntry = gtkEntryNew()
  let currentBandwidth = configJson{"network"}{"bandwidth_limit_kbps"}.getInt(0)
  gtkEditableSetText(bandwidthEntry, cstring($currentBandwidth))
  gtkWidgetSetMarginBottom(bandwidthEntry, 16)
  gtkBoxAppend(content, bandwidthEntry)
  
  let syncNoteLabel = gtkLabelNew("Per-buddy sync times are configured on each buddy instead of using a global sync window.")
  gtkLabelSetWrap(syncNoteLabel, 1)
  gtkWidgetSetMarginTop(syncNoteLabel, 12)
  gtkBoxAppend(content, syncNoteLabel)
  
  let data = cast[ptr SettingsData](allocShared0(sizeof(SettingsData)))
  data.dialog = dialog
  data.nameEntry = nameEntry
  data.portEntry = portEntry
  data.announceEntry = announceEntry
  data.relayUrlEntry = relayUrlEntry
  data.relayRegionEntry = relayRegionEntry
  data.storageBaseEntry = storageBaseEntry
  data.bandwidthEntry = bandwidthEntry
  
  discard gSignalConnect(cast[GObject](dialog), "response", cast[GCallback](onSettingsResponse), cast[pointer](data))
  
  gtkWidgetShow(dialog)

proc showSetupRecoveryDialog() =
  let dialog = gtkDialogNew()
  gtkWindowSetTitle(dialog, "Set Up Recovery")
  gtkWindowSetModal(dialog, 1)
  gtkWindowSetTransientFor(dialog, state.window)
  gtkWindowSetDefaultSize(dialog, 600, 500)
  
  discard gtkDialogAddButton(dialog, "Cancel", GTK_RESPONSE_CANCEL)
  discard gtkDialogAddButton(dialog, "Verify Words", -10)
  
  let content = gtkDialogGetContentArea(dialog)
  gtkWidgetSetMarginStart(content, 16)
  gtkWidgetSetMarginEnd(content, 16)
  gtkWidgetSetMarginTop(content, 16)
  gtkWidgetSetMarginBottom(content, 16)
  
  let (mnemonic, recoveryCfg) = setupRecovery()
  let words = mnemonic.splitWhitespace()
  
  let warningLabel = gtkLabelNew("Write down these 12 words and keep them safe.\nAnyone with these words can recover your data.")
  gtkWidgetAddCssClass(warningLabel, "warning")
  gtkWidgetSetMarginBottom(warningLabel, 16)
  gtkBoxAppend(content, warningLabel)
  
  let grid = gtkGridNew()
  gtkGridColumnSetSpacing(grid, 12)
  gtkGridRowSetSpacing(grid, 8)
  
  var wordEntries = cast[ptr UncheckedArray[pointer]](allocShared0(12 * sizeof(pointer)))
  
  for i in 0 ..< 12:
    let numLabel = gtkLabelNew(cstring($ (i + 1) & "."))
    gtkWidgetAddCssClass(numLabel, "dim-label")
    gtkGridAttach(grid, numLabel, cint(0), cint(i), 1, 1)
    
    let wordText = if i < words.len: words[i] else: ""
    let wordLabel = gtkLabelNew(cstring(wordText))
    gtkWidgetAddCssClass(wordLabel, "heading")
    gtkGridAttach(grid, wordLabel, cint(1), cint(i), 1, 1)
    
    let entry = gtkEntryNew()
    gtkEntrySetPlaceholderText(entry, "type word here")
    gtkGridAttach(grid, entry, cint(2), cint(i), 1, 1)
    wordEntries[i] = entry
  
  gtkBoxAppend(content, grid)
  
  let verifyLabel = gtkLabelNew("")
  gtkWidgetSetMarginTop(verifyLabel, 12)
  gtkBoxAppend(content, verifyLabel)
  
  let data = cast[ptr SetupRecoveryData](allocShared0(sizeof(SetupRecoveryData)))
  data.dialog = dialog
  data.wordEntries = wordEntries
  data.verifyLabel = verifyLabel
  data.expectedWords = words
  data.recoveryCfg = recoveryCfg
  
  proc onSetupRecoveryResponse(w: GtkWindow, responseId: cint, userData: pointer) {.cdecl.} =
    let d = cast[ptr SetupRecoveryData](userData)
    
    if responseId == -10:
      var correct = 0
      var checked = 0
      for i in 0 ..< 12:
        let typed = $gtkEditableGetText(d.wordEntries[i])
        if typed.len > 0:
          inc checked
          if i < d.expectedWords.len and typed.toLowerAscii() == d.expectedWords[i].toLowerAscii():
            inc correct
      
      if checked == 0:
        gtkLabelSetText(d.verifyLabel, "Please type some words to verify.")
      elif correct == checked:
        gtkLabelSetText(d.verifyLabel, "All words correct! Recovery is set up.")
        var cfg = currentConfig()
        cfg.recovery = d.recoveryCfg
        saveConfigAndRefresh(cfg)
        discard apiPost("/recovery/sync-config")
        discard refreshUI(nil)
      else:
        gtkLabelSetText(d.verifyLabel, cstring($correct & " of " & $checked & " words correct. Try again."))
    else:
      gtkWidgetSetVisible(d.dialog, 0)
      deallocShared(userData)
  
  discard gSignalConnect(cast[GObject](dialog), "response", cast[GCallback](onSetupRecoveryResponse), cast[pointer](data))
  
  gtkWidgetShow(dialog)

proc showRecoverDialog() =
  let dialog = gtkDialogNew()
  gtkWindowSetTitle(dialog, "Recover from Mnemonic")
  gtkWindowSetModal(dialog, 1)
  gtkWindowSetTransientFor(dialog, state.window)
  gtkWindowSetDefaultSize(dialog, 600, 500)
  
  discard gtkDialogAddButton(dialog, "Cancel", GTK_RESPONSE_CANCEL)
  discard gtkDialogAddButton(dialog, "Recover", GTK_RESPONSE_OK)
  
  let content = gtkDialogGetContentArea(dialog)
  gtkWidgetSetMarginStart(content, 16)
  gtkWidgetSetMarginEnd(content, 16)
  gtkWidgetSetMarginTop(content, 16)
  gtkWidgetSetMarginBottom(content, 16)
  
  let infoLabel = gtkLabelNew("Enter your 12-word recovery phrase:")
  gtkWidgetSetMarginBottom(infoLabel, 12)
  gtkBoxAppend(content, infoLabel)
  
  let grid = gtkGridNew()
  gtkGridColumnSetSpacing(grid, 12)
  gtkGridRowSetSpacing(grid, 8)
  
  var wordEntries = cast[ptr UncheckedArray[pointer]](allocShared0(12 * sizeof(pointer)))
  
  for i in 0 ..< 12:
    let numLabel = gtkLabelNew(cstring($ (i + 1) & "."))
    gtkWidgetAddCssClass(numLabel, "dim-label")
    gtkGridAttach(grid, numLabel, cint(0), cint(i), 1, 1)
    
    let entry = gtkEntryNew()
    gtkGridAttach(grid, entry, cint(1), cint(i), 1, 1)
    wordEntries[i] = entry
  
  gtkBoxAppend(content, grid)
  
  let data = cast[ptr RecoverData](allocShared0(sizeof(RecoverData)))
  data.dialog = dialog
  data.wordEntries = wordEntries
  
  proc onRecoverResponse(w: GtkWindow, responseId: cint, userData: pointer) {.cdecl.} =
    let d = cast[ptr RecoverData](userData)
    if responseId == GTK_RESPONSE_OK:
      var words: seq[string] = @[]
      for i in 0 ..< 12:
        let word = $gtkEditableGetText(d.wordEntries[i])
        words.add(word)
      
      let mnemonic = words.join(" ")
      let relayUrl = if buddyconfig.configExists() and currentConfig().apiBaseUrl.len > 0: currentConfig().apiBaseUrl else: DefaultKvApiUrl
      let relayRegion = if buddyconfig.configExists() and currentConfig().relayRegion.len > 0: currentConfig().relayRegion else: "eu"
      let recovered = waitFor attemptRecovery(mnemonic, relayUrl, relayRegion)

      if recovered.isSome():
        buddyconfig.saveConfig(recovered.get())
        discard refreshUI(nil)
      else:
        showMessageDialog("Recovery Failed", "Could not recover a config from the relay with the provided mnemonic.")
    else:
      gtkWidgetSetVisible(d.dialog, 0)
      deallocShared(userData)
  
  discard gSignalConnect(cast[GObject](dialog), "response", cast[GCallback](onRecoverResponse), cast[pointer](data))
  
  gtkWidgetShow(dialog)
  gtkWidgetGrabFocus(wordEntries[0])

proc initializeBuddyDrive() =
  if buddyconfig.configExists():
    showMessageDialog("Already Initialized", "BuddyDrive is already initialized on this machine.")
    return
  let name = generateBuddyName()
  let uuid = generateUuid()
  discard buddyconfig.initConfig(name, uuid)
  discard refreshUI(nil)
  showMessageDialog("BuddyDrive Initialized", "Identity: " & name & "\nBuddy ID: " & uuid)

proc showLogsDialog() =
  let logPath = buddyconfig.getLogPath()
  if not fileExists(logPath):
    showMessageDialog("Logs", "No log file found.")
    return
  showMessageDialog("Recent Logs", readFile(logPath))

proc showExportRecoveryDialog() =
  if not buddyconfig.configExists() or not currentConfig().recovery.enabled:
    showMessageDialog("Recovery", "Recovery is not enabled.")
    return
  let cfg = currentConfig()
  showMessageDialog(
    "Recovery Details",
    "Public key: " & cfg.recovery.publicKeyB58 & "\nMaster key: " & cfg.recovery.masterKey &
      "\n\nThe original 12-word phrase is not stored and cannot be shown again."
  )

proc showMyBuddyIdDialog() =
  if not buddyconfig.configExists():
    showMessageDialog("Pairing", "Initialize BuddyDrive first.")
    return
  let cfg = currentConfig()
  showMessageDialog(
    "Your Buddy ID",
    "Your Buddy ID: " & cfg.buddy.uuid &
      "\nYour Name: " & cfg.buddy.name &
      "\n\nTo pair, both of you open Pair with Buddy and enter each other's Buddy ID. " &
      "One of you presses Generate and sends the code; the other enters that same code."
  )

proc syncConfigNow() =
  if not buddyconfig.configExists() or not currentConfig().recovery.enabled:
    showMessageDialog("Sync Config", "Recovery is not enabled.")
    return
  let cfg = currentConfig()
  let relayUrl = if cfg.apiBaseUrl.len > 0: cfg.apiBaseUrl else: DefaultKvApiUrl
  let synced = waitFor syncConfigToRelay(cfg, relayUrl)
  if synced:
    setMessage("Config synced to relay.")
  else:
    setMessage("Failed to sync config to relay.")

proc startDaemonFromGui() =
  if not buddyconfig.configExists():
    showMessageDialog("Start Daemon", "Initialize BuddyDrive first.")
    return
  let cliPath = resolveCliBinary()
  if cliPath.len == 0:
    showMessageDialog("Start Daemon", "Could not find the buddydrive CLI binary in PATH or next to the GUI executable.")
    return
  let port = $DefaultControlPort
  state.daemonProcess = startProcess(
    cliPath,
    workingDir = buddyconfig.getConfigDir(),
    args = @["start", "--port", port],
    options = {poUsePath, poParentStreams, poDaemon}
  )
  setMessage("Starting daemon...")

proc stopDaemonFromGui() =
  if state.controlAvailable:
    discard apiPost("/daemon/stop")
    setMessage("Daemon stop requested.")
  else:
    setMessage("Daemon is not running.")

proc createMainWindow(app: GtkApplication): GtkWindow =
  let window = gtkApplicationWindowNew(app)
  gtkWindowSetTitle(window, "BuddyDrive")
  gtkWindowSetDefaultSize(window, 700, 600)
  
  let mainBox = gtkBoxNew(GTKORIENTATIONVERTICAL, 0)
  
  let headerBox = gtkBoxNew(GTKORIENTATIONHORIZONTAL, 12)
  gtkWidgetSetMarginStart(headerBox, 16)
  gtkWidgetSetMarginEnd(headerBox, 16)
  gtkWidgetSetMarginTop(headerBox, 16)
  gtkWidgetSetMarginBottom(headerBox, 8)
  
  let titleBox = gtkBoxNew(GTKORIENTATIONVERTICAL, 4)
  gtkWidgetSetHexpand(titleBox, 1)
  
  let titleLabel = gtkLabelNew("BuddyDrive")
  gtkWidgetAddCssClass(titleLabel, "title-1")
  gtkBoxAppend(titleBox, titleLabel)
  
  state.statusLabel = gtkLabelNew("Stopped")
  gtkWidgetAddCssClass(state.statusLabel, "dim-label")
  gtkBoxAppend(titleBox, state.statusLabel)
  
  gtkBoxAppend(headerBox, titleBox)
  
  let refreshBtn = gtkButtonNewWithLabel("Refresh")
  let startBtn = gtkButtonNewWithLabel("Start")
  let stopBtn = gtkButtonNewWithLabel("Stop")
  gtkBoxAppend(headerBox, refreshBtn)
  gtkBoxAppend(headerBox, startBtn)
  gtkBoxAppend(headerBox, stopBtn)
  
  gtkBoxAppend(mainBox, headerBox)
  
  let infoBox = gtkBoxNew(GTKORIENTATIONHORIZONTAL, 24)
  gtkWidgetSetMarginStart(infoBox, 16)
  gtkWidgetSetMarginEnd(infoBox, 16)
  gtkWidgetSetMarginBottom(infoBox, 12)
  
  state.buddyNameLabel = gtkLabelNew("Identity: --")
  gtkBoxAppend(infoBox, state.buddyNameLabel)
  
  state.uptimeLabel = gtkLabelNew("Uptime: 0h 0m")
  gtkBoxAppend(infoBox, state.uptimeLabel)
  
  gtkBoxAppend(mainBox, infoBox)

  state.messageLabel = gtkLabelNew("")
  gtkWidgetSetMarginStart(state.messageLabel, 16)
  gtkWidgetSetMarginEnd(state.messageLabel, 16)
  gtkWidgetSetMarginBottom(state.messageLabel, 12)
  gtkWidgetAddCssClass(state.messageLabel, "dim-label")
  gtkBoxAppend(mainBox, state.messageLabel)
  
  let foldersCard = createSectionCard("Folders")
  state.foldersList = gtkListBoxNew()
  gtkWidgetAddCssClass(state.foldersList, "boxed-list")
  gtkBoxAppend(foldersCard.content, state.foldersList)
  
  let folderBtnBox = gtkBoxNew(GTKORIENTATIONHORIZONTAL, 8)
  gtkWidgetSetMarginTop(folderBtnBox, 8)
  
  let syncAllBtn = gtkButtonNewWithLabel("Sync All")
  gtkWidgetAddCssClass(syncAllBtn, "suggested-action")
  gtkBoxAppend(folderBtnBox, syncAllBtn)
  
  let addFolderBtn = gtkButtonNewWithLabel("Add Folder...")
  gtkBoxAppend(folderBtnBox, addFolderBtn)
  
  gtkBoxAppend(foldersCard.content, folderBtnBox)
  
  gtkBoxAppend(mainBox, foldersCard.box)
  
  let buddiesCard = createSectionCard("Buddies")
  state.buddiesList = gtkListBoxNew()
  gtkWidgetAddCssClass(state.buddiesList, "boxed-list")
  gtkBoxAppend(buddiesCard.content, state.buddiesList)
  
  let pairBtn = gtkButtonNewWithLabel("Pair with Buddy...")
  gtkWidgetAddCssClass(pairBtn, "suggested-action")
  gtkWidgetSetMarginTop(pairBtn, 8)
  gtkBoxAppend(buddiesCard.content, pairBtn)

  let pairingInfoBtn = gtkButtonNewWithLabel("Show My Buddy ID...")
  gtkBoxAppend(buddiesCard.content, pairingInfoBtn)
  
  gtkBoxAppend(mainBox, buddiesCard.box)
  
  # Settings card
  let settingsCard = createSectionCard("Settings")
  
  let settingsBtn = gtkButtonNewWithLabel("Configure Settings...")
  gtkWidgetAddCssClass(settingsBtn, "suggested-action")
  gtkBoxAppend(settingsCard.content, settingsBtn)

  let initBtn = gtkButtonNewWithLabel("Initialize BuddyDrive...")
  gtkBoxAppend(settingsCard.content, initBtn)

  let logsBtn = gtkButtonNewWithLabel("View Logs...")
  gtkBoxAppend(settingsCard.content, logsBtn)

  let connectBtn = gtkButtonNewWithLabel("Manual Connect...")
  gtkBoxAppend(settingsCard.content, connectBtn)
  
  gtkBoxAppend(mainBox, settingsCard.box)
  
  let recoveryCard = createSectionCard("Recovery")
  
  state.recoveryStatusLabel = gtkLabelNew("Not set up")
  gtkWidgetAddCssClass(state.recoveryStatusLabel, "dim-label")
  gtkWidgetSetMarginBottom(state.recoveryStatusLabel, 8)
  gtkBoxAppend(recoveryCard.content, state.recoveryStatusLabel)
  
  let recoveryBtnBox = gtkBoxNew(GTKORIENTATIONHORIZONTAL, 8)
  
  let setupRecoveryBtn = gtkButtonNewWithLabel("Set Up Recovery...")
  gtkWidgetAddCssClass(setupRecoveryBtn, "suggested-action")
  gtkBoxAppend(recoveryBtnBox, setupRecoveryBtn)
  
  let recoverBtn = gtkButtonNewWithLabel("Recover from Mnemonic...")
  gtkBoxAppend(recoveryBtnBox, recoverBtn)

  let exportRecoveryBtn = gtkButtonNewWithLabel("Export Recovery Details...")
  gtkBoxAppend(recoveryBtnBox, exportRecoveryBtn)

  let syncConfigBtn = gtkButtonNewWithLabel("Sync Config Now")
  gtkBoxAppend(recoveryBtnBox, syncConfigBtn)
  
  gtkBoxAppend(recoveryCard.content, recoveryBtnBox)
  
  gtkBoxAppend(mainBox, recoveryCard.box)
  
  proc onRefreshClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    discard refreshUI(nil)
  
  discard gSignalConnect(cast[GObject](refreshBtn), "clicked", cast[GCallback](onRefreshClick), nil)

  proc onStartClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    startDaemonFromGui()

  discard gSignalConnect(cast[GObject](startBtn), "clicked", cast[GCallback](onStartClick), nil)

  proc onStopClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    stopDaemonFromGui()

  discard gSignalConnect(cast[GObject](stopBtn), "clicked", cast[GCallback](onStopClick), nil)
  
  proc onSyncAllClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    let foldersJson = apiGet("/folders")
    for folder in foldersJson{"folders"}.getElems():
      let name = folder{"name"}.getStr("")
      if name.len > 0:
        discard apiPost("/sync/" & name)
  
  discard gSignalConnect(cast[GObject](syncAllBtn), "clicked", cast[GCallback](onSyncAllClick), nil)
  
  proc onAddFolderClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    showAddFolderDialog()
  
  discard gSignalConnect(cast[GObject](addFolderBtn), "clicked", cast[GCallback](onAddFolderClick), nil)
  
  proc onPairClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    showPairBuddyDialog()
  
  discard gSignalConnect(cast[GObject](pairBtn), "clicked", cast[GCallback](onPairClick), nil)

  proc onPairingInfoClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    showMyBuddyIdDialog()

  discard gSignalConnect(cast[GObject](pairingInfoBtn), "clicked", cast[GCallback](onPairingInfoClick), nil)
  
  proc onSettingsClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    showSettingsDialog()
  
  discard gSignalConnect(cast[GObject](settingsBtn), "clicked", cast[GCallback](onSettingsClick), nil)

  proc onInitClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    initializeBuddyDrive()

  discard gSignalConnect(cast[GObject](initBtn), "clicked", cast[GCallback](onInitClick), nil)

  proc onLogsClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    showLogsDialog()

  discard gSignalConnect(cast[GObject](logsBtn), "clicked", cast[GCallback](onLogsClick), nil)

  proc onConnectClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    showMessageDialog("Manual Connect", "Manual direct connect is not implemented yet, matching the current CLI behavior.")

  discard gSignalConnect(cast[GObject](connectBtn), "clicked", cast[GCallback](onConnectClick), nil)
  
  proc onSetupRecoveryClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    showSetupRecoveryDialog()
  
  discard gSignalConnect(cast[GObject](setupRecoveryBtn), "clicked", cast[GCallback](onSetupRecoveryClick), nil)
  
  proc onRecoverClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    showRecoverDialog()
  
  discard gSignalConnect(cast[GObject](recoverBtn), "clicked", cast[GCallback](onRecoverClick), nil)

  proc onExportRecoveryClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    showExportRecoveryDialog()

  discard gSignalConnect(cast[GObject](exportRecoveryBtn), "clicked", cast[GCallback](onExportRecoveryClick), nil)

  proc onSyncConfigClick(btn: GtkButton, userData: pointer) {.cdecl.} =
    syncConfigNow()

  discard gSignalConnect(cast[GObject](syncConfigBtn), "clicked", cast[GCallback](onSyncConfigClick), nil)
  
  gtkWindowSetChild(window, mainBox)
  result = window

proc onActivate(app: GtkApplication, userData: pointer) {.cdecl.} =
  state.client = newHttpClient()
  state.window = createMainWindow(app)
  gtkWidgetShow(state.window)
  
  discard gTimeoutAdd(5000, refreshUI, nil)
  discard refreshUI(nil)

proc installIcon() =
  let iconDir = getHomeDir() / ".local/share/icons/hicolor"
  let sizes = ["48x48", "256x256"]
  
  let iconPath = currentSourcePath().parentDir().parentDir() / "icons" / "buddydrive.png"
  
  if fileExists(iconPath):
    for size in sizes:
      let destDir = iconDir / size / "apps"
      createDir(destDir)
      let dest = destDir / "buddydrive.png"
      if not fileExists(dest):
        copyFile(iconPath, dest)

proc main() =
  installIcon()
  gtkWindowSetDefaultIconName("buddydrive")
  
  app = gtkApplicationNew(AppId, GAPPLICATIONFLAGSNONE)
  discard gSignalConnect(cast[GObject](app), "activate", cast[GCallback](onActivate), nil)
  
  let status = gApplicationRun(cast[GApplication](app), 0, nil)
  quit(status)

when isMainModule:
  main()
