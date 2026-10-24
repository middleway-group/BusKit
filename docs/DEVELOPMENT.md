# Development Guide

## Prerequisites

- macOS with Xcode (CI uses `macos-26`), Swift 5.9+, macOS 13+ deployment target per README
- .NET 10 SDK (`10.0.x`) for the sidecar
- `protoc` + Swift protobuf / gRPC plugins (only when regenerating gRPC code)
- `gh` CLI (releases only)

## Build

The Xcode project has a build phase that runs `Scripts/build-sidecar.sh`, which publishes the .NET sidecar into the app bundle (`Contents/Resources/SidecarBin`). So building the app builds the sidecar too.

```bash
xcodebuild build \
  -project BusKit.xcodeproj -scheme BusKit \
  -configuration Debug -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

(CI additionally passes `SWIFT_STRICT_CONCURRENCY=off`.) Or open `BusKit.xcodeproj` in Xcode and run the `BusKit` scheme.

Sidecar only (staging output in `SidecarBin/`):

```bash
./Scripts/build-sidecar.sh
```

Env overrides: `SIDECAR_TARGET_RID` (default `osx-arm64`), `SIDECAR_BUILD_CONFIGURATION` (default: Xcode `CONFIGURATION`, else `Release`), `SIDECAR_OUTPUT_DIR`.

## Test

```bash
# .NET sidecar (xUnit)
dotnet test Sidecar/BusKit.Sidecar.Tests/BusKit.Sidecar.Tests.csproj --configuration Release

# Swift app tests (BusKitTests/)
xcodebuild test -project BusKit.xcodeproj -scheme BusKit -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=off
```

Place sidecar tests in the file matching the service area (`EntityOperationsTests.cs`, `MessageOperationsTests.cs`, …). Place Swift tests next to the matching store/model test in `BusKitTests/`.

## Running locally

On launch `GRPCManager.startSidecar` kills any orphaned process on port 50051, launches the bundled sidecar, polls the port for up to 30 s, then connects the gRPC client. If it fails, the error message includes the sidecar log path. `Scripts/wait-for-port.sh` is a helper for scripts.

## Regenerate gRPC code

See `docs/PROTO-WORKFLOW.md`.

## CI/CD (`.github/workflows/`)

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `tests.yml` | push to `main`, PRs | .NET tests (ubuntu) and Swift tests (macOS) |
| `ci.yml` | tag `vX.Y.Z` | Debug `xcodebuild build` |
| `release.yml` | manual (`version` input) | Builds, tags, publishes release |

## Versioning and release

- `./Scripts/bump-version.sh [--major|--minor|--patch]` updates `MARKETING_VERSION` (semver) and `CURRENT_PROJECT_VERSION` (`X*10000 + Y*100 + Z`) in `project.pbxproj`.
- `./Scripts/package.sh [--arch arm64|x86_64|universal] [--output path] [--configuration Debug|Release]` builds a DMG.
- `./Scripts/release.sh [--patch|--minor|--major]` builds, signs (Sparkle key in login Keychain), and publishes via `gh`. Updates the Sparkle appcast with `Scripts/update_appcast.py`; notes rendered by `Scripts/render_release_notes.py` from `RELEASE_NOTES.md`.

## Before opening a PR

- [ ] Sidecar tests pass; Swift tests pass
- [ ] Proto files in sync and Swift code regenerated if the contract changed
- [ ] `docs/CODEMAP.md` updated if files/modules were added, moved, or removed
- [ ] `RELEASE_NOTES.md` updated for user-visible changes
