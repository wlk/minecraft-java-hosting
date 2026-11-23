#!/usr/bin/env bats
# Tests for scripts/deploy.sh. `ssh` is stubbed to run "remote" commands in a
# temp dir, so rsync and scripts/upgrade.sh run for real; `docker` is stubbed.

load helpers

setup() {
  setup_stubs
  export DEPLOY_HOST=testhost
  REMOTE_DIR="$FAKE_REMOTE_HOME/minecraft-java-hosting"
}

@test "syncs files without touching servers" {
  mkdir -p "$REMOTE_DIR/scripts"
  echo "DATA_ROOT=/srv" >"$REMOTE_DIR/.env"
  echo "old" >"$REMOTE_DIR/scripts/removed.sh"

  run "$REPO_ROOT/scripts/deploy.sh"

  [ "$status" -eq 0 ]
  cmp "$REPO_ROOT/compose.yaml" "$REMOTE_DIR/compose.yaml"
  [ -x "$REMOTE_DIR/scripts/upgrade.sh" ]
  [ -f "$REMOTE_DIR/systemd/minecraft@.service" ]
  [ "$(cat "$REMOTE_DIR/.env")" = "DATA_ROOT=/srv" ]
  [ ! -e "$REMOTE_DIR/scripts/removed.sh" ]
  assert_called "&& docker compose config --quiet"
  refute_called "compose up"
  refute_called "compose stop"
}

@test "--dry-run shows the diff and changes nothing" {
  mkdir -p "$REMOTE_DIR"
  echo "name: old" >"$REMOTE_DIR/compose.yaml"

  run "$REPO_ROOT/scripts/deploy.sh" --dry-run

  [ "$status" -eq 0 ]
  assert_output_contains "-name: old"
  assert_output_contains "+name: minecraft"
  [ "$(cat "$REMOTE_DIR/compose.yaml")" = "name: old" ]
  [ ! -e "$REMOTE_DIR/scripts" ]
  refute_called "&& docker"
}

@test "--apply runs compose up on the host" {
  run "$REPO_ROOT/scripts/deploy.sh" --apply

  [ "$status" -eq 0 ]
  assert_called "&& docker compose up -d --wait"
}

@test "--upgrade runs the upgrade script on the host" {
  run "$REPO_ROOT/scripts/deploy.sh" --upgrade

  [ "$status" -eq 0 ]
  assert_called "&& scripts/upgrade.sh"
  assert_called "docker compose pull"
}

@test "--upgrade stops when players are online unless --force" {
  export STUB_RUNNING=pvp STUB_PLAYERS=1

  run "$REPO_ROOT/scripts/deploy.sh" --upgrade
  [ "$status" -ne 0 ]
  assert_output_contains "players are online"
  refute_called "compose pull"

  run "$REPO_ROOT/scripts/deploy.sh" --upgrade --force
  [ "$status" -eq 0 ]
  assert_called "&& scripts/upgrade.sh --force"
  assert_called "compose pull"
}

@test "fails clearly when the host is unreachable" {
  export STUB_UNREACHABLE=1

  run "$REPO_ROOT/scripts/deploy.sh"

  [ "$status" -eq 1 ]
  assert_output_contains "cannot ssh to testhost"
}

@test "fails with setup instructions when DEPLOY_HOST is unset" {
  unset DEPLOY_HOST

  run "$REPO_ROOT/scripts/deploy.sh"

  [ "$status" -eq 1 ]
  assert_output_contains "DEPLOY_HOST is not set"
  assert_output_contains ".env.example"
  refute_called "ssh"
}

@test "rejects invalid flag combinations" {
  run "$REPO_ROOT/scripts/deploy.sh" --force
  [ "$status" -eq 1 ]
  assert_output_contains "--force only applies to --upgrade"

  run "$REPO_ROOT/scripts/deploy.sh" --apply --upgrade
  [ "$status" -eq 1 ]
  assert_output_contains "cannot be combined"

  run "$REPO_ROOT/scripts/deploy.sh" --bogus
  [ "$status" -eq 1 ]
  assert_output_contains "unknown option"
}

@test "--help prints usage" {
  run "$REPO_ROOT/scripts/deploy.sh" --help

  [ "$status" -eq 0 ]
  assert_output_contains "Usage: scripts/deploy.sh"
  refute_called "ssh"
}
