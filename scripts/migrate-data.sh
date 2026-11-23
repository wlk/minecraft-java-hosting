#!/usr/bin/env bash
# One-off migration from the old per-server layout:
#   ~/<server>/docker-compose.yml
#   ~/<server>/data/
# to the single Compose project in this repo:
#   ~/minecraft-data/<server>/
#
# For each server it stops the old Compose stack (graceful, world is saved),
# verifies no container still uses the data, moves the data directory, and
# parks the old compose dir under ~/minecraft-legacy.
# Safe to re-run after an interruption: finished steps are skipped.
# It does NOT start the new stack; run `docker compose up -d` afterwards.
#
# Usage: scripts/migrate-data.sh [--dry-run]
set -euo pipefail

readonly SERVERS=(
  minecraft-przetrwanie
  minecraft-kreatywny
  coblemon-przetrwanie
  coblemon-kreatywny
  redstone
  pvp
)
# Old compose dirs with no data that are not part of the new project.
readonly OBSOLETE=(minecraft-sodium)

readonly OLD_ROOT="${OLD_ROOT:-$HOME}"
readonly DATA_ROOT="${DATA_ROOT:-$HOME/minecraft-data}"
readonly LEGACY_ROOT="${LEGACY_ROOT:-$HOME/minecraft-legacy}"
readonly STOP_TIMEOUT_SECONDS=60

DRY_RUN=0

die() {
  echo "error: $*" >&2
  exit 1
}

run() {
  echo "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

# Fail if any running container bind-mounts the given host path.
assert_not_mounted() {
  local path="$1" ids
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  ids="$(docker ps -q)"
  [[ -n "$ids" ]] || return 0
  # shellcheck disable=SC2086 # word splitting of container ids is intended
  if docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' $ids | grep -Fxq "$path"; then
    die "a running container still mounts $path; refusing to move it"
  fi
}

# Moving within one filesystem is an instant rename; across filesystems it is
# a slow copy+delete that can leave a half-moved world if interrupted.
assert_same_filesystem() {
  local src_dev dst_dev
  src_dev="$(stat -c %d "$OLD_ROOT")"
  dst_dev="$(stat -c %d "$(dirname "$DATA_ROOT")")"
  [[ "$src_dev" == "$dst_dev" ]] || die "$OLD_ROOT and $DATA_ROOT are on different filesystems"
}

# Each server must be in a state this script knows how to continue from.
preflight_server() {
  local name="$1" old_dir="$OLD_ROOT/$1" target="$DATA_ROOT/$1"
  if [[ -d "$old_dir/data" ]]; then
    [[ -f "$old_dir/docker-compose.yml" ]] || die "missing $old_dir/docker-compose.yml"
    [[ ! -e "$target" ]] || die "both $old_dir/data and $target exist; resolve manually"
    [[ ! -e "$LEGACY_ROOT/$name" ]] || die "legacy target already exists: $LEGACY_ROOT/$name"
  elif [[ ! -d "$target" ]]; then
    die "no data for $name in $old_dir/data or $target"
  fi
}

preflight() {
  command -v docker >/dev/null || die "docker not found"
  assert_same_filesystem
  local name
  for name in "${SERVERS[@]}"; do
    preflight_server "$name"
  done
  for name in "${OBSOLETE[@]}"; do
    [[ ! -e "$OLD_ROOT/$name/data" ]] || die "$OLD_ROOT/$name has data; handle it manually"
  done
}

stop_old_stack() {
  local old_dir="$1"
  if [[ -f "$old_dir/docker-compose.yml" ]]; then
    run docker compose -f "$old_dir/docker-compose.yml" down --timeout "$STOP_TIMEOUT_SECONDS"
  fi
}

archive_old_dir() {
  local name="$1"
  if [[ -d "$OLD_ROOT/$name" ]]; then
    run mv "$OLD_ROOT/$name" "$LEGACY_ROOT/$name"
  fi
}

migrate_server() {
  local name="$1" old_dir="$OLD_ROOT/$1"
  echo "==> $name"
  stop_old_stack "$old_dir"
  if [[ -d "$old_dir/data" ]]; then
    assert_not_mounted "$old_dir/data"
    run mv "$old_dir/data" "$DATA_ROOT/$name"
  else
    echo "    data already at $DATA_ROOT/$name"
  fi
  archive_old_dir "$name"
}

archive_obsolete() {
  local name
  for name in "${OBSOLETE[@]}"; do
    [[ -d "$OLD_ROOT/$name" ]] || continue
    echo "==> $name (obsolete, archiving)"
    stop_old_stack "$OLD_ROOT/$name"
    archive_old_dir "$name"
  done
}

main() {
  case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    *) die "usage: $0 [--dry-run]" ;;
  esac

  preflight
  run mkdir -p "$DATA_ROOT" "$LEGACY_ROOT"

  local name
  for name in "${SERVERS[@]}"; do
    migrate_server "$name"
  done
  archive_obsolete

  echo
  echo "Done. Start the new stack from the repo directory:"
  echo "  docker compose up -d && docker compose ps"
}

main "$@"
