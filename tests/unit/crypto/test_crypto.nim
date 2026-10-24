import std/unittest
import std/strutils
import std/os
import std/times
import ../../../src/buddydrive/crypto
import ../../../src/buddydrive/recovery

proc masterKeyToString(mk: array[32, byte]): string =
  result = newString(32)
  for i in 0..<32:
    result[i] = char(mk[i])

suite "Crypto initialization":
  test "initCrypto succeeds":
    check initCrypto()

suite "Pairing code":
  test "format is XXXX-XXXX from the unambiguous alphabet":
    for _ in 0 ..< 200:
      let code = generatePairingCode()
      check code.len == 9
      check code[4] == '-'
      for i, c in code:
        if i != 4:
          check c in PairingCodeAlphabet

  test "codes do not repeat":
    var seen: seq[string] = @[]
    for _ in 0 ..< 1000:
      let code = generatePairingCode()
      check code notin seen
      seen.add(code)

  test "every alphabet character is used":
    var counts: array[256, int]
    for _ in 0 ..< 2000:
      for c in generatePairingCode():
        inc counts[ord(c)]
    for c in PairingCodeAlphabet:
      check counts[ord(c)] > 0

suite "Key generation":
  test "generateKey returns 32 bytes":
    let key = generateKey()
    check key.len == KeySize

  test "generateKey produces different keys":
    let k1 = generateKey()
    let k2 = generateKey()
    check k1 != k2

  test "generateNonce returns 24 bytes":
    let nonce = generateNonce()
    check nonce.len == NonceSize

  test "generateNonce produces different nonces":
    let n1 = generateNonce()
    let n2 = generateNonce()
    check n1 != n2

suite "Key pair generation":
  test "generateKeyPair returns non-empty keys":
    let kp = generateKeyPair()
    check kp.publicKey.len > 0
    check kp.secretKey.len > 0

  test "generateKeyPair produces different keys each time":
    let kp1 = generateKeyPair()
    let kp2 = generateKeyPair()
    check kp1.publicKey != kp2.publicKey

suite "Config blob encryption (via recovery module)":
  test "encryptConfigBlob/decryptConfigBlob round-trip":
    let mk = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    let data = "hello world"
    let encrypted = encryptConfigBlob(data, mk)
    check encrypted != data
    let decrypted = decryptConfigBlob(encrypted, mk)
    check decrypted == data

  test "decryptConfigBlob with wrong key fails":
    let mk1 = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    let mk2 = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    let data = "secret message"
    let encrypted = encryptConfigBlob(data, mk1)
    try:
      discard decryptConfigBlob(encrypted, mk2)
      check false
    except CatchableError:
      check true
    except:
      check true

  test "encrypt empty string round-trip":
    let mk = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    let encrypted = encryptConfigBlob("", mk)
    let decrypted = decryptConfigBlob(encrypted, mk)
    check decrypted == ""

  test "encrypt large data round-trip":
    let mk = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    let data = "x".repeat(10000)
    let encrypted = encryptConfigBlob(data, mk)
    let decrypted = decryptConfigBlob(encrypted, mk)
    check decrypted == data

suite "Key derivation":
  test "deriveKey is deterministic":
    let salt = generateSalt()
    let k1 = deriveKey("password", salt)
    let k2 = deriveKey("password", salt)
    check k1 == k2

  test "deriveKey with different passwords produces different keys":
    let salt = generateSalt()
    let k1 = deriveKey("password1", salt)
    let k2 = deriveKey("password2", salt)
    check k1 != k2

  test "deriveKey with different salts produces different keys":
    let k1 = deriveKey("password", generateSalt())
    let k2 = deriveKey("password", generateSalt())
    check k1 != k2

  test "deriveKey returns 32 bytes":
    let key = deriveKey("password", generateSalt())
    check key.len == KeySize

suite "Password hashing":
  test "hashPassword/verifyPassword round-trip":
    let hash = hashPassword("mypassword")
    check verifyPassword(hash, "mypassword")

  test "verifyPassword rejects wrong password":
    let hash = hashPassword("mypassword")
    check not verifyPassword(hash, "wrongpassword")

  test "hashPassword produces different hashes":
    let h1 = hashPassword("same")
    let h2 = hashPassword("same")
    check h1 != h2

  test "verifyPassword still works with different hashes of same password":
    let h1 = hashPassword("same")
    let h2 = hashPassword("same")
    check verifyPassword(h1, "same")
    check verifyPassword(h2, "same")

suite "Salt generation":
  test "generateSalt returns non-empty string":
    let salt = generateSalt()
    check salt.len > 0

  test "generateSalt produces different salts":
    let s1 = generateSalt()
    let s2 = generateSalt()
    check s1 != s2

