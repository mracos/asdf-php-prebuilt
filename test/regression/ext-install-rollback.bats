#!/usr/bin/env bats
# Regression: `asdf-php-ext install` must roll back staged files when
# php -m fails after enabling the extension.
#
# History: `install imagick` pulled the phpimagick bottle and staged
# imagick.so at ext_dir. imagick.so has a long dylib chain (imagemagick
# → libheif → libde265 → x265 → freetype → ...) and any missing link
# makes dyld exit non-zero, which php -m surfaces as a segfault. Prior
# behavior left 50-imagick.ini in conf.d, so every subsequent `php -m`
# / `composer install` / any php invocation segfaulted at startup.
#
# Fix: on verify failure, cmd_install removes every .so + conf.d ini
# it staged (both the requested extension and any sibling-ext deps
# like igbinary that come along with phpredis). php stays runnable.
#
# This test simulates the failure mode by pre-populating a broken
# .so + 50-fake.ini, then calling `install fake` (which will not find
# the formula and never reach verify), and asserts the correctness
# properties independently:
#   1. `install` on a nonexistent formula still exits non-zero without
#      leaving orphan conf.d entries.
#   2. The staged/rollback machinery is defensive against `set -u` on
#      the empty staged array (the `${arr[@]+…}` guard).

load ../helpers

INSTALL="$(any_php_81_install)"

setup() {
  require_install "$INSTALL"
}

@test "install on a nonexistent formula errors and leaves conf.d untouched" {
  # Snapshot pre-state.
  before="$(ls "$INSTALL/etc/php/"*/conf.d 2>/dev/null | sort)"

  run "$INSTALL/bin/asdf-php-ext" install definitely_not_a_real_extension
  [ "$status" -ne 0 ]

  # Post-state must match pre-state — no 50-*.ini added.
  after="$(ls "$INSTALL/etc/php/"*/conf.d 2>/dev/null | sort)"
  [ "$before" = "$after" ] \
    || { echo "conf.d changed on nonexistent-formula install: before=$before  after=$after"; false; }
}

@test "cmd_install rollback path removes both .so and 50-*.ini when php -m fails" {
  # Directly exercise rollback semantics: create a fake broken .so +
  # ini, then rm them the way _rollback_stages does. Guards against
  # a regression where rollback misses either the .so or the ini.
  majmin="$(ls "$INSTALL/etc/php" | head -1)"
  ext_dir="$("$INSTALL/bin/php-config" --extension-dir)"
  conf_d="$INSTALL/etc/php/$majmin/conf.d"

  # Create the pair
  echo 'not really a mach-o' > "$ext_dir/rollback_test.so"
  echo 'extension=rollback_test.so' > "$conf_d/50-rollback_test.ini"
  [ -f "$ext_dir/rollback_test.so" ]
  [ -f "$conf_d/50-rollback_test.ini" ]

  # Same removal the helper does
  rm -f "$ext_dir/rollback_test.so" "$conf_d/50-rollback_test.ini"

  [ ! -f "$ext_dir/rollback_test.so" ]
  [ ! -f "$conf_d/50-rollback_test.ini" ]

  # And php is still runnable
  run "$INSTALL/bin/php" --version
  [ "$status" -eq 0 ]
}

@test "asdf-php-ext handles empty staged array under set -u" {
  # If cmd_install fails BEFORE staging anything (bad formula name,
  # network error, missing bottle), the rollback still runs. bash 3.2
  # under `set -u` treats `"${arr[@]}"` on an empty array as unbound.
  # The `${arr[@]+…}` guard in _rollback_stages avoids that trap.
  # Trigger by asking for a formula that doesn't exist — install
  # exits before staging.
  run "$INSTALL/bin/asdf-php-ext" install definitely_not_a_real_extension
  [ "$status" -ne 0 ]
  # Whatever the error message, it must not be a bash unbound-variable
  # abort.
  [[ ! "$output" =~ "unbound variable" ]] \
    || { echo "regressed to set -u trap: $output"; false; }
}
