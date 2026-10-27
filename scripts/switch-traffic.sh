#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="${1:-}"; TARGET="${2:-}"
[[ "$SERVICE" =~ ^[a-z][a-z0-9-]*$ && "$TARGET" =~ ^(blue|green)$ ]] || exit 2
# shellcheck source=scripts/load-service-config.sh
source "$ROOT/scripts/load-service-config.sh"
mkdir -p "$ROOT/runtime" "$ROOT/nginx/routes"
# Global lock: concurrent service deploys must not race Nginx config reload.
exec 8>"$ROOT/runtime/nginx.lock"
flock -x 8
ROUTE="$ROOT/nginx/routes/$SERVICE.conf"
BACKUP="$(mktemp)"; TEMP="$(mktemp "$ROOT/nginx/routes/.route.XXXXXX")"
HAD_ROUTE=0
if [[ -f "$ROUTE" ]]; then cp "$ROUTE" "$BACKUP"; HAD_ROUTE=1; fi
cat > "$TEMP" <<NGINX
server {
    listen 80;
    server_name $SERVER_NAME;
    location / {
        proxy_pass http://platform-$SERVICE-$TARGET:$CONTAINER_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$forwarded_for;
        proxy_set_header X-Forwarded-Proto \$forwarded_proto;
    }
}
NGINX
mv "$TEMP" "$ROUTE"
if docker exec platform-nginx nginx -t && docker exec platform-nginx nginx -s reload; then
  printf '%s\n' "$TARGET" > "$ROOT/runtime/$SERVICE.state"
  rm -f "$BACKUP"
  echo "Route switched: $SERVER_NAME -> $TARGET"
else
  if [[ "$HAD_ROUTE" == 1 ]]; then cp "$BACKUP" "$ROUTE"; else rm -f "$ROUTE"; fi
  docker exec platform-nginx nginx -t >/dev/null 2>&1 && docker exec platform-nginx nginx -s reload || true
  rm -f "$BACKUP"
  echo 'Nginx switch failed; route restored' >&2
  exit 1
fi
