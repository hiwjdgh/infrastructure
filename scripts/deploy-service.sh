#!/usr/bin/env bash
set -euo pipefail
# Usage: deploy-service.sh php-frontend ghcr.io/hiwjdgh/php-frontend:sha-abc123  # [ORG] ghcr.io/<org>/php-frontend:sha-abc123
#        deploy-service.sh php-frontend sha-abc123   (tag only -> uses IMAGE_REPO from services/<service>.conf)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="${1:-}"; IMAGE="${2:-}"
[[ "$SERVICE" =~ ^[a-z][a-z0-9-]*$ && -n "$IMAGE" ]] || { echo 'Usage: deploy-service.sh <service> <image>' >&2; exit 2; }
# shellcheck source=scripts/load-service-config.sh
source "$ROOT/scripts/load-service-config.sh"
# Tag only (no '/') -> prepend IMAGE_REPO from the service config.
if [[ "$IMAGE" != */* ]]; then
  [[ -n "${IMAGE_REPO:-}" ]] || { echo "IMAGE_REPO not set in $CONFIG; pass a full image reference" >&2; exit 2; }
  IMAGE="$IMAGE_REPO:$IMAGE"
fi
[[ "$CONTAINER_PORT" =~ ^[0-9]+$ && "$HEALTH_PATH" == /* ]] || { echo 'Invalid service config' >&2; exit 2; }
# App runtime env: environments/<APP_ENV>/<service>.env (APP_ENV from .env, default local)
APP_ENV="${APP_ENV:-local}"
[[ "$APP_ENV" =~ ^(local|test|prod)$ ]] || { echo "Invalid APP_ENV: $APP_ENV (local|test|prod)" >&2; exit 2; }
export APP_ENV_FILE="$ROOT/environments/$APP_ENV/$SERVICE.env"
[[ -f "$APP_ENV_FILE" ]] || echo "WARN: $APP_ENV_FILE not found; starting without app env vars" >&2
# Memory limit (resolved in load-service-config.sh)
export MEMORY_LIMIT
[[ "$MEMORY_LIMIT" =~ ^([0-9]+)([mg])$ ]] || { echo "Invalid memory limit: $MEMORY_LIMIT (e.g. 512m, 2g)" >&2; exit 2; }
LIMIT_MB="${BASH_REMATCH[1]}"; [[ "${BASH_REMATCH[2]}" == m ]] || LIMIT_MB=$((LIMIT_MB * 1024))
# Node apps: cap V8 heap below the container limit so Node GCs before the kernel OOM-kills it.
unset NODE_OPTIONS
if [[ -n "${NODE_HEAP_PERCENT:-}" ]]; then
  [[ "$NODE_HEAP_PERCENT" =~ ^[0-9]+$ ]] || { echo "Invalid NODE_HEAP_PERCENT: $NODE_HEAP_PERCENT" >&2; exit 2; }
  export NODE_OPTIONS="--max-old-space-size=$((LIMIT_MB * NODE_HEAP_PERCENT / 100))"
fi
echo "Memory limit: $MEMORY_LIMIT${NODE_OPTIONS:+ ($NODE_OPTIONS)}"
mkdir -p "$ROOT/runtime" "$ROOT/nginx/routes"
exec 9>"$ROOT/runtime/$SERVICE.lock"
flock -x 9
STATE="$ROOT/runtime/$SERVICE.state"
ENVFILE="$ROOT/runtime/$SERVICE.images.env"
ACTIVE='none'
[[ ! -f "$STATE" ]] || ACTIVE="$(cat "$STATE")"
case "$ACTIVE" in
  none|green) TARGET=blue ;;
  blue) TARGET=green ;;
  *) echo 'Invalid state' >&2; exit 1 ;;
esac
if [[ ! -f "$ENVFILE" ]]; then
  printf 'SERVICE=%s\nBLUE_IMAGE=nginx:alpine\nGREEN_IMAGE=nginx:alpine\n' "$SERVICE" > "$ENVFILE"
fi
# Only the inactive slot's image changes. Old slot remains available for rollback.
if [[ "$TARGET" == blue ]]; then
  sed -i "s|^BLUE_IMAGE=.*|BLUE_IMAGE=$IMAGE|" "$ENVFILE"
else
  sed -i "s|^GREEN_IMAGE=.*|GREEN_IMAGE=$IMAGE|" "$ENVFILE"
fi
cd "$ROOT"
docker pull "$IMAGE"
docker compose -p "platform-$SERVICE" --env-file "$ENVFILE" -f services/compose.yaml up -d --no-deps "$TARGET"
CONTAINER="platform-$SERVICE-$TARGET"
echo "Checking $CONTAINER on $HEALTH_PATH"
HEALTHY=0
for _ in $(seq 1 30); do
  if docker exec platform-nginx wget -q -T 2 -O /dev/null "http://$CONTAINER:$CONTAINER_PORT$HEALTH_PATH"; then HEALTHY=1; break; fi
  sleep 2
done
if [[ "$HEALTHY" != 1 ]]; then
  echo 'Health check failed; old route unchanged' >&2
  exit 1
fi
"$ROOT/scripts/switch-traffic.sh" "$SERVICE" "$TARGET"
echo "Deployed $SERVICE: $ACTIVE -> $TARGET ($IMAGE)"
