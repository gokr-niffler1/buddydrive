import std/unittest
import std/os except FileInfo
import std/times
import std/sequtils
import std/algorithm
import std/options
import ../../../src/buddydrive/types
import ../../../src/buddydrive/sync/scanner
import ../../../src/buddydrive/sync/transfer
import ../../../src/buddydrive/p2p/protocol
import ../../../src/buddydrive/crypto
import ../../testutils

useIsolatedDataDir("scanner")

suite "FileScanner construction":
  test "newFileScanner creates scanner with folder config":
    let folder = newFolderConfig("docs", "/tmp/test-docs")
    let scanner = newFileScanner(folder)
    check scanner.folder.name == "docs"
    check scanner.rootPath == "/tmp/test-docs"

suite "scanDirectory":
  test "empty directory returns empty seq":
    withTestDir("scanempty"):
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let files = scanner.scanDirectory()
      check files.len == 0

  test "single file detected":
    withTestDir("scansingle"):
      writeFile(testDir / "hello.txt", "hello")
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let files = scanner.scanDirectory()
      check files.len == 1
      check files[0].path == "hello.txt"

  test "temp files are ignored":
    withTestDir("scantemp"):
      writeFile(testDir / "good.txt", "keep me")
      writeFile(testDir / ("partial.dat" & TempSuffix), "ignore me")
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let files = scanner.scanDirectory()
      check files.len == 1
      check files[0].path == "good.txt"

  test "subdirectory files detected with relative paths":
    withTestDir("scansubdir"):
      createDir(testDir / "sub")
      writeFile(testDir / "sub" / "nested.txt", "nested")
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let files = scanner.scanDirectory()
      check files.len == 1
      check files[0].path == "sub/nested.txt"

  test "nonexistent directory returns empty":
    let folder = newFolderConfig("test", "/tmp/buddydrive_nonexistent_dir_12345")
    let scanner = newFileScanner(folder)
    let files = scanner.scanDirectory()
    check files.len == 0

  test "scanDirectory reuses cached hash when metadata is unchanged":
    withTestDir("scancache"):
      discard initCrypto()
      writeFile(testDir / "doc.txt", "alpha")
      let folder = newFolderConfig("test", testDir)
      let transfer = newFileTransfer(folder, newSyncProtocol())
      defer: transfer.close()
      let firstScan = transfer.scanner.scanDirectory()
      check firstScan.len == 1
      let originalHash = firstScan[0].hash
      let originalMtime = firstScan[0].mtime
      writeFile(testDir / "doc.txt", "bravo")
      setLastModificationTime(testDir / "doc.txt", fromUnix(originalMtime))
      let secondScan = transfer.scanner.scanDirectory()
      check secondScan.len == 1
      check secondScan[0].hash == originalHash

suite "scanFile uses crypto hash":
  test "scanFile computes blake2b content hash":
    withTestDir("scanhash"):
      discard initCrypto()
      writeFile(testDir / "doc.txt", "some content here")
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let info = scanner.scanFile(testDir / "doc.txt")
      check info.path == "doc.txt"
      check info.size > 0
      var zeroHash: array[32, byte]
      check info.hash != zeroHash

  test "same content produces same hash":
    withTestDir("scanhashsame"):
      discard initCrypto()
      writeFile(testDir / "a.txt", "identical content")
      writeFile(testDir / "b.txt", "identical content")
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let infoA = scanner.scanFile(testDir / "a.txt")
      let infoB = scanner.scanFile(testDir / "b.txt")
      check infoA.hash == infoB.hash

  test "different content produces different hash":
    withTestDir("scanhashdiff"):
      discard initCrypto()
      writeFile(testDir / "a.txt", "content A")
      writeFile(testDir / "b.txt", "content B is different")
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let infoA = scanner.scanFile(testDir / "a.txt")
      let infoB = scanner.scanFile(testDir / "b.txt")
      check infoA.hash != infoB.hash

suite "scanFile encrypted_path":
  test "encrypted folder with folderKey computes encrypted_path":
    withTestDir("scanencpath"):
      discard initCrypto()
      writeFile(testDir / "secret.txt", "secret stuff")
      var folder = newFolderConfig("test", testDir)
      folder.encrypted = true
      folder.folderKey = generateKey()
      let scanner = newFileScanner(folder)
      let info = scanner.scanFile(testDir / "secret.txt")
      check info.path == "secret.txt"
      check info.encryptedPath != "secret.txt"
      check info.encryptedPath.len > 0

  test "unencrypted folder uses plaintext as encrypted_path":
    withTestDir("scanunencpath"):
      discard initCrypto()
      writeFile(testDir / "shared.txt", "shared stuff")
      var folder = newFolderConfig("test", testDir)
      folder.encrypted = false
      let scanner = newFileScanner(folder)
      let info = scanner.scanFile(testDir / "shared.txt")
      check info.path == "shared.txt"
      check info.encryptedPath == "shared.txt"

  test "encrypted path is deterministic":
    withTestDir("scanencdet"):
      discard initCrypto()
      writeFile(testDir / "file.txt", "content")
      var folder = newFolderConfig("test", testDir)
      folder.encrypted = true
      folder.folderKey = generateKey()
      let scanner = newFileScanner(folder)
      let info1 = scanner.scanFile(testDir / "file.txt")
      let info2 = scanner.scanFile(testDir / "file.txt")
      check info1.encryptedPath == info2.encryptedPath

