import std/unittest
import std/strutils
import ../../../src/buddydrive/recovery

proc hexToEntropy(hex: string): seq[byte] =
  doAssert hex.len mod 2 == 0
  result = newSeq[byte](hex.len div 2)
  for i in 0 ..< result.len:
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

suite "Mnemonic generation":
  test "generateMnemonic returns 12 words":
    let mnemonic = generateMnemonic()
    let words = mnemonic.splitWhitespace()
    check words.len == 12

  test "generated mnemonic validates":
    let mnemonic = generateMnemonic()
    check validateMnemonic(mnemonic)

  test "different calls produce different mnemonics":
    let m1 = generateMnemonic()
    let m2 = generateMnemonic()
    check m1 != m2

suite "Mnemonic validation":
  test "valid BIP39 test vector passes":
    check validateMnemonic("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")

  test "invalid words fail":
    check not validateMnemonic("notaword notaword notaword notaword notaword notaword notaword notaword notaword notaword notaword notaword")

  test "too few words fails":
    check not validateMnemonic("too few words")

  test "empty string fails":
    check not validateMnemonic("")

  test "13 words fails":
    check not validateMnemonic("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon extra")

  test "case insensitive validation":
    check validateMnemonic("Abandon Abandon Abandon Abandon Abandon Abandon Abandon Abandon Abandon Abandon Abandon About")

  test "wrong last word fails checksum":
    check not validateMnemonic("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon")

  test "single word swap fails checksum":
    let original = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    let modified = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ability about"
    check validateMnemonic(original)
    check not validateMnemonic(modified)

suite "BIP39 entropy encoding":
  test "official test vector: all-zero entropy":
    let entropy = hexToEntropy("00000000000000000000000000000000")
    let mnemonic = entropyToMnemonic(entropy)
    check mnemonic == "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

  test "official test vector: 7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f":
    let entropy = hexToEntropy("7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f")
    let mnemonic = entropyToMnemonic(entropy)
    check mnemonic == "legal winner thank year wave sausage worth useful legal winner thank yellow"

  test "official test vector: 80808080808080808080808080808080":
    let entropy = hexToEntropy("80808080808080808080808080808080")
    let mnemonic = entropyToMnemonic(entropy)
    check mnemonic == "letter advice cage absurd amount doctor acoustic avoid letter advice cage above"

  test "official test vector: ffffffffffffffffffffffffffffffff":
    let entropy = hexToEntropy("ffffffffffffffffffffffffffffffff")
    let mnemonic = entropyToMnemonic(entropy)
    check mnemonic == "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong"

suite "BIP39 entropy decoding":
  test "mnemonicToEntropy round-trip: all-zero entropy":
    let originalEntropy = hexToEntropy("00000000000000000000000000000000")
    let mnemonic = entropyToMnemonic(originalEntropy)
    let (recovered, valid) = mnemonicToEntropy(mnemonic)
    check valid
    check recovered == originalEntropy

  test "mnemonicToEntropy round-trip: random entropy":
    let mnemonic = generateMnemonic()
    let (entropy1, valid1) = mnemonicToEntropy(mnemonic)
    check valid1
    let mnemonic2 = entropyToMnemonic(entropy1)
    let (entropy2, valid2) = mnemonicToEntropy(mnemonic2)
    check valid2
    check entropy2 == entropy1

  test "mnemonicToEntropy with invalid checksum returns false":
    let badMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
    let (_, valid) = mnemonicToEntropy(badMnemonic)
    check not valid

  test "mnemonicToEntropy with wrong word count returns false":
    let (_, valid) = mnemonicToEntropy("abandon abandon abandon")
    check not valid

  test "mnemonicToEntropy with unknown word returns false":
    let (_, valid) = mnemonicToEntropy("notaword notaword notaword notaword notaword notaword notaword notaword notaword notaword notaword notaword")
    check not valid

suite "Key derivation":
  test "mnemonicToSeed is deterministic":
    let mnemonic = generateMnemonic()
    let seed1 = mnemonicToSeed(mnemonic)
    let seed2 = mnemonicToSeed(mnemonic)
    check seed1 == seed2

  test "deriveMasterKey is deterministic":
    let mnemonic = generateMnemonic()
    let seed = mnemonicToSeed(mnemonic)
    let mk1 = deriveMasterKey(seed)
    let mk2 = deriveMasterKey(seed)
    check mk1 == mk2

  test "different mnemonics produce different master keys":
    let m1 = generateMnemonic()
    let m2 = generateMnemonic()
    let mk1 = bytesToHex(deriveMasterKey(mnemonicToSeed(m1)))
    let mk2 = bytesToHex(deriveMasterKey(mnemonicToSeed(m2)))
    check mk1 != mk2

  test "master key hex is 64 chars":
    let mk = bytesToHex(deriveMasterKey(mnemonicToSeed(generateMnemonic())))
    check mk.len == 64

  test "invalid mnemonic raises on mnemonicToSeed":
    expect ValueError:
      discard mnemonicToSeed("invalid mnemonic words here")

  test "Argon2i seed derivation differs from BIP39 PBKDF2":
    let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    let seed = mnemonicToSeed(mnemonic)
    var seedHex = ""
    const hexChars = "0123456789abcdef"
    for b in seed:
      seedHex.add(hexChars[int(b shr 4)])
      seedHex.add(hexChars[int(b and 0x0f)])
    check seedHex[0..7] != "5eb11bb8"

