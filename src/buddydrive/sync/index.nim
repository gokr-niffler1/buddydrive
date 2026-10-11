import std/[options, times, strutils, sets, tables]
import db_connector/db_sqlite
import ../types
import ../config

export types

const SchemaVersion = 5

type
  IndexError* = object of CatchableError
  
  FileIndex* = ref object
    db*: DbConn
    folderName*: string

proc migrate(index: FileIndex) =
  var currentVersion = 0
  for row in index.db.rows(sql"PRAGMA user_version"):
    currentVersion = row[0].parseInt()
  
  if currentVersion < 1:
    let createOwner = """
      CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        folder TEXT NOT NULL,
        path TEXT NOT NULL,
        encrypted_path TEXT NOT NULL,
        size INTEGER NOT NULL,
        mtime INTEGER NOT NULL,
        hash BLOB NOT NULL,
        synced INTEGER DEFAULT 0,
        last_sync INTEGER DEFAULT 0,
        UNIQUE(folder, path)
      );
      CREATE INDEX IF NOT EXISTS idx_folder_path ON files(folder, path);
      CREATE INDEX IF NOT EXISTS idx_folder_synced ON files(folder, synced);
    """
    discard index.db.tryExec(sql(createOwner))
  
  if currentVersion < 2:
    discard index.db.tryExec(sql"CREATE INDEX IF NOT EXISTS idx_folder_content_hash ON files(folder, hash)")
    discard index.db.tryExec(sql"CREATE INDEX IF NOT EXISTS idx_folder_encrypted_path ON files(folder, encrypted_path)")

  if currentVersion < 3:
    discard index.db.tryExec(sql"ALTER TABLE files ADD COLUMN mode INTEGER NOT NULL DEFAULT 0")
    discard index.db.tryExec(sql"ALTER TABLE files ADD COLUMN symlink_target TEXT NOT NULL DEFAULT ''")
  
  if currentVersion < 4:
    discard index.db.tryExec(sql"""
      CREATE TABLE IF NOT EXISTS delete_confirmations (
        folder TEXT NOT NULL,
        path TEXT NOT NULL,
        buddy TEXT NOT NULL,
        UNIQUE(folder, path, buddy)
      )
    """)

  if currentVersion < 5:
    # The storage side keeps its own sidecar files now.
    discard index.db.tryExec(sql"DROP TABLE IF EXISTS storage_files")

  discard index.db.tryExec(sql("PRAGMA user_version = " & $SchemaVersion))

proc adoptLegacyRows(index: FileIndex, legacyKey: string) =
  ## Rows used to be kept under the folder's name and path, so renaming a
  ## folder lost them, its tombstones included. They move to the new key the
  ## first time it is used.
  if legacyKey.len == 0 or legacyKey == index.folderName:
    return
  if index.db.getValue(sql"SELECT 1 FROM files WHERE folder = ? LIMIT 1", index.folderName).len > 0:
    return
  index.db.exec(sql"BEGIN")
  try:
    index.db.exec(sql"UPDATE files SET folder = ? WHERE folder = ?", index.folderName, legacyKey)
    index.db.exec(sql"UPDATE OR IGNORE delete_confirmations SET folder = ? WHERE folder = ?",
      index.folderName, legacyKey)
    index.db.exec(sql"COMMIT")
  except DbError:
    discard index.db.tryExec(sql"ROLLBACK")
    raise

proc newIndex*(folderName: string, legacyKey = ""): FileIndex =
  ## folderName is the key the folder's rows are kept under. Rows still under
  ## legacyKey are taken over when there are none under folderName yet.
  result = FileIndex()
  result.folderName = folderName

  let dbPath = config.getIndexPath()
  config.ensureDataDir()

  let db = open(dbPath, "", "", "")
  result.db = db

  try:
    result.migrate()
    result.adoptLegacyRows(legacyKey)
  except CatchableError:
    db.close()
    raise

proc close*(index: FileIndex) =
  if index.db != nil:
    index.db.close()

proc hashToString*(hash: array[32, byte]): string =
  result = ""
  for b in hash:
    result.add(b.toHex(2).toLower())

proc stringToHash*(s: string): array[32, byte] =
  result = default(array[32, byte])
  for i in 0..<min(s.len div 2, 32):
    let hex = s[i*2..min(i*2+1, s.len-1)]
    try:
      result[i] = fromHex[byte](hex)
    except:
      discard

proc addFile*(index: FileIndex, info: types.FileInfo, synced: bool = false) =
  let hashStr = hashToString(info.hash)
  let query = """
    INSERT OR REPLACE INTO files (folder, path, encrypted_path, size, mtime, hash, mode, symlink_target, synced, last_sync)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  """
  let lastSync = if synced: getTime().toUnix() else: 0
  discard index.db.tryExec(sql(query), index.folderName, info.path, info.encryptedPath, info.size, info.mtime, hashStr, info.mode, info.symlinkTarget, if synced: 1 else: 0, lastSync)

proc cacheScannedFile*(index: FileIndex, info: types.FileInfo) =
  let hashStr = hashToString(info.hash)
  let query = """
    INSERT INTO files (folder, path, encrypted_path, size, mtime, hash, mode, symlink_target)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(folder, path) DO UPDATE SET
      encrypted_path = excluded.encrypted_path,
      size = excluded.size,
      mtime = excluded.mtime,
      hash = excluded.hash,
      mode = excluded.mode,
      symlink_target = excluded.symlink_target
  """
  discard index.db.tryExec(sql(query), index.folderName, info.path, info.encryptedPath, info.size, info.mtime, hashStr, info.mode, info.symlinkTarget)

