# Shared bats helpers: puts the `docker` and `ssh` test doubles on PATH and
# gives each test its own call log and fake remote home directory.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup_stubs() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cp "$BATS_TEST_DIRNAME"/stubs/* "$bin/"
  chmod +x "$bin"/*
  export PATH="$bin:$PATH"

  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$STUB_LOG"

  export FAKE_REMOTE_HOME="$BATS_TEST_TMPDIR/remote-home"
  mkdir -p "$FAKE_REMOTE_HOME"
}

assert_called() {
  if ! grep -qF -- "$1" "$STUB_LOG"; then
    echo "expected a call containing: $1"
    echo "--- calls:"
    cat "$STUB_LOG"
    return 1
  fi
}

refute_called() {
  if grep -qF -- "$1" "$STUB_LOG"; then
    echo "unexpected call containing: $1"
    echo "--- calls:"
    cat "$STUB_LOG"
    return 1
  fi
}

assert_output_contains() {
  if [[ "$output" != *"$1"* ]]; then
    echo "expected output to contain: $1"
    echo "--- output:"
    echo "$output"
    return 1
  fi
}