suite "Encrypt/Decrypt API edge cases":
  test "encrypt/decrypt round-trip":
    let key = generateKey()
    let data = "hello world"
    let enc = encrypt(data, key)
    let dec = decrypt(enc, key)
    check dec == data

  test "encrypt/decrypt empty string":
    let key = generateKey()
    let enc = encrypt("", key)
    let dec = decrypt(enc, key)
    check dec == ""

  test "encrypt/decrypt large data":
    let key = generateKey()
    let data = "x".repeat(10000)
    let enc = encrypt(data, key)
    let dec = decrypt(enc, key)
    check dec == data

  test "encrypt produces nonce of correct size":
    let key = generateKey()
    let enc = encrypt("data", key)
    check enc.nonce.len == NonceSize

  test "encrypt/decrypt with wrong key fails":
    let key1 = generateKey()
    let key2 = generateKey()
    let enc = encrypt("secret", key1)
    try:
      discard decrypt(enc, key2)
      check false
    except CatchableError:
      check true
    except:
      check true

  test "encryptPath/decryptPath round-trip":
    let key = generateKey()
    let plainPath = "photos/2024/vacation.jpg"
    let enc = encryptPath(plainPath, key)
    let dec = decryptPath(enc, key)
    check dec == plainPath

  test "encryptPath is deterministic":
    let key = generateKey()
    let plainPath = "documents/report.pdf"
    let enc1 = encryptPath(plainPath, key)
    let enc2 = encryptPath(plainPath, key)
    check enc1 == enc2

  test "encryptPath produces different ciphertext for different paths":
    let key = generateKey()
    let enc1 = encryptPath("photos/a.jpg", key)
    let enc2 = encryptPath("photos/b.jpg", key)
    check enc1 != enc2

  test "encrypt with invalid key size raises":
    expect CryptoError:
      discard encrypt("data", "shortkey")

  test "decrypt with invalid key size raises":
    let enc = EncryptedData(nonce: "x", ciphertext: "y")
    expect CryptoError:
      discard decrypt(enc, "shortkey")

suite "Streaming hash":
  test "hashFileStream returns 32 bytes":
    let tmpDir = getTempDir() / "buddydrive_test_hashfile_" & $getTime().toUnix()
    createDir(tmpDir)
    let tmpFile = tmpDir / "testfile.txt"
    writeFile(tmpFile, "hello world")
    let hash = hashFileStream(tmpFile)
    check hash.len == 32
    removeDir(tmpDir)

  test "hashFileStream is deterministic":
    let tmpDir = getTempDir() / "buddydrive_test_hashfile2_" & $getTime().toUnix()
    createDir(tmpDir)
    let tmpFile = tmpDir / "testfile.txt"
    writeFile(tmpFile, "same content")
    let h1 = hashFileStream(tmpFile)
    let h2 = hashFileStream(tmpFile)
    check h1 == h2
    removeDir(tmpDir)

  test "hashFileStream produces different hashes for different content":
    let tmpDir = getTempDir() / "buddydrive_test_hashfile3_" & $getTime().toUnix()
    createDir(tmpDir)
    let f1 = tmpDir / "a.txt"
    let f2 = tmpDir / "b.txt"
    writeFile(f1, "content A")
    writeFile(f2, "content B")
    check hashFileStream(f1) != hashFileStream(f2)
    removeDir(tmpDir)

  test "hashFileStream matches hashBytes for file contents":
    let tmpDir = getTempDir() / "buddydrive_test_hashfile4_" & $getTime().toUnix()
    createDir(tmpDir)
    let tmpFile = tmpDir / "blob.bin"
    let content = "abc123".repeat(4096)
    writeFile(tmpFile, content)
    let fileHash = hashFileStream(tmpFile)
    var bytes = newSeq[byte](content.len)
    for i, ch in content:
      bytes[i] = byte(ch)
    let memHash = hashBytes(bytes)
    check fileHash == memHash
    removeDir(tmpDir)

suite "Chunk encryption with random nonces":
  test "encryptChunk/decryptChunk round-trip":
    let key = generateKey()
    let data = @[byte(1), byte(2), byte(3), byte(4), byte(5)]
    let enc = encryptChunk(data, key)
    let dec = decryptChunk(enc, key)
    check dec == data

  test "encryptChunk prepends nonce (24 bytes + mac)":
    let key = generateKey()
    let data = @[byte(42)]
    let enc = encryptChunk(data, key)
    check enc.len == data.len + NonceSize + MacSize

  test "encryptChunk produces different ciphertext each time":
    let key = generateKey()
    let data = @[byte(1), byte(2), byte(3)]
    let enc1 = encryptChunk(data, key)
    let enc2 = encryptChunk(data, key)
    check enc1 != enc2

  test "decryptChunk with wrong key fails":
    let key1 = generateKey()
    let key2 = generateKey()
    let data = @[byte(1), byte(2), byte(3)]
    let enc = encryptChunk(data, key1)
    expect CatchableError:
      discard decryptChunk(enc, key2)

suite "Folder key derivation":
  test "deriveFolderKey is deterministic":
    let masterKey = generateKey()
    let folderId = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    let k1 = deriveFolderKey(masterKey, folderId)
    let k2 = deriveFolderKey(masterKey, folderId)
    check k1 == k2

  test "deriveFolderKey returns 32 bytes":
    let masterKey = generateKey()
    let folderId = "test-folder-id"
    let k = deriveFolderKey(masterKey, folderId)
    check k.len == KeySize

  test "deriveFolderKey with different folder IDs produces different keys":
    let masterKey = generateKey()
    let k1 = deriveFolderKey(masterKey, "folder-aaa")
    let k2 = deriveFolderKey(masterKey, "folder-bbb")
    check k1 != k2

  test "deriveFolderKey with different master keys produces different keys":
    let k1 = deriveFolderKey(generateKey(), "same-folder")
    let k2 = deriveFolderKey(generateKey(), "same-folder")
    check k1 != k2
