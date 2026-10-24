import std/[base64, syncio]
import libsodium/sodium
import libsodium/sodium_sizes

type
  CryptoError* = object of CatchableError

  EncryptedData* = object
    nonce*: string
    ciphertext*: string

  KeyPair* = object
    publicKey*: string
    secretKey*: string

const
  KeySize* = 32
  NonceSize* = 24
  MacSize* = 16
  HashSize* = 32

proc sodium_generichash_init(
  state: ptr char,
  key: ptr char,
  keylen: csize_t,
  outlen: csize_t,
): cint {.importc: "crypto_generichash_init", dynlib: "libsodium.so.23".}

proc sodium_generichash_update(
  state: ptr char,
  data: ptr char,
  datalen: culonglong,
): cint {.importc: "crypto_generichash_update", dynlib: "libsodium.so.23".}

proc sodium_generichash_final(
  state: ptr char,
  hash: ptr char,
  hashlen: csize_t,
): cint {.importc: "crypto_generichash_final", dynlib: "libsodium.so.23".}

proc sodium_secretbox_easy(
  c: ptr char,
  m: ptr char,
  mlen: culonglong,
  n: ptr char,
  k: ptr char,
): cint {.importc: "crypto_secretbox_easy", dynlib: "libsodium.so.23".}

proc sodium_secretbox_open_easy(
  dec: ptr char,
  c: ptr char,
  clen: culonglong,
  n: ptr char,
  k: ptr char,
): cint {.importc: "crypto_secretbox_open_easy", dynlib: "libsodium.so.23".}

proc initCrypto*(): bool =
  sodium.sodium_init() >= 0

proc generateKey*(): string =
  crypto_secretbox_keygen()

const PairingCodeAlphabet* = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

proc generatePairingCode*(): string =
  ## Eight characters from libsodium's CSPRNG, formatted XXXX-XXXX. The code
  ## is the only secret behind the discovery record and the relay rendezvous.
  for i in 0 .. 7:
    if i == 4:
      result.add('-')
    result.add(PairingCodeAlphabet[int(randombytes_uniform(uint32(PairingCodeAlphabet.len)))])

proc generateNonce*(): string =
  randombytes(crypto_secretbox_noncebytes())

proc generateKeyPair*(): KeyPair =
  let (pk, sk) = crypto_box_keypair()
  result.publicKey = pk
  result.secretKey = sk

proc secretboxEncrypt*(key: string, msg: string, nonce: string): string =
  if key.len != crypto_secretbox_keybytes():
    raise newException(CryptoError, "Invalid key size")
  if nonce.len != crypto_secretbox_noncebytes():
    raise newException(CryptoError, "Invalid nonce size")

  result = newString(msg.len + crypto_secretbox_macbytes())
  let rc = sodium_secretbox_easy(
    cast[ptr char](cstring(result)),
    cast[ptr char](cstring(msg)),
    culonglong(msg.len),
    cast[ptr char](cstring(nonce)),
    cast[ptr char](cstring(key))
  )
  if rc != 0:
    raise newException(CryptoError, "Encryption failed")

proc secretboxDecrypt*(key: string, ciphertext: string, nonce: string): string =
  if key.len != crypto_secretbox_keybytes():
    raise newException(CryptoError, "Invalid key size")
  if nonce.len != crypto_secretbox_noncebytes():
    raise newException(CryptoError, "Invalid nonce size")
  if ciphertext.len < crypto_secretbox_macbytes():
    raise newException(CryptoError, "Ciphertext too short")

  result = newString(ciphertext.len - crypto_secretbox_macbytes())
  let rc = sodium_secretbox_open_easy(
    cast[ptr char](cstring(result)),
    cast[ptr char](cstring(ciphertext)),
    culonglong(ciphertext.len),
    cast[ptr char](cstring(nonce)),
    cast[ptr char](cstring(key))
  )
  if rc != 0:
    raise newException(CryptoError, "Decryption failed")

proc encrypt*(data: string, key: string): EncryptedData =
  if key.len != crypto_secretbox_keybytes():
    raise newException(CryptoError, "Invalid key size: " & $key.len & " != " & $crypto_secretbox_keybytes())

  let nonce = generateNonce()
  result.nonce = nonce
  result.ciphertext = secretboxEncrypt(key, data, nonce)

proc decrypt*(encData: EncryptedData, key: string): string =
  if key.len != crypto_secretbox_keybytes():
    raise newException(CryptoError, "Invalid key size")

  result = secretboxDecrypt(key, encData.ciphertext, encData.nonce)

proc deriveKey*(password: string, salt: string): string =
  var saltBytes = newSeq[byte](salt.len)
  for i, c in salt:
    saltBytes[i] = byte(c)
  let derived = crypto_pwhash(password, saltBytes, crypto_secretbox_keybytes())
  result = newString(derived.len)
  for i, b in derived:
    result[i] = char(b)

