#!/bin/bash
# release.sh — Build, sign, and publish a new BusKit release from your local machine.
#
# Usage:
#   ./Scripts/release.sh [--patch|--minor|--major]
#
# Defaults to --patch.
#
# Requirements:
#   - gh CLI authenticated  (brew install gh)
#   - Sparkle private key in your login Keychain
#     (run: sparkle-tools/bin/generate_keys  to verify it's present)
#
# This script signs the DMG using your local Keychain key — the SPARKLE_PRIVATE_KEY
# GitHub secret is no longer needed.

set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$ROOT/Scripts"
SPARKLE_VERSION="2.9.3"

# ── Argument parsing ──────────────────────────────────────────────────────────
BUMP_TYPE="patch"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --patch|--minor|--major) BUMP_TYPE="${1#--}"; shift ;;
    -h|--help)
      awk 'NR>1{if(/^#/){sub(/^# ?/,"");print}else if(!/^$/){exit}}' "$0"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Prerequisites ─────────────────────────────────────────────────────────────
echo "🔍 Checking prerequisites..."
command -v gh >/dev/null || {
  echo "❌ gh CLI not found — install with: brew install gh" >&2; exit 1
}
gh auth status >/dev/null 2>&1 || {
  echo "❌ gh CLI not authenticated — run: gh auth login" >&2; exit 1
}

# ── Find or download Sparkle tools ───────────────────────────────────────────
find_sparkle_bin() {
  for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" /tmp/sparkle-release/bin; do
    [[ -x "$d/sign_update" ]] && echo "$d" && return 0
  done
  echo "📦 Downloading Sparkle tools v${SPARKLE_VERSION}…" >&2
  mkdir -p /tmp/sparkle-release
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
    -o /tmp/sparkle-release.tar.xz
  tar xf /tmp/sparkle-release.tar.xz -C /tmp/sparkle-release
  echo "/tmp/sparkle-release/bin"
}
SPARKLE_BIN="$(find_sparkle_bin)"

# Verify the Keychain key is present and matches the app's public key
APP_PUBKEY=$(grep 'INFOPLIST_KEY_SUPublicEDKey' "$ROOT/BusKit.xcodeproj/project.pbxproj" \
  | head -1 | sed 's/.*= "//;s/";//' | xargs)
KEYCHAIN_PUBKEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)
if [[ -z "$KEYCHAIN_PUBKEY" ]]; then
  echo "❌ No Sparkle private key found in Keychain." >&2
  echo "   Run: $SPARKLE_BIN/generate_keys  to create one, then update SUPublicEDKey in Xcode." >&2
  exit 1
fi
if [[ "$KEYCHAIN_PUBKEY" != "$APP_PUBKEY" ]]; then
  echo "❌ Keychain public key ($KEYCHAIN_PUBKEY)" >&2
  echo "   does not match app's SUPublicEDKey ($APP_PUBKEY)" >&2
  exit 1
fi
echo "✅ Sparkle key verified: $APP_PUBKEY"

# Verify git tree is clean
if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --staged --quiet; then
  echo "❌ Working tree has uncommitted changes. Please commit or stash first." >&2
  exit 1
fi

# ── Step 1: Bump version ──────────────────────────────────────────────────────
echo ""
echo "📦 Bumping $BUMP_TYPE version…"
"$SCRIPTS_DIR/bump-version.sh" "--${BUMP_TYPE}"
VERSION=$(grep 'MARKETING_VERSION' "$ROOT/BusKit.xcodeproj/project.pbxproj" \
  | head -1 | sed 's/.*MARKETING_VERSION = //;s/;//' | xargs)
BUILD=$(grep 'CURRENT_PROJECT_VERSION' "$ROOT/BusKit.xcodeproj/project.pbxproj" \
  | head -1 | sed 's/.*CURRENT_PROJECT_VERSION = //;s/;//' | xargs)
TAG="v${VERSION}"
DMG="$ROOT/BusKit-${VERSION}-arm64.dmg"
echo "   Version: $VERSION  Build: $BUILD  Tag: $TAG"

# Commit the version bump
git -C "$ROOT" add BusKit.xcodeproj/project.pbxproj
git -C "$ROOT" commit -m "chore: bump version to $VERSION"

# ── Step 2: Build DMG ─────────────────────────────────────────────────────────
echo ""
echo "🔨 Building DMG…"
"$SCRIPTS_DIR/package.sh" --arch arm64 --output "$DMG"
DMG_SIZE=$(du -sh "$DMG" | cut -f1)
echo "   Size: $DMG_SIZE"

# ── Step 3: Tag and push ──────────────────────────────────────────────────────
echo ""
echo "🏷️  Tagging and pushing…"
git -C "$ROOT" tag "$TAG"
git -C "$ROOT" push origin main
git -C "$ROOT" push origin "$TAG"

# ── Step 4: Create GitHub release ─────────────────────────────────────────────
echo ""
echo "🚀 Creating GitHub release $TAG…"
gh release create "$TAG" "$DMG" \
  --repo middleway-group/BusKit \
  --title "BusKit $TAG" \
  --generate-notes
echo "✅ GitHub release created"

# ── Step 5: Sign DMG and update appcast ───────────────────────────────────────
echo ""
echo "✍️  Signing DMG (from Keychain)…"
SIGN_OUT=$("$SPARKLE_BIN/sign_update" "$DMG" 2>&1)
ED_SIG=$(echo "$SIGN_OUT" | grep -o 'sparkle:edSignature="[^"]*"' \
  | sed 's/sparkle:edSignature="//;s/"//')
DMG_LEN=$(stat -f%z "$DMG")
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://github.com/middleway-group/BusKit/releases/download/${TAG}/BusKit-${VERSION}-arm64.dmg"

echo "   Signature: ${ED_SIG:0:20}…"

APPCAST_PATH="$ROOT/releases/appcast.xml" \
VERSION="$VERSION" \
BUILD="$BUILD" \
PUBDATE="$PUBDATE" \
DOWNLOAD_URL="$DOWNLOAD_URL" \
ED_SIG="$ED_SIG" \
DMG_LEN="$DMG_LEN" \
python3 "$ROOT/Scripts/update_appcast.py"

# ── Step 6: Commit and push appcast ──────────────────────────────────────────
echo ""
echo "📝 Committing appcast…"
git -C "$ROOT" add releases/appcast.xml
git -C "$ROOT" commit -m "chore: update appcast for $VERSION [skip ci]"
git -C "$ROOT" push origin main

# ── Cleanup ────────────────────────────────────────────────────────────────────
rm -f "$DMG"

echo ""
echo "🎉 Released BusKit $VERSION successfully!"
echo "   Tag:      $TAG"
echo "   Release:  https://github.com/middleway-group/BusKit/releases/tag/$TAG"
echo "   Appcast:  https://raw.githubusercontent.com/middleway-group/BusKit/main/releases/appcast.xml"
