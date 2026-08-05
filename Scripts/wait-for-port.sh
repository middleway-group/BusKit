#!/bin/bash
# Waits (up to a timeout) for something to be listening on the given TCP port.
# Always exits 0 so it never blocks a debug launch as a preLaunchTask, even on timeout.

PORT="${1:-50051}"
MAX_TRIES="${2:-40}"

for i in $(seq 1 "$MAX_TRIES"); do
  if lsof -i "tcp:$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "✅ Port $PORT is listening"
    exit 0
  fi
  sleep 0.25
done

echo "⚠️  Timed out waiting for port $PORT to open (continuing anyway)"
exit 0
