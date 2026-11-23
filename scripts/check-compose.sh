#!/usr/bin/env bash
# Checks for compose.yaml beyond schema validation:
#   - the file renders (`docker compose config`)
#   - no two services publish the same host port
#   - no two services mount the same data directory
set -euo pipefail

cd "$(dirname "$0")/.."

docker compose config --quiet
config_json="$(docker compose config --format json)"

failed=0

report_duplicates() {
  local label="$1" values="$2" dupes
  dupes="$(sort <<<"$values" | uniq -d)"
  if [[ -n "$dupes" ]]; then
    echo "error: duplicate ${label}:" >&2
    echo "$dupes" >&2
    failed=1
  fi
}

ports="$(jq -r '.services[].ports[]?.published' <<<"$config_json")"
data_dirs="$(jq -r '.services[].volumes[]? | select(.type == "bind") | .source' <<<"$config_json")"

report_duplicates "host ports" "$ports"
report_duplicates "data directories" "$data_dirs"

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
echo "compose.yaml OK"
