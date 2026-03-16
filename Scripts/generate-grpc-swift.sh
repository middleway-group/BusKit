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

echo "✅ Generated files in $OUT_DIR:"
ls -la "$OUT_DIR"
