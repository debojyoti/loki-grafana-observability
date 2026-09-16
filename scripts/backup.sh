#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

backup_dir="${BACKUP_DIR:-$PWD/backups}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"

grafana_container="$(docker compose ps -q grafana)"
caddy_container="$(docker compose ps -q caddy)"
if [[ -z "$grafana_container" || -z "$caddy_container" ]]; then
  echo "Grafana and Caddy containers must exist before backup." >&2
  exit 1
fi

grafana_volume="$(docker inspect "$grafana_container" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/grafana"}}{{.Name}}{{end}}{{end}}')"
caddy_data_volume="$(docker inspect "$caddy_container" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')"

restart_grafana=0
cleanup() {
  if [[ "$restart_grafana" == "1" ]]; then
    docker compose start grafana >/dev/null
  fi
}
trap cleanup EXIT

docker compose stop grafana >/dev/null
restart_grafana=1

docker run --rm \
  -v "${grafana_volume}:/state/grafana:ro" \
  -v "${caddy_data_volume}:/state/caddy:ro" \
  -v "${backup_dir}:/backup" \
  alpine:3.22.1 \
  tar -C /state -czf "/backup/production-logging-state-${timestamp}.tar.gz" grafana caddy

tar --exclude=.env --exclude=.git --exclude=backups \
  -czf "${backup_dir}/production-logging-config-${timestamp}.tar.gz" .
chmod 600 "${backup_dir}"/*.tar.gz

docker compose start grafana >/dev/null
restart_grafana=0

echo "Backup written to $backup_dir. Loki object data was intentionally not copied from the Droplet."

