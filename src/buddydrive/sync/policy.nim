import std/[strutils, times]
import ../types

const
  LegacySyncToleranceMinutes* = 15
  DefaultSyncIntervalMinutes* = 30
  FirstContactSyncIntervalMinutes* = 5

proc parseClockMinutes*(value: string): int =
  let parts = value.strip().split(":")
  if parts.len != 2:
    return -1

  try:
    let hour = parseInt(parts[0])
    let minute = parseInt(parts[1])
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
      return -1
    hour * 60 + minute
  except ValueError:
    -1

proc parseSyncWindow*(value: string): tuple[ok: bool, startMinute, endMinute: int] =
  ## "HH:MM-HH:MM", which may wrap midnight. A single "HH:MM", the older
  ## sync_time form, is the half hour around that time.
  let text = value.strip()
  if text.len == 0:
    return (false, -1, -1)
  let parts = text.split("-")
  if parts.len == 1:
    let at = parseClockMinutes(parts[0])
    if at < 0:
      return (false, -1, -1)
    return (true, (at - LegacySyncToleranceMinutes + 1440) mod 1440, (at + LegacySyncToleranceMinutes) mod 1440)
  if parts.len != 2:
    return (false, -1, -1)
  let startMinute = parseClockMinutes(parts[0])
  let endMinute = parseClockMinutes(parts[1])
  if startMinute < 0 or endMinute < 0:
    return (false, -1, -1)
  (true, startMinute, endMinute)

proc isValidSyncWindow*(value: string): bool =
  value.strip().len == 0 or parseSyncWindow(value).ok

proc parseSyncInterval*(value: string): int =
  ## Minutes in "30m", "2h", "1h30m" or a bare number of minutes. 0 when
  ## empty, -1 when not understood.
  let text = value.strip().toLowerAscii().replace(" ", "")
  if text.len == 0:
    return 0
  var total = 0
  var n = 0
  var digits = 0
  for c in text:
    if c.isDigit():
      if digits == 5:
        return -1
      n = n * 10 + (ord(c) - ord('0'))
      inc digits
    elif c in {'h', 'm'} and digits > 0:
      total += (if c == 'h': n * 60 else: n)
      n = 0
      digits = 0
    else:
      return -1
  if digits > 0:
    if total > 0:
      return -1
    total = n
  if total <= 0:
    return -1
  total

proc isValidSyncInterval*(value: string): bool =
  parseSyncInterval(value) >= 0

proc syncWindowDescription*(syncWindow: string): string =
  if syncWindow.strip().len > 0:
    syncWindow.strip()
  else:
    "any time"

proc syncIntervalDescription*(syncInterval: string): string =
  let minutes = parseSyncInterval(syncInterval)
  if minutes <= 0:
    "every " & $FirstContactSyncIntervalMinutes & "m until first contact, then every " & $DefaultSyncIntervalMinutes & "m"
  else:
    "every " & syncInterval.strip()

proc isWithinSyncWindow*(syncWindow: string, currentTime: DateTime = now()): bool =
  let window = parseSyncWindow(syncWindow)
  if not window.ok:
    return true
  let currentMinute = currentTime.hour * 60 + currentTime.minute
  if window.startMinute <= window.endMinute:
    currentMinute >= window.startMinute and currentMinute <= window.endMinute
  else:
    currentMinute >= window.startMinute or currentMinute <= window.endMinute

proc nextSyncTime*(syncWindow: string, due: DateTime): DateTime =
  ## due, or the next opening of the window after it.
  if isWithinSyncWindow(syncWindow, due):
    return due
  let start = parseSyncWindow(syncWindow).startMinute
  result = dateTime(due.year, due.month, due.monthday, start div 60, start mod 60, 0, 0, due.timezone)
  if result < due:
    result = result + 1.days

proc effectiveSyncIntervalMinutes*(buddy: BuddyInfo, everConnected: bool): int =
  let minutes = parseSyncInterval(buddy.syncInterval)
  if minutes > 0:
    minutes
  elif everConnected:
    DefaultSyncIntervalMinutes
  else:
    FirstContactSyncIntervalMinutes

proc isSyncDue*(lastActivity: Time, intervalMinutes: int, currentTime: Time = getTime()): bool =
  ## lastActivity is the later of our last attempt and the last session,
  ## whoever dialed; the zero Time means never.
  if lastActivity == Time():
    return true
  currentTime - lastActivity >= initDuration(minutes = intervalMinutes)

proc shouldAttemptBuddySync*(buddy: BuddyInfo, currentTime: DateTime = now()): bool =
  isWithinSyncWindow(buddy.syncWindow, currentTime)
