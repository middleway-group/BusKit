# BusKit Codemap

Native macOS client for Azure Service Bus. Sidecar architecture: a SwiftUI app
talks over gRPC to a local .NET sidecar that uses the Azure SDKs.

```
SwiftUI app (BusKit/)  ──gRPC──▶  .NET Sidecar (Sidecar/BusKit.Sidecar)  ──▶  Azure Service Bus / ARM / MSAL
        ▲                                   ▲
        └────────── buskit.proto ───────────┘  (see docs/PROTO-WORKFLOW.md; two copies)
```

## Top level

| Path | Purpose |
|------|---------|
| `BusKit/` | SwiftUI macOS app source |
| `BusKitTests/` | Swift unit tests (ActivityLogStore, EntityActionStore, MessageSearch, Models) |
| `BusKit.xcodeproj/` | Xcode project; shared `BusKit` scheme |
| `Sidecar/` | .NET gRPC backend + xUnit tests |
| `SidecarBin/` | Built/published sidecar binaries bundled into the app |
| `Proto/buskit.proto` | gRPC service contract (source of truth for Swift codegen) |
| `Scripts/` | Build, packaging, release, versioning helpers |
| `Assets/`, `releases/` | Icons/logos; release artifacts |
| `.github/workflows/` | `ci.yml` (xcodebuild), `tests.yml`, `release.yml` |
| `README.md`, `RELEASE_NOTES.md` | Docs |

## Swift app (`BusKit/`)

- `BusKitApp.swift` – app entry, scenes, sidecar lifecycle.
- `ContentView.swift` – root layout (sidebar / detail / panels).
- `Providers/GRPCManager.swift` – gRPC client wrapper; all calls to sidecar.
- `Generated/buskit.pb.swift`, `buskit.grpc.swift` – generated; regenerate with `Scripts/generate-grpc-swift.sh`. Don't edit.
- `Models/`
  - `Models.swift` – domain types (namespaces, queues, topics, subscriptions, messages).
  - `ActivityLogStore.swift` – activity log state.
  - `AppStatusModel.swift` – connection/sidecar status.
  - `EntityActionStore.swift` – entity create/delete/purge actions.
  - `MessageSearch.swift` – message filtering/search logic.
- `Views/`
  - Navigation: `SidebarView`, `ConnectionToolbar`, `StatusBarView`, `ActivityLogPanel`, `ToastNotificationView`, `ProgressView`.
  - Entity details: `QueueDetailView`, `TopicDetailView`, `SubscriptionDetailView`, `OverviewComponents`.
  - Messages: `MessageBodyPanel`, `MessageSearchViews`, `SQLHighlightTextEditor`, `SendMessageSheet`, `BulkResubmitSheet`, `RepairResubmitSheet`.
  - Create sheets: `CreateQueueSheet`, `CreateTopicSheet`, `CreateSubscriptionSheet`.
  - RBAC: `RbacPermissionDialog`, `AccessSummaryCard`.
  - Misc: `AboutView`.

## .NET sidecar (`Sidecar/BusKit.Sidecar`)

- `Program.cs` – Kestrel/gRPC host setup, DI.
- `Protos/buskit.proto` – contract copy used by the server.
- `Services/`
  - `BusKitGrpcService.cs` – gRPC endpoint implementations; delegates to services below.
  - `ConnectionService.cs` – connection lifecycle, clients, RBAC/warmup.
  - `AzureAuth.cs`, `MsalTokenCredential.cs` – Azure/MSAL authentication.
  - `EntityOperations.cs`, `EntityPropertiesOperations.cs` – queue/topic/subscription/rule CRUD and properties.
  - `MessageOperations.cs`, `MessageProcessor.cs` – peek/send/receive/dead-letter/resubmit.
  - `MetricsOperations.cs` – Azure Monitor metrics.
  - `PermissionEvaluationEngine.cs` – RBAC role-assignment evaluation.
- `Models/PermissionEvaluationModels.cs` – RBAC evaluation types.
- `BusKit.Sidecar.Tests/` – xUnit tests, one file per service area.

## Scripts

- `build-sidecar.sh` – publish sidecar into `SidecarBin/`.
- `generate-grpc-swift.sh` – regenerate Swift gRPC code from `Proto/buskit.proto`.
- `wait-for-port.sh` – wait for sidecar port.
- `bump-version.sh`, `package.sh`, `release.sh`, `render_release_notes.py`, `update_appcast.py` – versioning, packaging, release notes, Sparkle appcast.

## Common workflows

- **Add an RPC:** edit `Proto/buskit.proto` (+ sync `Sidecar/.../Protos/`) → implement in `Services/` and `BusKitGrpcService.cs` → regenerate Swift code → call via `GRPCManager.swift` → surface in `Views/`.
- **Build app:** `xcodebuild` on the `BusKit` scheme.
- **Test:** Swift tests in `BusKitTests/`; .NET tests via `dotnet test` in `Sidecar/BusKit.Sidecar.Tests`.
