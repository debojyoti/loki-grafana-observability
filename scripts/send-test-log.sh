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

timestamp_ns="$(date +%s)000000000"
payload="$(cat <<JSON
{
  "streams": [
    {
      "stream": {"client":"internal","project":"logging-test","service":"api","environment":"production"},
      "values": [["${timestamp_ns}", "{\"level\":\"info\",\"message\":\"Centralized logging test successful\",\"requestId\":\"acceptance-internal\"}"]]
    },
    {
      "stream": {"client":"client-a","project":"project-a","service":"api","environment":"production"},
      "values": [["${timestamp_ns}", "{\"level\":\"info\",\"message\":\"Multi-project acceptance test\",\"requestId\":\"acceptance-a-api\"}"]]
    },
    {
      "stream": {"client":"client-a","project":"project-a","service":"worker","environment":"production"},
      "values": [["${timestamp_ns}", "{\"level\":\"warn\",\"message\":\"Multi-project worker acceptance test\",\"requestId\":\"acceptance-a-worker\"}"]]
    },
    {
      "stream": {"client":"client-b","project":"project-b","service":"api","environment":"production"},
      "values": [["${timestamp_ns}", "{\"level\":\"error\",\"message\":\"Multi-project error acceptance test\",\"requestId\":\"acceptance-b-api\"}"]]
    },
    {
      "stream": {"client":"client-b","project":"project-b","service":"api","environment":"staging"},
      "values": [["${timestamp_ns}", "{\"level\":\"info\",\"message\":\"Multi-project staging acceptance test\",\"requestId\":\"acceptance-b-staging\"}"]]
    }
  ]
}
JSON
)"

curl_flags=(-fsS)
if [[ "${CURL_INSECURE:-0}" == "1" ]]; then
  curl_flags+=(-k)
fi

curl "${curl_flags[@]}" \
  --user "${LOG_INGEST_USERNAME}:${LOG_INGEST_PASSWORD}" \
  -H 'Content-Type: application/json' \
  --data-binary "$payload" \
  "https://${LOGS_DOMAIN}/loki/api/v1/push"

echo "Sent five test streams. Query {client=~\"client-a|client-b|internal\"} in Grafana Explore."

