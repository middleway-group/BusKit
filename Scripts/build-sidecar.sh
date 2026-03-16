#!/bin/bash
set -e

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# $SRCROOT is set by Xcode; fall back to deriving from $0 when run manually.
if [ -n "$SRCROOT" ]; then
  ROOT="$SRCROOT"
else
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

SIDECAR_PROJECT="$ROOT/Sidecar/BusKit.Sidecar/BusKit.Sidecar.csproj"
STAGING_DIR="$ROOT/SidecarBin"

echo "ROOT        = $ROOT"
echo "SIDECAR_PROJECT = $SIDECAR_PROJECT"

if [ ! -f "$SIDECAR_PROJECT" ]; then
  echo "❌ ERROR: csproj not found at $SIDECAR_PROJECT" >&2
  exit 1
fi

# Publish directly to the app bundle when inside Xcode, staging dir otherwise.
if [ -n "$BUILT_PRODUCTS_DIR" ] && [ -n "$WRAPPER_NAME" ]; then
  OUTPUT_DIR="$BUILT_PRODUCTS_DIR/$WRAPPER_NAME/Contents/Resources/SidecarBin"
  echo "📦 Publishing directly to bundle: $OUTPUT_DIR"
else
  OUTPUT_DIR="$STAGING_DIR"
  echo "📦 Publishing to staging: $OUTPUT_DIR"
fi

echo "🔨 Building sidecar..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

dotnet publish "$SIDECAR_PROJECT" \
  -c Release \
  -r osx-arm64 \
  --self-contained true \
  -o "$OUTPUT_DIR"

echo "✅ Sidecar published to $OUTPUT_DIR"
ls "$OUTPUT_DIR/" | grep "BusKit.Sidecar"

# Safety net: if dotnet produced BusKit.dll instead of BusKit.Sidecar.dll, rename.
if [ -f "$OUTPUT_DIR/BusKit.dll" ] && [ ! -f "$OUTPUT_DIR/BusKit.Sidecar.dll" ]; then
  echo "⚠️  Renaming BusKit.* → BusKit.Sidecar.*"
  mv "$OUTPUT_DIR/BusKit.dll"                           "$OUTPUT_DIR/BusKit.Sidecar.dll"
  [ -f "$OUTPUT_DIR/BusKit.pdb" ]                       && mv "$OUTPUT_DIR/BusKit.pdb"                       "$OUTPUT_DIR/BusKit.Sidecar.pdb"
  [ -f "$OUTPUT_DIR/BusKit.staticwebassets.endpoints.json" ] && mv "$OUTPUT_DIR/BusKit.staticwebassets.endpoints.json" "$OUTPUT_DIR/BusKit.Sidecar.staticwebassets.endpoints.json"
fi

ls "$OUTPUT_DIR/BusKit.Sidecar.dll" && echo "✅ BusKit.Sidecar.dll present" || { echo "❌ BusKit.Sidecar.dll MISSING"; exit 1; }

# Keep staging dir in sync for reference.
if [ "$OUTPUT_DIR" != "$STAGING_DIR" ]; then
  rm -rf "$STAGING_DIR"
  cp -R "$OUTPUT_DIR" "$STAGING_DIR"
fi