suite "scanChanges":
  test "added file detected":
    withTestDir("changeadd"):
      discard initCrypto()
      writeFile(testDir / "new.txt", "new file")
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let changes = scanner.scanChanges(@[])
      check changes.len == 1
      check changes[0].kind == fcAdded
      check changes[0].info.path == "new.txt"

  test "modified file detected by mtime/size then hash":
    withTestDir("changemodify"):
      discard initCrypto()
      writeFile(testDir / "doc.txt", "old content")
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let prevFiles = scanner.scanDirectory()
      writeFile(testDir / "doc.txt", "updated content that is longer than before")
      let changes = scanner.scanChanges(prevFiles)
      check changes.len == 1
      check changes[0].kind == fcModified

  test "deleted file detected":
    withTestDir("changedelete"):
      discard initCrypto()
      var prev: seq[FileInfo] = @[]
      var oldInfo: FileInfo
      oldInfo.path = "gone.txt"
      oldInfo.encryptedPath = "gone.txt"
      oldInfo.size = 10
      oldInfo.mtime = 100
      for i in 0..<32: oldInfo.hash[i] = byte(i)
      prev.add(oldInfo)
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let changes = scanner.scanChanges(prev)
      check changes.len == 1
      check changes[0].kind == fcDeleted

  test "moved file detected by content hash match":
    withTestDir("changemove"):
      discard initCrypto()
      writeFile(testDir / "original.txt", "same content")
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let prevFiles = scanner.scanDirectory()
      removeFile(testDir / "original.txt")
      createDir(testDir / "moved")
      writeFile(testDir / "moved" / "original.txt", "same content")
      let changes = scanner.scanChanges(prevFiles)
      let moved = changes.filterIt(it.kind == fcMoved)
      check moved.len == 1
      check moved[0].info.path == "moved/original.txt"
      check moved[0].oldPath == "original.txt"
      let deleted = changes.filterIt(it.kind == fcDeleted)
      check deleted.len == 0
      let added = changes.filterIt(it.kind == fcAdded)
      check added.len == 0

  test "renamed file does not appear as delete + add":
    withTestDir("changemovenodelta"):
      discard initCrypto()
      writeFile(testDir / "old_name.txt", "content here")
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let prevFiles = scanner.scanDirectory()
      removeFile(testDir / "old_name.txt")
      writeFile(testDir / "new_name.txt", "content here")
      let changes = scanner.scanChanges(prevFiles)
      let moved = changes.filterIt(it.kind == fcMoved)
      check moved.len == 1
      check moved[0].oldPath == "old_name.txt"
      check moved[0].info.path == "new_name.txt"

suite "Crash safety - atomic write":
  test "write chunks to temp then rename":
    withTestDir("atomicwrite"):
      let finalPath = testDir / "testfile.dat"
      let tmpPath = finalPath & TempSuffix
      let chunk1 = @[byte(1), 2, 3, 4]
      let chunk2 = @[byte(5), 6, 7, 8]
      check writeFileChunk(tmpPath, 0, chunk1)
      check writeFileChunk(tmpPath, 4, chunk2)
      check not fileExists(finalPath)
      check fileExists(tmpPath)
      flushAndClose(tmpPath)
      moveFile(tmpPath, finalPath)
      check fileExists(finalPath)
      check not fileExists(tmpPath)
      let content = readFile(finalPath)
      check content.len == 8
      check content[0] == char(1)
      check content[7] == char(8)

  test "cleanup removes temp files":
    withTestDir("cleanup"):
      createDir(testDir / "subdir")
      writeFile(testDir / "good.txt", "keep me")
      writeFile(testDir / "partial.dat" & TempSuffix, "delete me")
      writeFile(testDir / "subdir" / "nested.dat" & TempSuffix, "delete me too")
      writeFile(testDir / "subdir" / "real.txt", "keep me too")
      cleanupTempFiles(testDir)
      check fileExists(testDir / "good.txt")
      check fileExists(testDir / "subdir" / "real.txt")
      check not fileExists(testDir / "partial.dat" & TempSuffix)
      check not fileExists(testDir / "subdir" / "nested.dat" & TempSuffix)

  test "cleanup on nonexistent dir does not raise":
    cleanupTempFiles("/tmp/buddydrive_nonexistent_dir_12345")

