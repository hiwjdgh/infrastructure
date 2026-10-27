#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="${1:-}"
[[ "$SERVICE" =~ ^[a-z][a-z0-9-]*$ ]] || { echo 'Usage: rollback-service.sh <service>' >&2; exit 2; }
exec 9>"$ROOT/runtime/$SERVICE.lock"
flock -x 9
STATE="$ROOT/runtime/$SERVICE.state"
[[ -f "$STATE" ]] || { echo 'No active deployment' >&2; exit 1; }
ACTIVE="$(cat "$STATE")"
case "$ACTIVE" in blue) TARGET=green;; green) TARGET=blue;; *) exit 1;; esac
# Verify the previous slot is still running.
[[ "$(docker inspect -f '{{.State.Running}}' "platform-$SERVICE-$TARGET" 2>/dev/null)" == true ]] || { echo 'Previous slot not running' >&2; exit 1; }
"$ROOT/scripts/switch-traffic.sh" "$SERVICE" "$TARGET"
