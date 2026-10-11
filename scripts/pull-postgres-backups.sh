#!/bin/sh
# Copy the Pi's nightly Postgres dumps to this machine.
#
# The CronJob writes them on the Pi's SD card, which is the part most likely to
# fail: a dump that never leaves the card protects against a bad migration and
# nothing else. Run this from a machine that is not the Pi — by hand, or from
# launchd/cron:
#
#   scripts/pull-postgres-backups.sh                  # into ~/Backups/qibla-db
#   scripts/pull-postgres-backups.sh /Volumes/disk/qibla-db
#
# Only finished dumps are copied (the job renames `.partial` once complete), and
# nothing is ever deleted here: the Pi keeps 14 days, this side keeps everything.
#
# Restore one into an empty database:
#   pg_restore --no-owner -d "postgresql://qibla_app:…@host/qibla" qibla-2026-10-12-0330.dump
set -eu

HOST="${PI_HOST:-pi@192.168.1.42}"
SOURCE="/home/pi/backups/postgres/"
TARGET="${1:-$HOME/Backups/qibla-db}"

mkdir -p "$TARGET"
rsync -a --include='qibla-*.dump' --exclude='*' "$HOST:$SOURCE" "$TARGET/"
latest=$(ls -1t "$TARGET"/qibla-*.dump 2>/dev/null | head -1)
if [ -z "$latest" ]; then
  echo "No dump on $HOST yet." >&2
  exit 1
fi
echo "Latest: $latest ($(du -h "$latest" | cut -f1))"
