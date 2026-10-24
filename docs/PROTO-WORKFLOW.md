# gRPC / Proto Workflow

BusKit's Swift app and .NET sidecar share one contract, `buskit.proto`. Messages are exchanged over gRPC on `127.0.0.1:50051` (default, set in `GRPCManager.startSidecar`).

## Where the proto lives

| Location | Role |
|----------|------|
| `Sidecar/BusKit.Sidecar/Protos/buskit.proto` | Compiled by the sidecar (`<Protobuf ... GrpcServices="Server" />` in the csproj). **Currently the most up-to-date copy.** |
| `Proto/buskit.proto` | Input for `Scripts/generate-grpc-swift.sh` (Swift codegen). |
| `BusKit/Generated/buskit.pb.swift`, `buskit.grpc.swift` | Generated; never edit by hand. |

> ⚠️ **Known drift:** the two proto files are not identical. `Proto/buskit.proto` lacks `GetTopicMetrics` / `GetQueueMetrics`, the metric messages, and several newer queue properties (fields 17–23), yet the committed Swift code already contains them. Running the generator from the stale `Proto/` file would drop those APIs and break `GRPCManager`. **Before regenerating, sync `Proto/buskit.proto` from the sidecar copy** (or make one location the single source of truth, e.g. link the sidecar csproj to `../../Proto/buskit.proto`).

## Adding or changing an RPC

1. Edit `Sidecar/BusKit.Sidecar/Protos/buskit.proto` (add `rpc`, request/reply messages). Never reuse or renumber existing field numbers; add new fields with new numbers.
2. Copy the same file to `Proto/buskit.proto` so both match (`diff` them to verify).
3. Implement the operation in `Sidecar/BusKit.Sidecar/Services/` (e.g. `EntityOperations.cs`, `MessageOperations.cs`).
4. Expose it in `Services/BusKitGrpcService.cs` by overriding the generated method and delegating to the service.
5. Add or extend xUnit tests in `Sidecar/BusKit.Sidecar.Tests/` (one file per service area).
6. Regenerate Swift code:
   ```bash
   ./Scripts/generate-grpc-swift.sh
   ```
   Requires `protoc`, `protoc-gen-swift`, and `protoc-gen-grpc-swift-2` on `PATH`. The script post-processes `buskit.grpc.swift` with `sed` to strip `type: .<kind>` lines and fix trailing commas (needed for the pinned gRPC-Swift version) – review the diff of generated files.
7. Add a wrapper in `BusKit/Providers/GRPCManager.swift` (pattern: build `Buskit_*Request`, call the client, map errors, return Swift types from `Models.swift`).
8. Use it from views/stores (see `docs/UI-GUIDELINES.md`) and log via `ActivityLogStore` where appropriate.

## Conventions

- Replies that can fail soft carry an `error` string field (e.g. metrics replies); the Swift wrapper converts it to a thrown error / UI message.
- Proto naming: `snake_case` fields; generated Swift types are prefixed `Buskit_`.
- Keep Swift-side models in `BusKit/Models/Models.swift` separate from generated types; map in `GRPCManager`.

## Verification

```bash
diff Proto/buskit.proto Sidecar/BusKit.Sidecar/Protos/buskit.proto   # must be empty
dotnet test Sidecar/BusKit.Sidecar.Tests/BusKit.Sidecar.Tests.csproj
xcodebuild build -project BusKit.xcodeproj -scheme BusKit -destination "platform=macOS"
```
