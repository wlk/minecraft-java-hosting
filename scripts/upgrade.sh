#!/usr/bin/env bash
# Upgrade all Minecraft servers: stop them, pull newer images, start them again.
#
# Run on the host from the repo directory, or from your machine with
# `scripts/deploy.sh --upgrade`.
#
# Servers without a pinned VERSION also fetch the newest Minecraft release when
# they start. Servers with a pinned VERSION (the Cobblemon ones) keep it.
#
# Usage: scripts/upgrade.sh [--force]
#   --force  upgrade even when players are online
#
# Env:
#   WAIT_TIMEOUT_SECONDS  how long to wait for servers to report healthy (default 1800)
set -euo pipefail

cd "$(dirname "$0")/.."

readonly WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-1800}"

die() {
  echo "error: $*" >&2
  exit 1
}

# Prints "<service>: <n> player(s) online" for each running server with players.
# Servers that do not answer RCON (e.g. still starting) are skipped.
players_online() {
  local service output count
  while read -r service; do
    [[ -n "$service" ]] || continue
    output="$(docker compose exec -T "$service" rcon-cli list </dev/null 2>/dev/null || true)"
    count="$(sed -n 's/^There are \([0-9][0-9]*\) of.*/\1/p' <<<"$output")"
    if [[ -n "$count" && "$count" -gt 0 ]]; then
      echo "$service: $count player(s) online"
    fi
  done < <(docker compose ps --services --status running)
}

refuse_if_players_online() {
  local online
  online="$(players_online)"
  if [[ -n "$online" ]]; then
    echo "$online" >&2
    die "players are online; re-run with --force to upgrade anyway"
  fi
}

main() {
  local force=0
  case "${1:-}" in
    "") ;;
    --force) force=1 ;;
    *) die "usage: $0 [--force]" ;;
  esac

  if [[ "$force" -eq 0 ]]; then
    refuse_if_players_online
  fi

  echo "==> Stopping servers"
  docker compose stop

  echo "==> Pulling images"
  local pull_failed=0
  docker compose pull || pull_failed=1

  echo "==> Starting servers (waiting up to ${WAIT_TIMEOUT_SECONDS}s for healthy)"
  if ! docker compose up -d --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS"; then
    docker compose ps
    die "servers did not all become healthy; check \`docker compose logs\`"
  fi
  docker compose ps

  if [[ "$pull_failed" -ne 0 ]]; then
    die "image pull failed; servers were restarted on their previous images"
  fi
  echo "Upgrade complete."
}

main "$@"
