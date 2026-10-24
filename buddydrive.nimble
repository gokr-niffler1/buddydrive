import os, strutils

version = "0.1.0"
author = "Göran Krampe"
description = "P2P encrypted folder sync with buddies"
license = "MIT"
srcDir = "src"
binDir = "bin"
bin = @["buddydrive"]

requires "nim >= 2.2.8"              # Language version
requires "libp2p >= 1.15"            # P2P networking, direct transport
requires "libsodium >= 0.7"          # Encryption (XChaCha20-Poly1305), key derivation
requires "parsetoml"                  # TOML config parsing (~/.buddydrive/config.toml)
requires "results >= 0.5.1"          # Result type for error handling
requires "stew"                       # Utility types used by libp2p
requires "uuids"                      # UUID generation for buddy/folder IDs
requires "db_connector"              # SQLite (bundled with Nim 2.2.8+) for state/index DBs
requires "nat_traversal"             # NAT hole punching
requires "curly"                      # HTTP client (relay KV API, config sync)
requires "https://github.com/gokr/lz4wrapper" # LZ4 compression (used by libp2p)
requires "https://github.com/status-im/nim-zlib#daa8723" # zlib for libp2p; pinned because libp2p declares underspecified version

task test, "Run all tests (automatic discovery via testament)":
  # No "|| true" here: a failing suite must fail the task.
  exec """
    echo "Running BuddyDrive test suite..."
    echo "=== Unit tests ==="
    testament pattern "tests/unit/*/*.nim"
    echo "=== Integration tests ==="
    testament pattern "tests/integration/*.nim"
  """

task testUnit, "Run unit tests":
  exec "testament pattern \"tests/unit/*/*.nim\""

task testTypes, "Run types tests":
  exec "testament pattern \"tests/unit/types/*.nim\""

task testRecovery, "Run recovery tests":
  exec "testament pattern \"tests/unit/recovery/*.nim\""

task testCrypto, "Run crypto tests":
  exec "testament pattern \"tests/unit/crypto/*.nim\""

task testConfig, "Run config tests":
  exec "testament pattern \"tests/unit/config/*.nim\""

task testPolicy, "Run sync policy tests":
  exec "testament pattern \"tests/unit/policy/*.nim\""

task testAddrs, "Run address selection tests":
  exec "testament pattern \"tests/unit/addrs/*.nim\""

task testScanner, "Run scanner tests":
  exec "testament pattern \"tests/unit/scanner/*.nim\""

task testIndex, "Run file index tests":
  exec "testament pattern \"tests/unit/index/*.nim\""

task testMessages, "Run protocol message tests":
  exec "testament pattern \"tests/unit/messages/*.nim\""

task testConfigSync, "Run config sync tests":
  exec "testament pattern \"tests/unit/config_sync/*.nim\""

task testControl, "Run control API tests":
  exec "testament pattern \"tests/unit/control/*.nim\""

task testControlWeb, "Run control web helper tests":
  exec "testament pattern \"tests/unit/control_web/*.nim\""

task testRawRelay, "Run raw relay helper tests":
  exec "testament pattern \"tests/unit/rawrelay/*.nim\""

task testPairing, "Run pairing unit tests":
  exec "testament pattern \"tests/unit/pairing/*.nim\""

task testTransfer, "Run transfer crash-safety tests":
  exec "testament pattern \"tests/unit/scanner/test_transfer_crash_safety.nim\""

task testCli, "Run CLI integration tests":
  exec "testament pattern \"tests/integration/test_cli_flows.nim\""

task testIntegration, "Run integration tests":
  exec "testament pattern \"tests/integration/*.nim\""

task build, "Build release CLI":
  exec "nim c -d:release src/buddydrive.nim"

task gui, "Build GUI (debug)":
  exec "nim c -d:gtk4 -o:bin/buddydrive-gui src/buddydrive_gui.nim"

task gui_release, "Build GUI (release)":
  exec "nim c -d:release -d:gtk4 -o:bin/buddydrive-gui src/buddydrive_gui.nim"

