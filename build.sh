#!/bin/bash
# Builds Vigil.app into ./build (SwiftPM; works with just the Command Line Tools, no Xcode needed).
#
#   ./build.sh                 build + ad-hoc sign -> ./build/Vigil.app
#   ./build.sh --install       ...and copy it to /Applications (quits a running Vigil first, so it restores sleep)
#   ./build.sh --test          ...also run the unit tests first
#   SIGN_IDENTITY="Apple Development: you (TEAMID)" ./build.sh    sign with a real identity instead of ad-hoc
#
# Why the staging dir: ~/Desktop and ~/Documents may be iCloud-synced, and iCloud stamps bundles with
# com.apple.FinderInfo / fileprovider xattrs, which makes codesign fail ("detritus not allowed").
# So everything is built and signed under ~/Library/Caches and only the finished, signed app is copied here.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
VERSION="${VERSION:-1.0.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
CACHE="${VIGIL_CACHE:-$HOME/Library/Caches/Vigil}"
SCRATCH="$CACHE/swiftbuild"
STAGE="$CACHE/stage"
APP_STAGE="$STAGE/Vigil.app"
OUT="$ROOT/build"

INSTALL=0
RUN_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --test) RUN_TESTS=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Command Line Tools ship without Xcode's framework/lib directories, so ld prints three harmless
# "search path ... not found" notices for every link. They come from the toolchain, not from this
# project. We hide exactly those lines (and say how many) so real warnings are never lost in the noise.
toolchain_notice='ld: warning: search path .* not found'
filter_toolchain_notices() {
  local log; log="$(mktemp)"
  cat > "$log"
  local hidden; hidden=$(grep -Ec "$toolchain_notice" "$log" || true)
  grep -Ev "$toolchain_notice" "$log" || true
  if [ "$hidden" -gt 0 ]; then echo "(hid $hidden 'ld: search path not found' notices from the Command Line Tools; install Xcode to remove them)"; fi
  rm -f "$log"
}

mkdir -p "$CACHE"

if [ "$RUN_TESTS" = 1 ]; then
  step "Unit tests"
  PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
  EXTRA=()
  [ -d "$PLUGINS" ] && EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")   # Swift Testing macros in a CLT-only setup
  swift test --scratch-path "$SCRATCH" ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 | filter_toolchain_notices | grep -E "✘|error|Test run with|warning" || true
  swift test --scratch-path "$SCRATCH" ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null 2>&1 || { echo "tests FAILED" >&2; exit 1; }
fi

step "Compiling (release, warnings are errors)"
swift build -c release --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors 2>&1 | filter_toolchain_notices
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null)/Vigil"
[ -x "$BIN" ] || { echo "error: $BIN not found" >&2; exit 1; }

step "Assembling Vigil.app"
rm -rf "$STAGE"
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources"
cp "$BIN" "$APP_STAGE/Contents/MacOS/Vigil"
sed -e "s|<string>1.0.0</string>|<string>$VERSION</string>|" Resources/Info.plist > "$APP_STAGE/Contents/Info.plist"
plutil -lint "$APP_STAGE/Contents/Info.plist" >/dev/null

# Icon: render the PNGs if missing, then build the .icns (actool would need full Xcode).
if [ ! -f Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png ]; then
  swift Scripts/make_icon.swift Resources/Assets.xcassets >/dev/null
fi
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
cp Resources/Assets.xcassets/AppIcon.appiconset/*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP_STAGE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Localization (en + cs). Fails if the code uses a string that is missing from the catalog.
python3 Scripts/gen_lproj.py Resources/Localizable.xcstrings Sources "$APP_STAGE/Contents/Resources"

step "Signing (${SIGN_IDENTITY/#-/ad-hoc}, Hardened Runtime, no sandbox)"
xattr -cr "$APP_STAGE"
codesign --force --options runtime --timestamp=none --entitlements Resources/Vigil.entitlements \
  --sign "$SIGN_IDENTITY" "$APP_STAGE"
codesign --verify --strict --deep "$APP_STAGE"

step "Copying to ./build"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto --noextattr --noqtn "$APP_STAGE" "$OUT/Vigil.app"
codesign --verify --strict --deep "$OUT/Vigil.app" && echo "signature valid: $OUT/Vigil.app"
case "$ROOT" in
  "$HOME/Desktop"*|"$HOME/Documents"*|*"/Mobile Documents/"*)
    echo "note: this folder is iCloud-synced. iCloud re-stamps ./build/Vigil.app with Finder attributes a few seconds"
    echo "      from now, so a later 'codesign --verify' on THAT copy fails ('detritus not allowed') even though the app"
    echo "      launches fine. Use './build.sh --install' (copies to /Applications) for a copy that always verifies." ;;
esac

if [ "$INSTALL" = 1 ]; then
  step "Installing to /Applications"
  if pgrep -x Vigil >/dev/null; then
    echo "Quitting the running Vigil (it restores normal sleep on exit)..."
    pkill -TERM -x Vigil || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Vigil >/dev/null || break; sleep 0.5; done
  fi
  rm -rf /Applications/Vigil.app
  ditto --noextattr --noqtn "$APP_STAGE" /Applications/Vigil.app
  codesign --verify --strict --deep /Applications/Vigil.app && echo "installed: /Applications/Vigil.app"
  echo "Launch it with:  open /Applications/Vigil.app"
fi

step "Done"
echo "$OUT/Vigil.app"
