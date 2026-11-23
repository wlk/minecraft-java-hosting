#!/usr/bin/env bats
# Tests for scripts/upgrade.sh (docker is stubbed).

load helpers

setup() {
  setup_stubs
  export STUB_RUNNING="minecraft-przetrwanie pvp"
}

@test "stops, pulls, then starts all servers in that order" {
  run "$REPO_ROOT/scripts/upgrade.sh"

  [ "$status" -eq 0 ]
  run grep -oE 'compose (stop|pull|up -d --wait)' "$STUB_LOG"
  [ "$output" = $'compose stop\ncompose pull\ncompose up -d --wait' ]
}

@test "refuses to upgrade while players are online" {
  export STUB_PLAYERS=2

  run "$REPO_ROOT/scripts/upgrade.sh"

  [ "$status" -eq 1 ]
  assert_output_contains "pvp: 2 player(s) online"
  assert_output_contains "--force"
  refute_called "compose stop"
}

@test "--force upgrades even with players online" {
  export STUB_PLAYERS=2

  run "$REPO_ROOT/scripts/upgrade.sh" --force

  [ "$status" -eq 0 ]
  refute_called "rcon-cli"
  assert_called "compose pull"
}

@test "restarts servers on old images when pull fails" {
  export STUB_PULL_EXIT=1

  run "$REPO_ROOT/scripts/upgrade.sh"

  [ "$status" -eq 1 ]
  assert_called "compose up -d --wait"
  assert_output_contains "previous images"
}

@test "fails when servers do not become healthy" {
  export STUB_UP_EXIT=1

  run "$REPO_ROOT/scripts/upgrade.sh"

  [ "$status" -eq 1 ]
  assert_output_contains "did not all become healthy"
}

@test "passes the wait timeout to compose" {
  export WAIT_TIMEOUT_SECONDS=42

  run "$REPO_ROOT/scripts/upgrade.sh"

  [ "$status" -eq 0 ]
  assert_called "compose up -d --wait --wait-timeout 42"
}

@test "rejects unknown arguments" {
  run "$REPO_ROOT/scripts/upgrade.sh" --bogus

  [ "$status" -eq 1 ]
  assert_output_contains "usage:"
  refute_called "compose stop"
}