task icons, "Install icons to ~/.local/share/icons":
  let home = getHomeDir()
  let iconsBase = home / ".local/share/icons/hicolor"
  let cwd = getCurrentDir()
  
  echo "Installing icons..."
  
  for size in ["48", "128", "256", "512"]:
    let srcDir = cwd / "icons/hicolor" / (size & "x" & size) / "apps"
    let destDir = iconsBase / (size & "x" & size) / "apps"
    exec "mkdir -p " & destDir.quoteShell()
    if fileExists(srcDir / "buddydrive.png"):
      exec "cp " & (srcDir / "buddydrive.png").quoteShell() & " " & (destDir / "buddydrive.png").quoteShell()
      echo "  Installed " & size & "x" & size & " icon"
  
  # Create index.theme if not exists
  let indexTheme = iconsBase / "index.theme"
  if not fileExists(indexTheme):
    let content = """[Icon Theme]
Name=Hicolor
Comment=Freedesktop.org compatibility icon theme
Directories=48x48/apps,128x128/apps,256x256/apps,512x512/apps

[48x48/apps]
Size=48
Context=Applications
Type=Fixed

[128x128/apps]
Size=128
Context=Applications
Type=Fixed

[256x256/apps]
Size=256
Context=Applications
Type=Fixed

[512x512/apps]
Size=512
Context=Applications
Type=Fixed
"""
    writeFile(indexTheme, content)
    echo "Created icon theme index"
  
  exec "gtk4-update-icon-cache -f " & iconsBase.quoteShell() & " 2>/dev/null || true"

task install_gui, "Install GUI with desktop integration":
  let home = getHomeDir()
  let desktopDir = home / ".local/share/applications"
  let binDir = home / ".local/bin"
  let iconsBase = home / ".local/share/icons/hicolor"
  let cwd = getCurrentDir()
  
  echo "Creating directories..."
  exec "mkdir -p " & desktopDir.quoteShell()
  exec "mkdir -p " & binDir.quoteShell()
  
  let guiSource = cwd / "bin" / "buddydrive-gui"
  let guiDest = binDir / "buddydrive-gui"
  if not fileExists(guiSource):
    echo "Error: buddydrive-gui binary not found. Run 'nimble gui_release' first."
    system.quit(1)
  echo "Installing buddydrive-gui binary to " & guiDest & "..."
  exec "cp " & guiSource.quoteShell() & " " & guiDest.quoteShell()
  exec "chmod +x " & guiDest.quoteShell()
  
  echo "Installing buddydrive.desktop..."
  exec "cp " & (cwd / "buddydrive.desktop").quoteShell() & " " & (desktopDir / "buddydrive.desktop").quoteShell()
  exec "sed -i 's|Exec=.*|Exec=" & guiDest & "|g' " & (desktopDir / "buddydrive.desktop").quoteShell()
  exec "sed -i 's|StartupWMClass=.*|StartupWMClass=org.buddydrive.app|g' " & (desktopDir / "buddydrive.desktop").quoteShell()
  
  echo "Installing icons..."
  for size in ["48", "128", "256", "512"]:
    let srcDir = cwd / "icons/hicolor" / (size & "x" & size) / "apps"
    let destDir = iconsBase / (size & "x" & size) / "apps"
    exec "mkdir -p " & destDir.quoteShell()
    if fileExists(srcDir / "buddydrive.png"):
      exec "cp " & (srcDir / "buddydrive.png").quoteShell() & " " & (destDir / "buddydrive.png").quoteShell()
  
  # Create index.theme if not exists
  let indexTheme = iconsBase / "index.theme"
  if not fileExists(indexTheme):
    let content = """[Icon Theme]
Name=Hicolor
Comment=Freedesktop.org compatibility icon theme
Directories=48x48/apps,128x128/apps,256x256/apps,512x512/apps

[48x48/apps]
Size=48
Context=Applications
Type=Fixed

[128x128/apps]
Size=128
Context=Applications
Type=Fixed

[256x256/apps]
Size=256
Context=Applications
Type=Fixed

[512x512/apps]
Size=512
Context=Applications
Type=Fixed
"""
    writeFile(indexTheme, content)
    echo "Created icon theme index"
  
  exec "gtk4-update-icon-cache -f " & iconsBase.quoteShell() & " 2>/dev/null || true"
  
  exec "update-desktop-database " & desktopDir.quoteShell() & " 2>/dev/null || true"
  
  echo ""
  echo "BuddyDrive GUI installed!"
  echo "You may need to log out/in for icons to appear in the dock."