suite "Hex round-trip":
  test "bytesToHex/hexToBytes round-trip":
    let key = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    let hex = bytesToHex(key)
    let restored = hexToBytes(hex)
    check key == restored

  test "hexToBytes rejects wrong length":
    expect ValueError:
      discard hexToBytes("short")

suite "Base58 encoding":
  test "base58Encode produces valid characters":
    let data = @[byte(1), 2, 3, 4, 5]
    let encoded = base58Encode(data)
    const validChars = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    for c in encoded:
      check c in validChars

  test "matches the standard Base58 test vectors":
    # From Bitcoin Core's base58_encode_decode.json.
    proc fromHex(hex: string): seq[byte] =
      for i in countup(0, hex.len - 2, 2):
        result.add(byte(parseHexInt(hex[i .. i + 1])))
    let vectors = [
      ("", ""),
      ("61", "2g"),
      ("626262", "a3gV"),
      ("636363", "aPEr"),
      ("73696d706c792061206c6f6e6720737472696e67", "2cFupjhnEsSn59qHXstmK2ffpLv2"),
      ("00eb15231dfceb60925886b67d065299925915aeb172c06647", "1NS17iag9jJgTHD1VXjvLCEnZuQ3rJDE9L"),
      ("516b6fcd0f", "ABnLTmg"),
      ("bf4f89001e670274dd", "3SEo3LWLoPntC"),
      ("572e4794", "3EFU7m"),
      ("ecac89cad93923c02321", "EJDM8drfXA6uyA"),
      ("10c8511e", "Rt5zm"),
      ("00000000000000000000", "1111111111"),
    ]
    for (hex, expected) in vectors:
      check base58Encode(fromHex(hex)) == expected

  test "every byte of a 32-byte hash counts":
    # The encoder used to fold the input into a 64-bit integer, so only the
    # last 8 bytes survived and keys differing earlier collided.
    var a = newSeq[byte](32)
    var b = newSeq[byte](32)
    for i in 0 ..< 32:
      a[i] = byte(i + 1)
      b[i] = byte(i + 1)
    b[0] = 0xff
    check base58Encode(a) != base58Encode(b)
    check base58Encode(a).len >= 43

  test "base58Encode of zero bytes starts with 1s":
    let data = @[byte(0), 0, 1]
    let encoded = base58Encode(data)
    check encoded.startsWith("1")

suite "Public key derivation":
  test "derivePublicKeyB58 produces non-empty string":
    let mk = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    let pk = derivePublicKeyB58(mk)
    check pk.len > 0

  test "derivePublicKeyB58 is deterministic":
    let mk = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    let pk1 = derivePublicKeyB58(mk)
    let pk2 = derivePublicKeyB58(mk)
    check pk1 == pk2

suite "Config encryption":
  test "encryptConfigBlob/decryptConfigBlob round-trip":
    let mk = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    let original = "[buddy]\nname = \"test-buddy\"\n"
    let encrypted = encryptConfigBlob(original, mk)
    check encrypted != original
    check encrypted.len > original.len
    let decrypted = decryptConfigBlob(encrypted, mk)
    check decrypted == original

  test "decrypt with wrong key fails":
    let mk1 = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    let mk2 = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    let original = "[buddy]\nname = \"test\"\n"
    let encrypted = encryptConfigBlob(original, mk1)
    try:
      discard decryptConfigBlob(encrypted, mk2)
      check false
    except CatchableError:
      check true
    except:
      check true

  test "decrypt too-short data fails":
    let mk = deriveMasterKey(mnemonicToSeed(generateMnemonic()))
    expect ValueError:
      discard decryptConfigBlob("short", mk)

suite "Recovery setup":
  test "setupRecovery returns valid recovery config":
    let (mnemonic, recovery) = setupRecovery()
    check recovery.enabled
    check recovery.masterKey.len == 64
    check recovery.publicKeyB58.len > 0

  test "verifyMnemonic with correct mnemonic":
    let (mnemonic, recovery) = setupRecovery()
    check verifyMnemonic(mnemonic, recovery.masterKey)

  test "verifyMnemonic with wrong mnemonic":
    let (_, recovery) = setupRecovery()
    let wrongMnemonic = generateMnemonic()
    check not verifyMnemonic(wrongMnemonic, recovery.masterKey)

  test "recoverFromMnemonic produces same keys":
    let (mnemonic, original) = setupRecovery()
    let recovered = recoverFromMnemonic(mnemonic)
    check recovered.masterKey == original.masterKey
    check recovered.publicKeyB58 == original.publicKeyB58

suite "Word helpers":
  test "suggestWords returns matching words":
    let suggestions = suggestWords("aband")
    check suggestions.len > 0
    check "abandon" in suggestions

  test "findWordIndex finds known word":
    let idx = findWordIndex("abandon")
    check idx >= 0
    check getWordForIndex(idx) == "abandon"

  test "findWordIndex returns -1 for unknown word":
    check findWordIndex("xyznotaword") == -1

  test "getWordForIndex raises for out of range":
    expect ValueError:
      discard getWordForIndex(-1)

  test "suggestWords is case insensitive":
    let s1 = suggestWords("Aband")
    let s2 = suggestWords("aband")
    check s1 == s2

  test "suggestWords limits to 5 results":
    let suggestions = suggestWords("a")
    check suggestions.len <= 5
