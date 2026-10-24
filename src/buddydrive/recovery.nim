import std/[os, strutils, sequtils]
import libsodium/sodium
import libsodium/sodium_sizes
import ./types

const BIP39_WORD_COUNT = 12
const ENTROPY_BYTES = 16

proc toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

proc bytesToString*(bytes: seq[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc binaryToHex*(data: string): string =
  result = newString(data.len * 2)
  const hexChars = "0123456789abcdef"
  for i, ch in data:
    let b = byte(ch)
    result[i * 2] = hexChars[int(b shr 4)]
    result[i * 2 + 1] = hexChars[int(b and 0x0f)]

proc hexToBinary*(hex: string): string =
  if hex.len mod 2 != 0:
    raise newException(ValueError, "Invalid hex string length")

  result = newString(hex.len div 2)
  for i in 0 ..< result.len:
    let hi = hex[i * 2]
    let lo = hex[i * 2 + 1]
    var b = 0
    if hi >= 'a' and hi <= 'f':
      b = (int(hi) - int('a') + 10) shl 4
    elif hi >= 'A' and hi <= 'F':
      b = (int(hi) - int('A') + 10) shl 4
    elif hi >= '0' and hi <= '9':
      b = (int(hi) - int('0')) shl 4
    else:
      raise newException(ValueError, "Invalid hex string")
    if lo >= 'a' and lo <= 'f':
      b = b or (int(lo) - int('a') + 10)
    elif lo >= 'A' and lo <= 'F':
      b = b or (int(lo) - int('A') + 10)
    elif lo >= '0' and lo <= '9':
      b = b or (int(lo) - int('0'))
    else:
      raise newException(ValueError, "Invalid hex string")
    result[i] = char(b)

proc loadBip39Wordlist(): seq[string] =
  let wordlistPath = currentSourcePath().parentDir().parentDir().parentDir() / "wordlists" / "bip39_english.txt"
  if not fileExists(wordlistPath):
    raise newException(IOError, "BIP39 wordlist not found: " & wordlistPath)
  result = readFile(wordlistPath).strip().splitLines()

let BIP39_WORDS = loadBip39Wordlist()

proc getWordForIndex*(index: int): string =
  if index < 0 or index >= BIP39_WORDS.len:
    raise newException(ValueError, "Invalid word index")
  result = BIP39_WORDS[index]

proc findWordIndex*(word: string): int =
  let lower = word.toLowerAscii()
  for i, w in BIP39_WORDS:
    if w == lower:
      return i
  return -1

proc suggestWords*(partial: string): seq[string] =
  let lower = partial.toLowerAscii()
  result = @[]
  for word in BIP39_WORDS:
    if word.startsWith(lower):
      result.add(word)
      if result.len >= 5:
        break

proc sodium_hash_sha256(
  out_hash: ptr char,
  data: ptr char,
  datalen: culonglong,
): cint {.importc: "crypto_hash_sha256", dynlib: "libsodium.so.23".}

proc sha256(data: string): seq[byte] =
  var hashBuf = newString(32)
  var dataBuf = data
  let rc = sodium_hash_sha256(
    cast[ptr char](addr hashBuf[0]),
    if dataBuf.len > 0: cast[ptr char](addr dataBuf[0]) else: nil,
    culonglong(dataBuf.len)
  )
  if rc != 0:
    raise newException(ValueError, "SHA-256 hash failed")
  result = newSeq[byte](32)
  for i in 0 ..< 32:
    result[i] = byte(hashBuf[i])

proc getBits(data: seq[byte], bitOffset: int, numBits: int): int =
  result = 0
  for i in 0 ..< numBits:
    let idx = bitOffset + i
    let byteIdx = idx div 8
    let bitPos = 7 - (idx mod 8)
    let bit = int((data[byteIdx] shr bitPos) and 1)
    result = (result shl 1) or bit

proc writeBits(data: var seq[byte], bitOffset: int, value: int, numBits: int) =
  for i in 0 ..< numBits:
    let bit = (value shr (numBits - 1 - i)) and 1
    if bit == 1:
      let idx = bitOffset + i
      let byteIdx = idx div 8
      let bitPos = 7 - (idx mod 8)
      data[byteIdx] = data[byteIdx] or byte(1 shl bitPos)

proc entropyToMnemonic*(entropy: seq[byte]): string =
  doAssert entropy.len == ENTROPY_BYTES, "BuddyDrive uses 128-bit (16-byte) entropy for 12-word mnemonics"
  let checksumBits = entropy.len * 8 div 32
  let hash = sha256(bytesToString(entropy))
  let checksumValue = int(hash[0]) shr (8 - checksumBits)
  let totalBits = entropy.len * 8 + checksumBits
  let totalBytes = (totalBits + 7) div 8
  var combined = newSeq[byte](totalBytes)
  for i in 0 ..< entropy.len:
    combined[i] = entropy[i]
  writeBits(combined, entropy.len * 8, checksumValue, checksumBits)
  var words: seq[string] = @[]
  let wordCount = totalBits div 11
  for i in 0 ..< wordCount:
    let idx = getBits(combined, i * 11, 11)
    words.add(BIP39_WORDS[idx])
  result = words.join(" ")

proc mnemonicToEntropy*(mnemonic: string): tuple[entropy: seq[byte], valid: bool] =
  let words = mnemonic.strip().splitWhitespace()
  if words.len != BIP39_WORD_COUNT:
    return (entropy: newSeq[byte](0), valid: false)
  var indices: seq[int] = @[]
  for word in words:
    let idx = findWordIndex(word)
    if idx < 0:
      return (entropy: newSeq[byte](0), valid: false)
    indices.add(idx)
  let checksumBits = words.len * 11 div 33
  let entropyBits = words.len * 11 - checksumBits
  let entropyBytes = entropyBits div 8
  let totalBits = words.len * 11
  let totalBytes = (totalBits + 7) div 8
  var combined = newSeq[byte](totalBytes)
  for i, idx in indices:
    writeBits(combined, i * 11, idx, 11)
  var entropy = newSeq[byte](entropyBytes)
  for i in 0 ..< entropyBytes:
    entropy[i] = combined[i]
  let checksum = getBits(combined, entropyBytes * 8, checksumBits)
  let hash = sha256(bytesToString(entropy))
  let expectedChecksum = int(hash[0]) shr (8 - checksumBits)
  result.entropy = entropy
  result.valid = checksum == expectedChecksum

proc generateMnemonic*(): string =
  let entropyStr = randombytes(ENTROPY_BYTES)
  var entropy = newSeq[byte](ENTROPY_BYTES)
  for i in 0 ..< ENTROPY_BYTES:
    entropy[i] = byte(entropyStr[i])
  result = entropyToMnemonic(entropy)

proc validateMnemonic*(mnemonic: string): bool =
  let words = mnemonic.strip().splitWhitespace()
  if words.len != BIP39_WORD_COUNT:
    return false
  for word in words:
    if word.toLowerAscii() notin BIP39_WORDS:
      return false
  let (_, valid) = mnemonicToEntropy(mnemonic)
  result = valid

proc mnemonicToSeed*(mnemonic: string): array[64, byte] =
  if not validateMnemonic(mnemonic):
    raise newException(ValueError, "Invalid mnemonic")
  
  let words = mnemonic.strip().splitWhitespace()
  let normalized = words.mapIt(it.toLowerAscii()).join(" ")
  
  let saltLen = int(crypto_pwhash_saltbytes())
  var salt = newSeq[byte](saltLen)
  let saltStr = "mnemonic"
  for i in 0 ..< min(saltStr.len, saltLen):
    salt[i] = byte(saltStr[i])
  for i in saltStr.len ..< saltLen:
    salt[i] = byte(i)
  
  let entropy = crypto_pwhash(
    normalized,
    salt,
    64,
    phaDefault,
    crypto_pwhash_opslimit_moderate(),
    crypto_pwhash_memlimit_moderate()
  )
  
  for i in 0 ..< min(64, entropy.len):
    result[i] = entropy[i]

proc deriveMasterKey*(seed: array[64, byte]): array[32, byte] =
  var combined = newString(64)
  for i in 0 ..< 64:
    combined[i] = char(seed[i])
  
  let hash = crypto_generichash(combined, 32)
  for i in 0 ..< 32:
    result[i] = byte(hash[i])

proc bytesToHex*(bytes: array[32, byte]): string =
  result = newString(64)
  const hexChars = "0123456789abcdef"
  for i, b in bytes:
    result[i * 2] = hexChars[int(b shr 4)]
    result[i * 2 + 1] = hexChars[int(b and 0x0f)]

proc hexToBytes*(hex: string): array[32, byte] =
  if hex.len != 64:
    raise newException(ValueError, "Invalid hex string length")
  for i in 0 ..< 32:
    let hi = hex[i * 2]
    let lo = hex[i * 2 + 1]
    var b = 0
    if hi >= 'a' and hi <= 'f':
      b = (int(hi) - int('a') + 10) shl 4
    elif hi >= 'A' and hi <= 'F':
      b = (int(hi) - int('A') + 10) shl 4
    else:
      b = (int(hi) - int('0')) shl 4
    if lo >= 'a' and lo <= 'f':
      b = b or (int(lo) - int('a') + 10)
    elif lo >= 'A' and lo <= 'F':
      b = b or (int(lo) - int('A') + 10)
    else:
      b = b or (int(lo) - int('0'))
    result[i] = byte(b)

proc base58Encode*(data: seq[byte]): string =
  ## Bitcoin-alphabet Base58 of the whole input. Each leading zero byte
  ## becomes a "1"; the rest is converted as one big number.
  const Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  var zeros = 0
  while zeros < data.len and data[zeros] == 0:
    inc zeros

  var digits: seq[int] = @[]
  for i in zeros ..< data.len:
    var carry = int(data[i])
    for j in 0 ..< digits.len:
      carry += digits[j] shl 8
      digits[j] = carry mod 58
      carry = carry div 58
    while carry > 0:
      digits.add(carry mod 58)
      carry = carry div 58

  for _ in 0 ..< zeros:
    result.add('1')
  for j in countdown(digits.high, 0):
    result.add(Alphabet[digits[j]])

proc derivePublicKeyB58*(masterKey: array[32, byte]): string =
  var masterKeyStr = newString(32)
  for i in 0 ..< 32:
    masterKeyStr[i] = char(masterKey[i])
  let hash = crypto_generichash(masterKeyStr, 32)
  var hashBytes = newSeq[byte](hash.len)
  for i in 0 ..< hash.len:
    hashBytes[i] = byte(hash[i])
  base58Encode(hashBytes)

proc encryptConfigBlob*(config: string, masterKey: array[32, byte]): string =
  var masterKeyStr = newString(32)
  for i in 0 ..< 32:
    masterKeyStr[i] = char(masterKey[i])
  result = crypto_secretbox_easy(masterKeyStr, config)

proc decryptConfigBlob*(encrypted: string, masterKey: array[32, byte]): string =
  var masterKeyStr = newString(32)
  for i in 0 ..< 32:
    masterKeyStr[i] = char(masterKey[i])
  
  if encrypted.len < int(crypto_secretbox_noncebytes()) + int(crypto_secretbox_macbytes()):
    raise newException(ValueError, "Encrypted data too short")
  
  result = crypto_secretbox_open_easy(masterKeyStr, encrypted)

proc deriveSigningKeyPair*(masterKey: array[32, byte]): tuple[publicKey: string, secretKey: string] =
  var seed = newString(32)
  for i in 0 ..< 32:
    seed[i] = char(masterKey[i])
  result = crypto_sign_seed_keypair(seed)

proc deriveVerifyKeyHex*(masterKey: array[32, byte]): string =
  let (publicKey, _) = deriveSigningKeyPair(masterKey)
  binaryToHex(publicKey)

proc setupRecovery*(): tuple[mnemonic: string, recovery: RecoveryConfig] =
  result.mnemonic = generateMnemonic()
  let seed = mnemonicToSeed(result.mnemonic)
  let masterKey = deriveMasterKey(seed)
  
  result.recovery.enabled = true
  result.recovery.publicKeyB58 = derivePublicKeyB58(masterKey)
  result.recovery.masterKey = bytesToHex(masterKey)

proc recoverFromMnemonic*(mnemonic: string): RecoveryConfig =
  let seed = mnemonicToSeed(mnemonic)
  let masterKey = deriveMasterKey(seed)
  
  result.enabled = true
  result.publicKeyB58 = derivePublicKeyB58(masterKey)
  result.masterKey = bytesToHex(masterKey)

proc verifyMnemonic*(mnemonic: string, storedMasterKey: string): bool =
  let seed = mnemonicToSeed(mnemonic)
  let masterKey = deriveMasterKey(seed)
  let derivedHex = bytesToHex(masterKey)
  result = derivedHex == storedMasterKey
