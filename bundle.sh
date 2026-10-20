#!/bin/bash
# Assemble the SPM executable into a launchable macOS .app bundle.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Vision.app"
BIN_NAME="Vision"

echo "==> building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT" >/dev/null

BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/$BIN_NAME"
[ -f "$BIN" ] || { echo "missing binary: $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vision"

# Copy the logo assets into the bundle (app icon + in-app logo).
cp "$ROOT/assets/logo/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/assets/logo/logo.png"     "$APP/Contents/Resources/Logo.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Vision</string>
  <key>CFBundleDisplayName</key>     <string>Vision</string>
  <!-- The settings file is named after the identifier (AppIdentity.bundleIdentifier). The first launch brings
       over the settings, data folder and Keychain items of the build before the rename (LaunchMigration). -->
  <key>CFBundleIdentifier</key>      <string>com.503cm.vision.mac</string>
  <key>CFBundleVersion</key>         <string>26</string>
  <key>CFBundleShortVersionString</key> <string>0.16.8</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleExecutable</key>      <string>Vision</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <!-- Model servers on your own network (a DGX Spark, vLLM, Ollama, LM Studio)
       speak plain HTTP. NSAllowsLocalNetworking permits loopback, .local, and
       private-range addresses while ATS still governs the public internet. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key> <true/>
  </dict>
  <!-- Newer macOS asks before an app talks to other machines on your network.
       This is the wording of that prompt. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>Vision connects to the model servers you set up on your network — DGX Sparks, Ollama or LM Studio — and to the Spark Swapper that switches their models.</string>
  <!-- The agent reads and writes the project folder you open, and the
       integrated terminal runs your login shell there. -->
  <key>NSDesktopFolderUsageDescription</key>
  <string>Vision opens project folders you choose so the agent can read and edit them.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Vision opens project folders you choose so the agent can read and edit them.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Vision opens project folders you choose so the agent can read and edit them.</string>
  <!-- The computer-use tools (screenshot, ui_tree, keyboard) talk to the
       window server and System Events. These strings appear in the one-time
       macOS prompts; grants live in System Settings → Privacy & Security. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>Vision lets the agent inspect and control apps you approve — window titles, accessibility trees, and keyboard input — to debug what you are building.</string>
</dict>
</plist>
PLIST

# Sign. macOS ties Screen Recording, Accessibility and Automation grants to the app's designated
# requirement. An ad-hoc signature's requirement is the build's own hash, which every update changes,
# so grants silently stopped working after each update (up to 0.16.7). Releases are therefore signed
# with one long-lived certificate (SIGN_IDENTITY, imported by the release workflow), whose requirement
# — identifier + certificate root — stays the same across updates. Local builds without it stay ad-hoc.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "==> signing with: $SIGN_IDENTITY"
  codesign --force --deep --timestamp=none ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} --sign "$SIGN_IDENTITY" "$APP"
  DR="$(codesign -d -r- "$APP" 2>&1 | grep designated || true)"
  echo "    $DR"
  if [[ -n "${EXPECT_CERT_ROOT:-}" && "$DR" != *"certificate root = H\"$EXPECT_CERT_ROOT\""* ]]; then
    echo "error: the app is not signed by the release certificate (expected root $EXPECT_CERT_ROOT)." >&2
    echo "       A different certificate would break every user's macOS permissions again." >&2
    exit 1
  fi
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (unsigned — Gatekeeper may prompt on first launch)"
fi

# Build a distributable DMG (app + an Applications drag target).
DMG="$ROOT/build/Vision.dmg"
STAGE="$(mktemp -d)/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
echo "==> building DMG ($DMG)"
hdiutil create -volname "Vision" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo "==> done: $APP"
echo "==> done: $DMG"
