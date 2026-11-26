#!/usr/bin/env bash
# Daily dumps of the database server (runs in the backup container of docker-compose.yml).
# At BACKUP_TIME (container time, UTC unless TZ is set): /backups/<date>/ with globals.sql (roles,
# pg_dumpall --globals-only) and <database>.dump (pg_dump -Fc) for every database. Written to
# <date>.tmp first and renamed only when every dump worked, so a folder is always complete.
# Folders older than BACKUP_KEEP_DAYS are deleted. Restore: pg_restore -d <database> <file>.dump
set -uo pipefail
at=${BACKUP_TIME:-02:30}; keep=${BACKUP_KEEP_DAYS:-14}

dump_all() { # target folder
  pg_dumpall --globals-only > "$1/globals.sql" || return 1
  local db
  for db in $(psql -d postgres -Atc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"); do
    pg_dump -Fc -d "$db" -f "$1/$db.dump" || return 1
  done
}

while true; do
  now=$(date +%s); next=$(date -d "today $at" +%s)
  [ "$next" -gt "$now" ] || next=$(date -d "tomorrow $at" +%s)
  sleep $((next - now))
  day=/backups/$(date +%F); rm -rf "$day.tmp"; mkdir -p "$day.tmp"
  if dump_all "$day.tmp"; then
    rm -rf "$day"; mv "$day.tmp" "$day"; echo "backup: $day ($(du -sh "$day" | cut -f1))"
  else
    echo "backup FAILED at $(date -Is); the previous backups are kept" >&2; rm -rf "$day.tmp"
  fi
  find /backups -mindepth 1 -maxdepth 1 -type d -name '20??-??-??' -mtime +"$keep" -exec rm -rf {} +
done
