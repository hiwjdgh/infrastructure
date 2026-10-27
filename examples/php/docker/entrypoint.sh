#!/bin/sh
# COPY INTO THE PHP REPO: docker/entrypoint.sh
# Runs php-fpm and nginx together. If either exits, the container exits so Docker restarts it.
set -eu

php-fpm -t >/dev/null 2>&1 || php-fpm -t
nginx -t -q

php-fpm -F &
FPM=$!
nginx -g 'daemon off;' &
NGINX=$!

stop() { kill -QUIT "$FPM" "$NGINX" 2>/dev/null || true; }
trap stop TERM INT QUIT

while kill -0 "$FPM" 2>/dev/null && kill -0 "$NGINX" 2>/dev/null; do
  sleep 1
done
stop
wait || true
exit 1
