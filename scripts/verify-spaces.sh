#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env ]]; then
  echo "Missing .env." >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "AWS CLI is required for this check. Install awscli, then rerun this script." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

export AWS_ACCESS_KEY_ID="$DO_SPACES_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$DO_SPACES_SECRET_KEY"
export AWS_DEFAULT_REGION="$DO_SPACES_REGION"

object_count="$(aws --endpoint-url "https://${DO_SPACES_ENDPOINT}" \
  s3api list-objects-v2 \
  --bucket "$DO_SPACES_BUCKET" \
  --query 'length(Contents)' \
  --output text)"

if [[ "$object_count" == "None" || "$object_count" == "0" ]]; then
  echo "No Loki objects found in s3://${DO_SPACES_BUCKET}. Send logs and wait for Loki to flush chunks." >&2
  exit 1
fi

echo "Found $object_count Loki objects in s3://${DO_SPACES_BUCKET}."
aws --endpoint-url "https://${DO_SPACES_ENDPOINT}" \
  s3api list-objects-v2 \
  --bucket "$DO_SPACES_BUCKET" \
  --max-items 20 \
  --query 'Contents[].{Key:Key,Size:Size,Modified:LastModified}' \
  --output table

