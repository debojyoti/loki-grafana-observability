#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example to .env and fill in production values." >&2
  exit 1
fi

chmod 600 .env

compose_environment="$(docker compose --env-file .env config --environment)"

env_value() {
  local key="$1"
  awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' <<<"$compose_environment"
}

required=(
  LOGS_DOMAIN
  GRAFANA_DOMAIN
  GRAFANA_ADMIN_USER
  GRAFANA_ADMIN_PASSWORD
  GRAFANA_SECRET_KEY
  DO_SPACES_REGION
  DO_SPACES_ENDPOINT
  DO_SPACES_BUCKET
  DO_SPACES_ACCESS_KEY
  DO_SPACES_SECRET_KEY
  LOG_INGEST_USERNAME
  LOG_INGEST_PASSWORD
)

for key in "${required[@]}"; do
  value="$(env_value "$key")"
  if [[ -z "$value" || "$value" == change-me* ]]; then
    echo "Set a non-placeholder value for $key in .env." >&2
    exit 1
  fi
done

password_hash="$(env_value LOG_INGEST_PASSWORD_HASH)"
if [[ -z "$password_hash" || "$password_hash" == replace-with-* ]]; then
  echo "Generating the Caddy bcrypt hash for the ingestion password..."
  docker pull caddy:2.11.3-alpine >/dev/null
  ingest_password="$(env_value LOG_INGEST_PASSWORD)"
  password_hash="$(printf '%s\n' "$ingest_password" | docker run --rm -i caddy:2.11.3-alpine caddy hash-password)"
  unset ingest_password

  temp_env="$(mktemp .env.XXXXXX)"
  replacement="LOG_INGEST_PASSWORD_HASH='${password_hash}'"
  awk -v replacement="$replacement" '
    BEGIN { replaced = 0 }
    /^LOG_INGEST_PASSWORD_HASH=/ { print replacement; replaced = 1; next }
    { print }
    END { if (!replaced) print replacement }
  ' .env >"$temp_env"
  chmod 600 "$temp_env"
  mv "$temp_env" .env
  echo "Stored LOG_INGEST_PASSWORD_HASH in .env (mode 600)."
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git rev-parse '@{upstream}' >/dev/null 2>&1; then
  git pull --ff-only
fi

docker compose --env-file .env pull
docker compose --env-file .env config --quiet
docker compose --env-file .env up -d --wait
docker compose --env-file .env ps

echo "Deployment is healthy. Run scripts/send-test-log.sh, then scripts/verify-spaces.sh."
