#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
docker network inspect platform-network >/dev/null 2>&1 || docker network create platform-network
docker compose up -d nginx
mkdir -p "$ROOT/runtime" "$ROOT/nginx/routes"
echo 'Nginx is running. Try: curl -I http://localhost:8080'