proc removeFile*(index: FileIndex, path: string) =
  let query = "DELETE FROM files WHERE folder = ? AND path = ?"
  discard index.db.tryExec(sql(query), index.folderName, path)

proc getFile*(index: FileIndex, path: string): Option[types.FileInfo] =
  let query = "SELECT path, encrypted_path, size, mtime, hash, mode, symlink_target FROM files WHERE folder = ? AND path = ?"
  for row in index.db.rows(sql(query), index.folderName, path):
    var info: types.FileInfo
    info.path = row[0]
    info.encryptedPath = row[1]
    info.size = row[2].parseInt()
    info.mtime = row[3].parseInt()
    info.hash = stringToHash(row[4])
    info.mode = row[5].parseInt()
    info.symlinkTarget = row[6]
    return some(info)
  return none(types.FileInfo)

proc getFileByHash*(index: FileIndex, contentHash: array[32, byte]): Option[types.FileInfo] =
  let hashStr = hashToString(contentHash)
  let query = "SELECT path, encrypted_path, size, mtime, hash, mode, symlink_target FROM files WHERE folder = ? AND hash = ? LIMIT 1"
  for row in index.db.rows(sql(query), index.folderName, hashStr):
    var info: types.FileInfo
    info.path = row[0]
    info.encryptedPath = row[1]
    info.size = row[2].parseInt()
    info.mtime = row[3].parseInt()
    info.hash = stringToHash(row[4])
    info.mode = row[5].parseInt()
    info.symlinkTarget = row[6]
    return some(info)
  return none(types.FileInfo)

proc getFileByEncryptedPath*(index: FileIndex, encryptedPath: string): Option[types.FileInfo] =
  let query = "SELECT path, encrypted_path, size, mtime, hash, mode, symlink_target FROM files WHERE folder = ? AND encrypted_path = ? LIMIT 1"
  for row in index.db.rows(sql(query), index.folderName, encryptedPath):
    var info: types.FileInfo
    info.path = row[0]
    info.encryptedPath = row[1]
    info.size = row[2].parseInt()
    info.mtime = row[3].parseInt()
    info.hash = stringToHash(row[4])
    info.mode = row[5].parseInt()
    info.symlinkTarget = row[6]
    return some(info)
  return none(types.FileInfo)

proc getAllFiles*(index: FileIndex): seq[types.FileInfo] =
  result = @[]
  let query = "SELECT path, encrypted_path, size, mtime, hash, mode, symlink_target FROM files WHERE folder = ?"
  for row in index.db.rows(sql(query), index.folderName):
    var info: types.FileInfo
    info.path = row[0]
    info.encryptedPath = row[1]
    info.size = row[2].parseInt()
    info.mtime = row[3].parseInt()
    info.hash = stringToHash(row[4])
    info.mode = row[5].parseInt()
    info.symlinkTarget = row[6]
    result.add(info)

proc getUnsyncedFiles*(index: FileIndex): seq[types.FileInfo] =
  result = @[]
  let query = "SELECT path, encrypted_path, size, mtime, hash, mode, symlink_target FROM files WHERE folder = ? AND synced = 0"
  for row in index.db.rows(sql(query), index.folderName):
    var info: types.FileInfo
    info.path = row[0]
    info.encryptedPath = row[1]
    info.size = row[2].parseInt()
    info.mtime = row[3].parseInt()
    info.hash = stringToHash(row[4])
    info.mode = row[5].parseInt()
    info.symlinkTarget = row[6]
    result.add(info)

proc markSynced*(index: FileIndex, path: string) =
  let query = "UPDATE files SET synced = 1, last_sync = ? WHERE folder = ? AND path = ?"
  discard index.db.tryExec(sql(query), getTime().toUnix(), index.folderName, path)

proc markAllSynced*(index: FileIndex) =
  let query = "UPDATE files SET synced = 1, last_sync = ? WHERE folder = ?"
  discard index.db.tryExec(sql(query), getTime().toUnix(), index.folderName)

proc getSyncStatus*(index: FileIndex): tuple[total: int, synced: int, pending: int] =
  result = (0, 0, 0)
  
  let totalQuery = "SELECT COUNT(*) FROM files WHERE folder = ?"
  for row in index.db.rows(sql(totalQuery), index.folderName):
    result.total = row[0].parseInt()
  
  let syncedQuery = "SELECT COUNT(*) FROM files WHERE folder = ? AND synced = 1"
  for row in index.db.rows(sql(syncedQuery), index.folderName):
    result.synced = row[0].parseInt()
  
  result.pending = result.total - result.synced

proc confirmDelete*(index: FileIndex, path: string, buddyId: string) =
  ## Records that a buddy has been told a file is gone.
  discard index.db.tryExec(sql"INSERT OR IGNORE INTO delete_confirmations (folder, path, buddy) VALUES (?, ?, ?)",
    index.folderName, path, buddyId)

proc deleteConfirmations*(index: FileIndex): Table[string, HashSet[string]] =
  for row in index.db.rows(sql"SELECT path, buddy FROM delete_confirmations WHERE folder = ?", index.folderName):
    result.mgetOrPut(row[0], initHashSet[string]()).incl(row[1])

proc clearDeleteConfirmations*(index: FileIndex, path: string) =
  discard index.db.tryExec(sql"DELETE FROM delete_confirmations WHERE folder = ? AND path = ?", index.folderName, path)
