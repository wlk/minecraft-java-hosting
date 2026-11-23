#!/usr/bin/env bash
# Deploy compose.yaml, scripts/ and systemd/ from this checkout to the Minecraft host.
# Run it on your machine; it needs ssh access to the host.
#
# Usage: scripts/deploy.sh [--dry-run] [--apply | --upgrade [--force]]
#   (no flags)  validate, show the compose.yaml diff, sync files; servers untouched
#   --dry-run   show what would change and stop
#   --apply     after syncing, `docker compose up -d` (recreates only changed servers)
#   --upgrade   after syncing, run scripts/upgrade.sh (stop all, pull images, start all)
#   --force     with --upgrade: proceed even when players are online
#
# Env (put local values in .env; direnv loads it via .envrc, see .env.example):
#   DEPLOY_HOST           ssh destination, e.g. user@host (required)
#   DEPLOY_DIR           repo directory on the host, relative to its home (default: minecraft-java-hosting)
#   WAIT_TIMEOUT_SECONDS  with --apply: how long to wait for healthy servers (default 1800)
#
# Files on the host other than those (e.g. a .env) are left alone.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly DEPLOY_HOST="${DEPLOY_HOST:-}"
readonly DEPLOY_DIR="${DEPLOY_DIR:-minecraft-java-hosting}"
readonly WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-1800}"
readonly SYNC_PATHS=(compose.yaml scripts systemd)

DRY_RUN=0
ACTION=sync  # sync | apply | upgrade
FORCE=0

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

set_action() {
  [[ "$ACTION" == sync ]] || die "--apply and --upgrade cannot be combined"
  ACTION="$1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --apply) set_action apply ;;
      --upgrade) set_action upgrade ;;
      --force) FORCE=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  [[ "$FORCE" -eq 0 || "$ACTION" == upgrade ]] || die "--force only applies to --upgrade"
}

# Runs a shell command inside the deploy directory on the host.
# The path is expanded and %q-quoted locally on purpose.
# shellcheck disable=SC2029
remote() {
  ssh "$DEPLOY_HOST" "cd $(printf '%q' "$DEPLOY_DIR") && $1"
}

warn_if_dirty() {
  if [[ -n "$(git status --porcelain -- "${SYNC_PATHS[@]}" 2>/dev/null)" ]]; then
    echo "warning: deploying uncommitted changes" >&2
  fi
}

show_compose_diff() {
  local current
  # shellcheck disable=SC2029 # path is expanded and %q-quoted locally on purpose
  current="$(ssh "$DEPLOY_HOST" "cat $(printf '%q' "$DEPLOY_DIR/compose.yaml") 2>/dev/null" || true)"
  echo "==> compose.yaml diff ($DEPLOY_HOST -> local)"
  if diff -u <(printf '%s\n' "$current") compose.yaml; then
    echo "(no changes)"
  fi
}

sync_files() {
  local flags=(-rlptz --delete --itemize-changes)
  if [[ "$DRY_RUN" -ne 0 ]]; then
    flags+=(--dry-run)
  fi
  echo "==> Syncing ${SYNC_PATHS[*]} to $DEPLOY_HOST:$DEPLOY_DIR/"
  rsync "${flags[@]}" "${SYNC_PATHS[@]}" "$DEPLOY_HOST:$DEPLOY_DIR/"
}

run_action() {
  case "$ACTION" in
    sync)
      echo "Synced. Running servers were not touched (use --apply or --upgrade)."
      ;;
    apply)
      echo "==> Applying compose.yaml"
      remote "docker compose up -d --wait --wait-timeout $WAIT_TIMEOUT_SECONDS && docker compose ps"
      ;;
    upgrade)
      echo "==> Upgrading servers"
      if [[ "$FORCE" -ne 0 ]]; then
        remote "scripts/upgrade.sh --force"
      else
        remote "scripts/upgrade.sh"
      fi
      ;;
  esac
}

main() {
  parse_args "$@"
  [[ -n "$DEPLOY_HOST" ]] ||
    die "DEPLOY_HOST is not set. Run: cp .env.example .env, set DEPLOY_HOST in .env, then \`direnv allow\`"

  echo "==> Validating compose.yaml locally"
  scripts/check-compose.sh
  ssh "$DEPLOY_HOST" true || die "cannot ssh to $DEPLOY_HOST"
  warn_if_dirty
  show_compose_diff
  sync_files

  if [[ "$DRY_RUN" -ne 0 ]]; then
    echo "Dry run: nothing changed. Would then: $ACTION."
    return 0
  fi

  echo "==> Validating compose.yaml on $DEPLOY_HOST"
  remote "docker compose config --quiet"
  run_action
}

main "$@"
