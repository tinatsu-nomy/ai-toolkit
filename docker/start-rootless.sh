#!/bin/sh
set -eu

if [ ! -w /data ] || [ ! -w /cache/huggingface ]; then
    echo "Prepare /data and /cache/huggingface with write permission for the configured APP_UID/APP_GID." >&2
    exit 1
fi

cd /app/ai-toolkit/ui
npm run update_db
exec npm run start
