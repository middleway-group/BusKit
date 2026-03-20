#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTO_DIR="$SCRIPT_DIR/../Proto"
OUT_DIR="$SCRIPT_DIR/../BusKit/Generated"

mkdir -p "$OUT_DIR"

# Generate Swift Protobuf messages
protoc \
  --proto_path="$PROTO_DIR" \
  --swift_out="$OUT_DIR" \
  --swift_opt=Visibility=Public \
  "$PROTO_DIR/buskit.proto"

# Generate gRPC Swift v2 client stubs
# protoc \
#   --proto_path="$PROTO_DIR" \
#   --grpc-swift_out="$OUT_DIR" \
#   --grpc-swift_opt=Visibility=Public,Client=true,Server=false \
#   "$PROTO_DIR/buskit.proto"

protoc \
  --proto_path="$PROTO_DIR" \
  --grpc-swift-2_out="$OUT_DIR" \
  --grpc-swift-2_opt=Client=true,Server=false \
  "$PROTO_DIR/buskit.proto"

# Remove `type: .<kind>` lines emitted by newer plugin versions that are
# incompatible with the gRPC-Swift library pinned in this project.
sed -i '' \
  '/^[[:space:]]*type: \./d' \
  "$OUT_DIR/buskit.grpc.swift"
# Clean up the trailing comma left on the preceding `method:` line.
sed -i '' \
  's/\(method: "[^"]*"\),$/\1/' \
  "$OUT_DIR/buskit.grpc.swift"

echo "✅ Generated files in $OUT_DIR:"
ls -la "$OUT_DIR"
