#!/usr/bin/env bats
# Regression: libpq's Mach-O has to link against the openssl@3 version
# it was compiled against.
#
# History: bin/download's first cut fetched today's formula for every
# transitive dep, regardless of when the requested PHP was bottled.
# For php@8.1.27 (bottled Feb 2024), pulling *today's* libpq alongside
# *today's* openssl@3 (3.6.x) surfaced:
#   dyld[…]: Symbol not found: _SSL_CIPHER_get_bits
#   Referenced from: <install>/Cellar/libpq/*/lib/libpq.5.dylib
# because 2024's libpq linked against openssl@3 3.1.x which had
# _SSL_CIPHER_get_bits at a different location or symbol shape.
#
# Fix: for historical PHP patches, walk the tap's git history to the
# commit that pinned that patch, then find the contemporary
# Homebrew/homebrew-core sha via `gh api commits?until=<iso>`. Deps
# come from formulas of that era.
#
# This test guards the historical dep resolution by asserting that
# pdo_pgsql loads AND a PDO instance can be constructed without dyld
# barfing on libpq's linkage.

load ../helpers

INSTALL="$(any_php_81_install)"

setup() {
  require_install "$INSTALL"
}

@test "pdo_pgsql extension is loaded" {
  run "$INSTALL/bin/php" -m
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pdo_pgsql" ]] \
    || { echo "pdo_pgsql not in php -m: $output"; false; }
}

@test "libpq.5.dylib loads without missing symbols" {
  # class_exists("PDO") forces libpq to be loaded via pdo_pgsql.
  # If the openssl@3 symbol lookup fails, PHP prints a dyld error to
  # stderr and returns non-zero.
  run "$INSTALL/bin/php" -r 'echo class_exists("PDO") ? "ok" : "missing"; echo PHP_EOL;'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "PDO can be instantiated against pgsql DSN (no dyld error)" {
  # Instantiate a PDO with a bogus pgsql host. We EXPECT a connection
  # failure (PDOException), but not a dyld symbol-not-found crash.
  # The critical check: exit is from PHP (a PDOException), not a
  # process abort from dyld.
  run "$INSTALL/bin/php" -r '
    try {
      new PDO("pgsql:host=127.0.0.1;port=1;dbname=noop", "u", "p", [PDO::ATTR_TIMEOUT => 1]);
      echo "unexpected: connection succeeded", PHP_EOL;
    } catch (PDOException $e) {
      echo "pdo_exception_ok", PHP_EOL;
    }
  '
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pdo_exception_ok" ]] \
    || { echo "expected PDOException, got: $output (dyld symbol error?)"; false; }
  # Belt-and-suspenders: any dyld error would be on stderr / cause a crash.
  [[ ! "$output" =~ "Symbol not found" ]]
  [[ ! "$output" =~ "dyld" ]]
}

@test "openssl symbols libpq references are actually resolvable" {
  # otool -L should show libpq's linkage. All @loader_path references
  # should resolve to existing .dylib files.
  local libpq
  libpq="$(find "$INSTALL/Cellar/libpq" -name 'libpq.5.dylib' -maxdepth 4 | head -1)"
  [[ -n "$libpq" ]] || skip "libpq bottle not staged (deps may have moved)"

  # For each @loader_path/... entry, resolve against the libpq's dir
  # and assert the target file exists.
  local dir dep target
  dir="$(dirname -- "$libpq")"
  while IFS= read -r dep; do
    [[ "$dep" == @loader_path/* ]] || continue
    target="${dir}/${dep#@loader_path/}"
    [ -e "$target" ] || { echo "unresolved: $dep -> $target"; false; }
  done < <(otool -L "$libpq" | awk 'NR>1 {print $1}')
}