proc generateSalt*(): string =
  randombytes(int(crypto_pwhash_saltbytes()))

proc hashPassword*(password: string): string =
  crypto_pwhash_str(password)

proc verifyPassword*(hash: string, password: string): bool =
  crypto_pwhash_str_verify(hash, password)

proc hashFileStream*(path: string): array[32, byte] =
  result = default(array[32, byte])
  let stateSize = crypto_generichash_statebytes()
  var stateStr = newString(stateSize)
  let rc0 = sodium_generichash_init(
    cast[ptr char](cstring(stateStr)),
    nil, csize_t(0), csize_t(HashSize)
  )
  if rc0 != 0:
    raise newException(CryptoError, "generichash_init failed")

  let f = open(path, fmRead)
  var buf = newString(64 * 1024)
  while true:
    let n = f.readChars(buf.toOpenArray(0, buf.len - 1))
    if n == 0: break
    let rc1 = sodium_generichash_update(
      cast[ptr char](cstring(stateStr)),
      cast[ptr char](cstring(buf)),
      culonglong(n)
    )
    if rc1 != 0:
      f.close()
      raise newException(CryptoError, "generichash_update failed")
  f.close()

  var hashStr = newString(HashSize)
  let rc2 = sodium_generichash_final(
    cast[ptr char](cstring(stateStr)),
    cast[ptr char](cstring(hashStr)),
    csize_t(HashSize)
  )
  if rc2 != 0:
    raise newException(CryptoError, "generichash_final failed")

  for i in 0 ..< HashSize:
    result[i] = byte(hashStr[i])

proc hashBytes*(data: openArray[byte]): array[32, byte] =
  result = default(array[32, byte])
  var s = newString(data.len)
  for i in 0 ..< data.len:
    s[i] = char(data[i])
  let hash = crypto_generichash(s, HashSize)
  for i in 0 ..< min(HashSize, hash.len):
    result[i] = byte(hash[i])

proc deriveFolderKey*(masterKey: string, folderId: string): string =
  let context = masterKey & "/folder/" & folderId
  let hash = crypto_generichash(context, KeySize)
  result = newString(hash.len)
  for i, b in hash:
    result[i] = char(b)

proc encryptPath*(plainPath: string, folderKey: string): string =
  if folderKey.len != crypto_secretbox_keybytes():
    raise newException(CryptoError, "Invalid folder key size")

  let nonceInput = folderKey & "/path/" & plainPath
  let nonceHash = crypto_generichash(nonceInput, crypto_secretbox_noncebytes())
  var nonce = newString(nonceHash.len)
  for i, b in nonceHash:
    nonce[i] = char(b)

  let ciphertext = secretboxEncrypt(folderKey, plainPath, nonce)
  encode(nonce & ciphertext)

proc decryptPath*(encrypted: string, folderKey: string): string =
  if folderKey.len != crypto_secretbox_keybytes():
    raise newException(CryptoError, "Invalid folder key size")

  let decoded = decode(encrypted)
  let nonceLen = crypto_secretbox_noncebytes()
  if decoded.len < nonceLen:
    raise newException(CryptoError, "Decoded path too short")

  let nonce = decoded[0 ..< nonceLen]
  let ciphertext = decoded[nonceLen ..^ 1]
  result = secretboxDecrypt(folderKey, ciphertext, nonce)

proc encryptChunk*(data: openArray[byte], folderKey: string): seq[byte] =
  if folderKey.len != crypto_secretbox_keybytes():
    raise newException(CryptoError, "Invalid folder key size")

  let nonce = generateNonce()
  var plainStr = newString(data.len)
  for i in 0 ..< data.len:
    plainStr[i] = char(data[i])

  let ciphertext = secretboxEncrypt(folderKey, plainStr, nonce)

  result = newSeq[byte](nonce.len + ciphertext.len)
  for i in 0 ..< nonce.len:
    result[i] = byte(nonce[i])
  for i in 0 ..< ciphertext.len:
    result[nonce.len + i] = byte(ciphertext[i])

proc decryptChunk*(data: openArray[byte], folderKey: string): seq[byte] =
  if folderKey.len != crypto_secretbox_keybytes():
    raise newException(CryptoError, "Invalid folder key size")

  let nonceLen = crypto_secretbox_noncebytes()
  if data.len < nonceLen + MacSize:
    raise newException(CryptoError, "Encrypted chunk too short")

  var nonce = newString(nonceLen)
  for i in 0 ..< nonceLen:
    nonce[i] = char(data[i])

  var ciphertext = newString(data.len - nonceLen)
  for i in 0 ..< ciphertext.len:
    ciphertext[i] = char(data[nonceLen + i])

  let plaintext = secretboxDecrypt(folderKey, ciphertext, nonce)

  result = newSeq[byte](plaintext.len)
  for i in 0 ..< plaintext.len:
    result[i] = byte(plaintext[i])
