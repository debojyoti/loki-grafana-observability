#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env ]]; then
  echo "Missing .env." >&2
  exit 1
fi

# .env is an operator-controlled file. Quote values containing shell metacharacters.
set -a
# shellcheck disable=SC1091
source .env
set +a

curl_flags=(-fsS)
if [[ "${CURL_INSECURE:-0}" == "1" ]]; then
  curl_flags+=(-k)
fi

docker compose ps
docker compose exec -T caddy wget -qO- http://loki:3100/ready
docker compose exec -T caddy wget -qO- http://alloy:9999/ready
docker compose exec -T caddy wget -qO- http://grafana:3000/api/health
curl "${curl_flags[@]}" "https://${GRAFANA_DOMAIN}/api/health" >/dev/null

status="$(curl "${curl_flags[@]}" -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data '{"streams":[]}' \
  "https://${LOGS_DOMAIN}/loki/api/v1/push" || true)"
if [[ "$status" != "401" ]]; then
  echo "Expected unauthenticated ingestion to return 401; got $status." >&2
  exit 1
fi

for service_port in "loki 3100" "alloy 9999" "grafana 3000"; do
  read -r service port <<<"$service_port"
  if published="$(docker compose port "$service" "$port" 2>/dev/null)" && [[ -n "$published" ]]; then
    echo "$service:$port is unexpectedly published as $published" >&2
    exit 1
  fi
done

echo "Health checks passed; unauthenticated ingestion is rejected and internal ports are unpublished."

