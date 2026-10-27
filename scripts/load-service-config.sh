#!/usr/bin/env bash
# Sourced by deploy-service.sh / switch-traffic.sh (expects ROOT and SERVICE).
# Loads services/<service>.conf, then the host's .env, and applies per-host overrides:
#   SERVER_NAME_<SERVICE>  > SERVER_NAME  in services/<service>.conf   (e.g. SERVER_NAME_NEXT_FRONTEND)
#   MEMORY_LIMIT_<SERVICE> > MEMORY_LIMIT in services/<service>.conf > 512m
CONFIG="$ROOT/services/$SERVICE.conf"
[[ -f "$CONFIG" ]] || { echo "Missing service config: $CONFIG" >&2; exit 2; }
# shellcheck disable=SC1090
source "$CONFIG"
# shellcheck disable=SC1091
[[ ! -f "$ROOT/.env" ]] || source "$ROOT/.env"
SERVICE_KEY="$(tr 'a-z-' 'A-Z_' <<< "$SERVICE")"
_override="SERVER_NAME_$SERVICE_KEY"; SERVER_NAME="${!_override:-${SERVER_NAME:-}}"
_override="MEMORY_LIMIT_$SERVICE_KEY"; MEMORY_LIMIT="${!_override:-${MEMORY_LIMIT:-512m}}"
unset _override
# One or more space-separated host names.
[[ "$SERVER_NAME" =~ ^[a-zA-Z0-9.-]+( [a-zA-Z0-9.-]+)*$ ]] || { echo "Invalid SERVER_NAME for $SERVICE: '$SERVER_NAME'" >&2; exit 2; }