suite "File chunk I/O":
  test "readFileChunk reads correct data":
    withTestDir("chunkread"):
      writeFile(testDir / "data.bin", "0123456789")
      let chunk = readFileChunk(testDir / "data.bin", 2, 3)
      check chunk.len == 3
      check chunk[0] == byte('2')
      check chunk[1] == byte('3')
      check chunk[2] == byte('4')

  test "readFileChunk with offset beyond file returns empty":
    withTestDir("chunkbeyond"):
      writeFile(testDir / "small.txt", "hi")
      let chunk = readFileChunk(testDir / "small.txt", 100, 10)
      check chunk.len == 0

  test "writeFileChunk and readFileChunk round-trip":
    withTestDir("chunkroundtrip"):
      let data = @[byte(10), 20, 30, 40, 50]
      check writeFileChunk(testDir / "chunk.dat", 0, data)
      let read = readFileChunk(testDir / "chunk.dat", 0, 5)
      check read == data

  test "scanFile populates file info":
    withTestDir("scanfile"):
      discard initCrypto()
      writeFile(testDir / "doc.txt", "some content here")
      let folder = newFolderConfig("test", testDir)
      let scanner = newFileScanner(folder)
      let info = scanner.scanFile(testDir / "doc.txt")
      check info.path == "doc.txt"
      check info.size > 0
      check info.mode > 0

when defined(posix):
  suite "scanFile metadata":
    test "scanFile captures symlink target":
      withTestDir("scansymlink"):
        discard initCrypto()
        createSymlink("target.txt", testDir / "link.txt")
        let folder = newFolderConfig("test", testDir)
        let scanner = newFileScanner(folder)
        let info = scanner.scanFile(testDir / "link.txt")
        check info.path == "link.txt"
        check info.symlinkTarget == "target.txt"
        check info.size == int64("target.txt".len)

    test "metadata-only mode change is detected":
      withTestDir("changemode"):
        discard initCrypto()
        let path = testDir / "script.sh"
        writeFile(path, "echo hi")
        setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
        let folder = newFolderConfig("test", testDir)
        let scanner = newFileScanner(folder)
        let prevFiles = scanner.scanDirectory()
        setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpOthersRead})
        let changes = scanner.scanChanges(prevFiles)
        check changes.len == 1
        check changes[0].kind == fcModified

suite "safeJoin":
  test "accepts a plain relative path":
    withTestDir("safejoin_ok"):
      check safeJoin(testDir, "a/b.txt") == some(testDir / "a/b.txt")

  test "rejects paths that leave the root":
    withTestDir("safejoin_escape"):
      check safeJoin(testDir, "../outside.txt").isNone
      check safeJoin(testDir, "a/../../outside.txt").isNone
      check safeJoin(testDir, "/etc/passwd").isNone
      check safeJoin(testDir, "").isNone
      check safeJoin(testDir, "a//b").isNone
      check safeJoin(testDir, "./a").isNone

  when defined(posix):
    test "rejects paths through a symlinked directory":
      withTestDir("safejoin_symlink"):
        createDir(testDir / "real")
        createSymlink(testDir / "real", testDir / "link")
        check safeJoin(testDir, "link/file.txt").isNone
        check safeJoin(testDir, "real/file.txt").isSome

suite "scanDirectoryStrict":
  test "a missing folder raises instead of looking empty":
    withTestDir("strict_missing"):
      let scanner = newFileScanner(newFolderConfig("t", testDir / "gone"))
      check scanner.scanDirectory().len == 0
      expect ScannerError:
        discard scanner.scanDirectoryStrict()

  test "a readable folder scans like scanDirectory":
    withTestDir("strict_ok"):
      writeFile(testDir / "a.txt", "a")
      createDir(testDir / "sub")
      writeFile(testDir / "sub" / "b.txt", "b")
      let scanner = newFileScanner(newFolderConfig("t", testDir))
      check scanner.scanDirectoryStrict().mapIt(it.path).sorted() == @["a.txt", "sub/b.txt"]

  when defined(posix):
    test "an unreadable file raises instead of being listed with its plain name":
      withTestDir("strict_locked_file"):
        let key = generateKey()
        var folder = newFolderConfig("t", testDir)
        folder.folderKey = key
        writeFile(testDir / "locked.txt", "secret")
        setFilePermissions(testDir / "locked.txt", {})
        defer: setFilePermissions(testDir / "locked.txt", {fpUserRead, fpUserWrite})
        let scanner = newFileScanner(folder)
        # The lenient scan lists it under its plaintext name even though the
        # folder is encrypted.
        let lenient = scanner.scanDirectory()
        check lenient.len == 1 and lenient[0].encryptedPath == "locked.txt"
        expect ScannerError:
          discard scanner.scanDirectoryStrict()

    test "an unreadable subfolder raises":
      withTestDir("strict_locked_dir"):
        createDir(testDir / "sub")
        writeFile(testDir / "sub" / "b.txt", "b")
        setFilePermissions(testDir / "sub", {})
        defer: setFilePermissions(testDir / "sub", {fpUserRead, fpUserWrite, fpUserExec})
        expect ScannerError:
          discard newFileScanner(newFolderConfig("t", testDir)).scanDirectoryStrict()
