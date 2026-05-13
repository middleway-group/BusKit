#!/bin/bash
# package.sh — Build and package BusKit.app as a macOS DMG installer.
#
# Usage:
#   ./Scripts/package.sh [OPTIONS]
#
# Options:
#   --arch arm64|x86_64|universal   Target architecture (default: universal)
#   --output <path>                 Output DMG path (default: ./BusKit-<arch>.dmg)
#   --configuration Debug|Release   Xcode build configuration (default: Release)
#   -h, --help                      Show this message

set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$ROOT/Scripts"

# ── Defaults ─────────────────────────────────────────────────────────────────
ARCH="universal"
CONFIGURATION="Release"
OUTPUT_DMG=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --output)
      OUTPUT_DMG="$2"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    -h|--help)
      awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else if(!/^$/){exit}}' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" && "$ARCH" != "universal" ]]; then
  echo "❌ --arch must be arm64, x86_64, or universal" >&2
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
[[ -z "$OUTPUT_DMG" ]] && OUTPUT_DMG="$ROOT/BusKit-${ARCH}-${TIMESTAMP}.dmg"

# ── Derived paths ─────────────────────────────────────────────────────────────
BUILD_DIR="$ROOT/.build/package"
ARCHIVE_PATH="$BUILD_DIR/BusKit.xcarchive"
APP_STAGE_DIR="$BUILD_DIR/app"
DMG_STAGE_DIR="$BUILD_DIR/dmg-staging"

# ── Prerequisites ─────────────────────────────────────────────────────────────
echo "🔍 Checking prerequisites..."
command -v xcodebuild >/dev/null || { echo "❌ xcodebuild not found" >&2; exit 1; }
command -v dotnet     >/dev/null || { echo "❌ dotnet not found (install from https://dot.net)" >&2; exit 1; }
command -v hdiutil    >/dev/null || { echo "❌ hdiutil not found" >&2; exit 1; }

# ── Clean staging area ────────────────────────────────────────────────────────
echo "🧹 Cleaning build staging area..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$APP_STAGE_DIR" "$DMG_STAGE_DIR"

# ── Helper: build .NET sidecar for one arch ───────────────────────────────────
build_sidecar_arch() {
  local arch=$1      # arm64 or x86_64
  local out_dir=$2

  # Map macOS arch name → .NET runtime identifier
  local rid
  case "$arch" in
    arm64)  rid="osx-arm64" ;;
    x86_64) rid="osx-x64"   ;;
    *)      echo "❌ Unknown arch: $arch" >&2; exit 1 ;;
  esac

  echo ""
  echo "🔨 Building sidecar for $arch ($rid) → $out_dir"
  SIDECAR_TARGET_RID="$rid" \
  SIDECAR_OUTPUT_DIR="$out_dir" \
    "$SCRIPTS_DIR/build-sidecar.sh"
}

# ── Build sidecar(s) ──────────────────────────────────────────────────────────
SIDECAR_ARM64_DIR="$BUILD_DIR/sidecar-arm64"
SIDECAR_X86_DIR="$BUILD_DIR/sidecar-x86_64"

case "$ARCH" in
  arm64)
    build_sidecar_arch arm64 "$SIDECAR_ARM64_DIR"
    ;;
  x86_64)
    build_sidecar_arch x86_64 "$SIDECAR_X86_DIR"
    ;;
  universal)
    build_sidecar_arch arm64  "$SIDECAR_ARM64_DIR"
    build_sidecar_arch x86_64 "$SIDECAR_X86_DIR"
    ;;
esac

# ── Archive Swift app via Xcode ───────────────────────────────────────────────
# The Xcode build phase will run build-sidecar.sh for arm64 automatically;
# we override it with the SIDECAR_TARGET_RID we need for the primary arch.
case "$ARCH" in
  arm64|universal) PRIMARY_RID="osx-arm64" ;;
  x86_64)          PRIMARY_RID="osx-x64"   ;;
esac

