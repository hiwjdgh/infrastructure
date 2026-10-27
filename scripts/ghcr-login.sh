#!/usr/bin/env bash
set -euo pipefail
# Logs this host into GHCR using GHCR_USERNAME / GHCR_TOKEN from .env
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] || { echo "Missing $ROOT/.env (cp .env.example .env)" >&2; exit 2; }
# shellcheck disable=SC1091
source "$ROOT/.env"
[[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]] || { echo 'GHCR_USERNAME / GHCR_TOKEN must be set in .env' >&2; exit 2; }
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
