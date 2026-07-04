#!/usr/bin/env bash
# Shared bats helpers for asdf-php tests.

# Repo root, computed from this file's location.
export PLUGIN_DIR="${PLUGIN_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# Fixtures under test/fixtures/
export FIXTURES_DIR="$PLUGIN_DIR/test/fixtures"

# Load a lib file into the current test's shell scope.
load_lib() {
  local name="$1"
  # shellcheck source=/dev/null
  source "$PLUGIN_DIR/lib/${name}.bash"
}

# Skip the current test unless a real PHP install exists at the given path.
# For regression tests that install by hand and don't want to reinstall
# every run.
require_install() {
  local path="$1"
  [[ -x "$path/bin/php" ]] || skip "no install at $path (run `mise install php@<version>`)"
}

# Resolve INSTALL to whatever real 8.1.x is currently installed under
# mise. Tests set INSTALL="$(any_php_81_install)" then require_install.
#
# mise creates symlinks like `<installs>/php/8.1 → 8.1.34` alongside
# the real dirs; the glob catches both, so skip symlinks explicitly
# to land on the real versioned install.
any_php_81_install() {
  local d
  for d in "$HOME/.local/share/mise/installs/php/8.1"*; do
    [[ -L "$d" ]] && continue          # skip mise's convenience symlinks
    [[ -x "$d/bin/php" ]] || continue
    echo "$d"
    return 0
  done
  echo "$HOME/.local/share/mise/installs/php/8.1.NONE"
}

# Skip if we don't have network access — some tests hit the tap or GHCR.
require_network() {
  curl -fsSL --max-time 3 -o /dev/null https://raw.githubusercontent.com >/dev/null 2>&1 \
    || skip "network unreachable"
}

# Skip if `gh` isn't authenticated — needed for historical installs.
require_gh_auth() {
  command -v gh >/dev/null 2>&1 || skip "gh CLI not on PATH"
  gh auth status >/dev/null 2>&1 || skip "gh not authenticated (\`gh auth login\`)"
}
