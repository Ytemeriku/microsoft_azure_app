#!/bin/sh
set -eu

API_BASE_URL="${API_BASE_URL:-}"

if [ -n "$API_BASE_URL" ]; then
	printf 'window.__API_BASE_URL__ = %s;\n' "$(printf '%s' "$API_BASE_URL" | sed "s/'/'\\''/g; s/^/'/; s/$/'/")" >/usr/share/nginx/html/config.js
else
	printf 'window.__API_BASE_URL__ = "";\n' >/usr/share/nginx/html/config.js
fi

exec nginx -g 'daemon off;'