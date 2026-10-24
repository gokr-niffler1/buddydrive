import std/unittest
import std/times
import ../../../src/buddydrive/types
import ../../../src/buddydrive/sync/policy

suite "parseClockMinutes":
  test "valid HH:MM":
    check parseClockMinutes("01:30") == 90
    check parseClockMinutes("00:00") == 0
    check parseClockMinutes("23:59") == 23 * 60 + 59
    check parseClockMinutes("12:00") == 720

  test "invalid format returns -1":
    check parseClockMinutes("invalid") == -1
    check parseClockMinutes("25:00") == -1
    check parseClockMinutes("12:60") == -1
    check parseClockMinutes("") == -1

suite "parseSyncWindow":
  test "a range":
    check parseSyncWindow("22:00-06:00") == (true, 22 * 60, 6 * 60)
    check parseSyncWindow(" 08:30 - 17:00 ") == (true, 8 * 60 + 30, 17 * 60)

  test "a single time is the half hour around it":
    check parseSyncWindow("03:00") == (true, 2 * 60 + 45, 3 * 60 + 15)
    check parseSyncWindow("00:05") == (true, 23 * 60 + 50, 20)

  test "invalid or empty":
    check not parseSyncWindow("").ok
    check not parseSyncWindow("bad").ok
    check not parseSyncWindow("22:00-").ok
    check not parseSyncWindow("22:00-25:00").ok
    check isValidSyncWindow("")
    check not isValidSyncWindow("22-06")

suite "parseSyncInterval":
  test "minutes and hours":
    check parseSyncInterval("30m") == 30
    check parseSyncInterval("2h") == 120
    check parseSyncInterval("1h30m") == 90
    check parseSyncInterval(" 2H ") == 120
    check parseSyncInterval("45") == 45

  test "empty means the default":
    check parseSyncInterval("") == 0
    check isValidSyncInterval("")

  test "not understood":
    check parseSyncInterval("0m") == -1
    check parseSyncInterval("h") == -1
    check parseSyncInterval("2d") == -1
    check parseSyncInterval("1h30") == -1
    check parseSyncInterval("-5m") == -1
    check parseSyncInterval("999999m") == -1
    check not isValidSyncInterval("soon")

suite "descriptions":
  test "window":
    check syncWindowDescription("") == "any time"
    check syncWindowDescription("22:00-06:00") == "22:00-06:00"

  test "interval":
    check syncIntervalDescription("2h") == "every 2h"
    check syncIntervalDescription("") == "every 5m until first contact, then every 30m"

suite "isWithinSyncWindow":
  test "always within when the window is empty":
    check isWithinSyncWindow("")

  test "a single time keeps its 15 minute tolerance":
    check isWithinSyncWindow("03:00", dateTime(2026, mApr, 10, 2, 45, 0, 0, local()))
    check isWithinSyncWindow("03:00", dateTime(2026, mApr, 10, 3, 15, 0, 0, local()))
    check not isWithinSyncWindow("03:00", dateTime(2026, mApr, 10, 3, 16, 0, 0, local()))
    check isWithinSyncWindow("00:05", dateTime(2026, mApr, 10, 23, 55, 0, 0, local()))
    check isWithinSyncWindow("23:55", dateTime(2026, mApr, 11, 0, 5, 0, 0, local()))

  test "a range during the day":
    check isWithinSyncWindow("08:00-17:00", dateTime(2026, mApr, 10, 8, 0, 0, 0, local()))
    check isWithinSyncWindow("08:00-17:00", dateTime(2026, mApr, 10, 12, 0, 0, 0, local()))
    check not isWithinSyncWindow("08:00-17:00", dateTime(2026, mApr, 10, 17, 1, 0, 0, local()))
    check not isWithinSyncWindow("08:00-17:00", dateTime(2026, mApr, 10, 7, 59, 0, 0, local()))

  test "a range across midnight":
    check isWithinSyncWindow("22:00-06:00", dateTime(2026, mApr, 10, 23, 0, 0, 0, local()))
    check isWithinSyncWindow("22:00-06:00", dateTime(2026, mApr, 10, 3, 0, 0, 0, local()))
    check not isWithinSyncWindow("22:00-06:00", dateTime(2026, mApr, 10, 12, 0, 0, 0, local()))

  test "an invalid window falls through to any time":
    check isWithinSyncWindow("bad")

suite "sync interval":
  test "empty interval: 5 minutes until first contact, then 30":
    var buddy: BuddyInfo
    check effectiveSyncIntervalMinutes(buddy, everConnected = false) == 5
    check effectiveSyncIntervalMinutes(buddy, everConnected = true) == 30

  test "a set interval is used either way":
    var buddy: BuddyInfo
    buddy.syncInterval = "2h"
    check effectiveSyncIntervalMinutes(buddy, everConnected = false) == 120
    check effectiveSyncIntervalMinutes(buddy, everConnected = true) == 120

  test "due once the interval has passed since the last activity":
    let last = initTime(1_800_000_000, 0)
    check isSyncDue(Time(), 30)
    check not isSyncDue(last, 30, last + initDuration(minutes = 29))
    check isSyncDue(last, 30, last + initDuration(minutes = 30))

suite "shouldAttemptBuddySync":
  test "empty window means any time":
    var buddy: BuddyInfo
    buddy.id = newBuddyId("buddy-1", "Alice")
    check shouldAttemptBuddySync(buddy, dateTime(2026, mApr, 10, 12, 0, 0, 0, local()))

  test "outside the window":
    var buddy: BuddyInfo
    buddy.id = newBuddyId("buddy-1", "Alice")
    buddy.syncWindow = "22:00-06:00"
    check shouldAttemptBuddySync(buddy, dateTime(2026, mApr, 10, 2, 0, 0, 0, local()))
    check not shouldAttemptBuddySync(buddy, dateTime(2026, mApr, 10, 12, 0, 0, 0, local()))

suite "nextSyncTime":
  test "due inside the window, or with no window, is kept":
    let due = dateTime(2026, mApr, 10, 23, 30, 0, 0, local())
    check nextSyncTime("", due) == due
    check nextSyncTime("22:00-06:00", due) == due

  test "due before the window opens waits for it the same day":
    let due = dateTime(2026, mApr, 10, 12, 10, 0, 0, local())
    check nextSyncTime("18:00-23:00", due) == dateTime(2026, mApr, 10, 18, 0, 0, 0, local())

  test "due after the window closed waits for the next day":
    let due = dateTime(2026, mApr, 10, 23, 17, 0, 0, local())
    check nextSyncTime("18:00-23:00", due) == dateTime(2026, mApr, 11, 18, 0, 0, 0, local())