echo ""
echo "📦 Archiving BusKit.xcodeproj (${CONFIGURATION}, primary sidecar: ${PRIMARY_RID})..."
SIDECAR_TARGET_RID="$PRIMARY_RID" \
xcodebuild archive \
  -project "$ROOT/BusKit.xcodeproj" \
  -scheme BusKit \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  ONLY_ACTIVE_ARCH=NO \
  2>&1 | grep -E "(error:|warning:|note:|Archive Succeeded|BusKit\.xcarchive)"

echo "✅ Archive complete: $ARCHIVE_PATH"

# ── Extract .app from archive ─────────────────────────────────────────────────
APP_SRC=$(find "$ARCHIVE_PATH/Products" -name "BusKit.app" -maxdepth 4 | head -1)
if [[ -z "$APP_SRC" ]]; then
  echo "❌ BusKit.app not found inside archive at $ARCHIVE_PATH" >&2
  exit 1
fi
APP_PATH="$APP_STAGE_DIR/BusKit.app"
cp -R "$APP_SRC" "$APP_PATH"
echo "✅ Extracted: $APP_PATH"

# ── Inject sidecar binaries into the .app bundle ─────────────────────────────
RESOURCES_DIR="$APP_PATH/Contents/Resources"
SIDECAR_BUNDLE_DIR="$RESOURCES_DIR/SidecarBin"

case "$ARCH" in
  arm64)
    # Xcode already placed the arm64 sidecar here — nothing more to do.
    echo "✅ arm64 sidecar already in bundle."
    ;;

  x86_64)
    # Replace the arm64 sidecar Xcode placed with the x86_64 one.
    echo "🔄 Replacing arm64 sidecar with x86_64..."
    rm -rf "$SIDECAR_BUNDLE_DIR"
    cp -R "$SIDECAR_X86_DIR" "$SIDECAR_BUNDLE_DIR"
    echo "✅ x86_64 sidecar injected."
    ;;

  universal)
    echo "🔄 Setting up universal sidecar bundle..."
    # Move existing (arm64) files into arm64 sub-directory.
    TMP_ARM64="$BUILD_DIR/sidecar-arm64-tmp"
    mv "$SIDECAR_BUNDLE_DIR" "$TMP_ARM64"
    mkdir -p "$SIDECAR_BUNDLE_DIR/arm64" "$SIDECAR_BUNDLE_DIR/x86_64"
    cp -R "$TMP_ARM64/." "$SIDECAR_BUNDLE_DIR/arm64/"
    cp -R "$SIDECAR_X86_DIR/." "$SIDECAR_BUNDLE_DIR/x86_64/"
    rm -rf "$TMP_ARM64"

    # Create arch-detecting launcher script.
    LAUNCHER="$SIDECAR_BUNDLE_DIR/BusKit.Sidecar"
    cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/bin/bash
# Launcher: selects the sidecar binary matching the current CPU architecture.
DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
  exec "$DIR/arm64/BusKit.Sidecar" "$@"
else
  exec "$DIR/x86_64/BusKit.Sidecar" "$@"
fi
LAUNCHER_EOF
    chmod +x "$LAUNCHER"
    echo "✅ Universal sidecar bundle created with arch-detecting launcher."
    ;;
esac

# ── Create DMG ────────────────────────────────────────────────────────────────
echo ""
echo "💿 Creating DMG: $OUTPUT_DMG"

cp -R "$APP_PATH" "$DMG_STAGE_DIR/BusKit.app"
# Strip quarantine and other extended attributes so Gatekeeper doesn't block
# the app with "damaged and can't be opened" on unsigned builds.
xattr -cr "$DMG_STAGE_DIR/BusKit.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

rm -f "$OUTPUT_DMG"
hdiutil create \
  -volname "BusKit" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_DMG"

echo ""
echo "🎉 Done!"
echo "   Installer: $OUTPUT_DMG"
echo "   Arch:      $ARCH"
DMG_SIZE=$(du -sh "$OUTPUT_DMG" | cut -f1)
echo "   Size:      $DMG_SIZE"
