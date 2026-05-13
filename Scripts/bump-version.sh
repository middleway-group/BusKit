#!/bin/bash
# bump-version.sh — Bumps the version in BusKit.xcodeproj/project.pbxproj
#
# Usage: ./Scripts/bump-version.sh [--major | --minor | --patch]
# Default: --patch
#
# MARKETING_VERSION follows semver (X.Y.Z).
# CURRENT_PROJECT_VERSION is derived as X*10000 + Y*100 + Z.

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$ROOT/BusKit.xcodeproj/project.pbxproj"

BUMP="${1:---patch}"
case "$BUMP" in
  --major) COMPONENT=major ;;
  --minor) COMPONENT=minor ;;
  --patch) COMPONENT=patch ;;
  *)
    echo "Unknown option: $BUMP" >&2
    echo "Usage: $0 [--major | --minor | --patch]" >&2
    exit 1
    ;;
esac

# Read current MARKETING_VERSION (both build configs have the same value)
CURRENT=$(grep 'MARKETING_VERSION' "$PBXPROJ" | head -1 | sed 's/.*MARKETING_VERSION = //;s/;//' | xargs)

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
MAJOR="${MAJOR:-1}"
MINOR="${MINOR:-0}"
PATCH="${PATCH:-0}"

case "$COMPONENT" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
NEW_BUILD=$(( MAJOR * 10000 + MINOR * 100 + PATCH ))

echo "📦 Bumping version: $CURRENT → $NEW_VERSION (build $NEW_BUILD)"

# Escape dots for use in sed patterns
ESCAPED_CURRENT="${CURRENT//./\\.}"

sed -i '' \
  "s/MARKETING_VERSION = ${ESCAPED_CURRENT};/MARKETING_VERSION = ${NEW_VERSION};/g" \
  "$PBXPROJ"

CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION' "$PBXPROJ" | head -1 | sed 's/.*CURRENT_PROJECT_VERSION = //;s/;//' | xargs)
sed -i '' \
  "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD};/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" \
  "$PBXPROJ"

echo "✅ MARKETING_VERSION = $NEW_VERSION"
echo "✅ CURRENT_PROJECT_VERSION = $NEW_BUILD"
