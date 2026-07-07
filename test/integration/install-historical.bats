#!/usr/bin/env bats
# Integration: historical patch install (php@8.1.27), which requires
# the git-history + contemporary-core-ref resolution path.
#
# Skipped unless ASDF_PHP_RUN_INTEGRATION=1. Also needs `gh` CLI
# authenticated (for the homebrew-core ref lookup).

load ../helpers

VERSION="8.1.27"

setup_file() {
  [[ "${ASDF_PHP_RUN_INTEGRATION:-0}" == "1" ]] \
    || skip "set ASDF_PHP_RUN_INTEGRATION=1 to run integration tests"
  command -v gh >/dev/null 2>&1 || skip "gh CLI required for historical installs"
  gh auth status >/dev/null 2>&1 || skip "gh not authenticated"

  export INSTALL="$HOME/.local/share/mise/installs/php/${VERSION}"

  mise uninstall -y "php@${VERSION}" >/dev/null 2>&1 || true
  mise install "php@${VERSION}" >&2 \
    || { echo "mise install php@${VERSION} failed"; return 1; }
}

@test "php@8.1.27 reports 8.1.27 (not the current-tap patch)" {
  run "$INSTALL/bin/php" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "PHP ${VERSION}"* ]] \
    || { echo "wrong version: $output"; false; }
}

@test "pdo_pgsql loads (libpq's openssl3 symbols resolve)" {
  # This is the historical-deps-ABI regression from earlier in
  # development. Contemporary homebrew-core resolution should have
  # picked a libpq built against the same openssl@3 the bottle
  # expects.
  run "$INSTALL/bin/php" -r 'exit(extension_loaded("pdo_pgsql") ? 0 : 1);'
  [ "$status" -eq 0 ]
}

@test "PDO(pgsql) can be constructed without dyld crashing" {
  run "$INSTALL/bin/php" -r '
    try {
      new PDO("pgsql:host=127.0.0.1;port=1;dbname=noop", "u", "p",
        [PDO::ATTR_TIMEOUT => 1]);
      echo "unexpected: connection succeeded";
    } catch (PDOException $e) {
      echo "pdo_exception_ok";
    }
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"pdo_exception_ok"* ]]
  [[ ! "$output" =~ "Symbol not found" ]]
}

@test "composer runs against 8.1.27" {
  # Raw phar shebang (`env php`) relies on the mise shim to resolve
  # `php`, which on a fresh runner has no pinned version. Route through
  # `mise exec` (same pattern as install-current) so this install's php
  # is picked deterministically.
  run mise exec "php@${VERSION}" -- "$INSTALL/bin/composer" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$VERSION"* ]]
}

@test "asdf-php-ext list works on this install" {
  run "$INSTALL/bin/asdf-php-ext" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"opcache"* ]]
}
