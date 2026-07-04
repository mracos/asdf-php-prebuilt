#!/usr/bin/env bats
# Integration: `asdf-php-ext install <name>` end-to-end against a real
# extension from shivammathur/homebrew-extensions.
#
# Skipped unless ASDF_PHP_RUN_INTEGRATION=1. In CI this is the runner
# doing the verification that used to live in shell-history.
#
# Uses xdebug@8.1: no external C deps beyond libc, single .so, both
# extension= and zend_extension= (well, zend_extension=). Simplest
# possible tap-based install. Extensions with heavier dep chains
# (imagick, grpc) have their own limitations tracked in TODO.md.

load ../helpers

setup_file() {
  [[ "${ASDF_PHP_RUN_INTEGRATION:-0}" == "1" ]] \
    || skip "set ASDF_PHP_RUN_INTEGRATION=1 to run integration tests"

  export INSTALL
  INSTALL="$(any_php_81_install)"
  [[ -x "$INSTALL/bin/php" ]] \
    || skip "no php@8.1.x install to test against; run install-current first"
}

setup() {
  # Clean state per test.
  "$INSTALL/bin/asdf-php-ext" disable xdebug >/dev/null 2>&1 || true
  rm -f "$INSTALL"/opt/php@8.1/pecl/*/xdebug.so 2>/dev/null || true
  rm -rf "$INSTALL/Cellar/xdebug@8.1" 2>/dev/null || true
  rm -f  "$INSTALL/opt/xdebug@8.1" 2>/dev/null || true
}

teardown() {
  # Leave the install clean.
  "$INSTALL/bin/asdf-php-ext" disable xdebug >/dev/null 2>&1 || true
  rm -f "$INSTALL"/opt/php@8.1/pecl/*/xdebug.so 2>/dev/null || true
}

@test "asdf-php-ext install xdebug pulls the bottle and enables it" {
  run "$INSTALL/bin/asdf-php-ext" install xdebug
  [ "$status" -eq 0 ] \
    || { echo "install exited $status: $output"; false; }

  # The .so should exist at php-config's ext_dir now.
  local ext_dir
  ext_dir="$("$INSTALL/bin/php-config" --extension-dir)"
  [ -f "$ext_dir/xdebug.so" ] \
    || { echo "xdebug.so not at $ext_dir after install"; false; }

  # The conf.d entry should exist.
  [ -f "$INSTALL/etc/php/8.1/conf.d/50-xdebug.ini" ] \
    || { echo "no 50-xdebug.ini after install"; false; }

  # xdebug is a Zend extension.
  run grep -Fx 'zend_extension=xdebug.so' \
    "$INSTALL/etc/php/8.1/conf.d/50-xdebug.ini"
  [ "$status" -eq 0 ] \
    || { echo "50-xdebug.ini uses wrong directive"; false; }
}

@test "php -m lists xdebug after install (dylibs resolved)" {
  "$INSTALL/bin/asdf-php-ext" install xdebug \
    || skip "install prereq failed; see previous test"

  run "$INSTALL/bin/php" -m
  [ "$status" -eq 0 ]
  # xdebug appears under [Zend Modules] on newer bottles or as `xdebug`
  # in the main list on older ones. Accept either.
  [[ "$output" == *"xdebug"* || "$output" == *"Xdebug"* ]] \
    || { echo "xdebug not in php -m output"; false; }
}

@test "install refuses on a non-existent extension name" {
  run "$INSTALL/bin/asdf-php-ext" install definitely_not_a_real_ext
  [ "$status" -ne 0 ]
  [[ "$output" == *"no ext formula"* ]]
}

@test "install then disable removes conf.d entry; php -m no longer lists it" {
  "$INSTALL/bin/asdf-php-ext" install xdebug \
    || skip "install prereq failed"

  run "$INSTALL/bin/asdf-php-ext" disable xdebug
  [ "$status" -eq 0 ]
  [ ! -f "$INSTALL/etc/php/8.1/conf.d/50-xdebug.ini" ]

  run "$INSTALL/bin/php" -m
  [ "$status" -eq 0 ]
  # xdebug should be gone from the Zend Modules section. Grep for the
  # exact tokens to avoid matching another string that contains xdebug.
  local zend_section=0 found=0
  while IFS= read -r line; do
    [[ "$line" == "[Zend Modules]" ]] && { zend_section=1; continue; }
    [[ "$zend_section" == 1 && "$line" =~ [Xx]debug ]] && found=1
  done <<< "$output"
  [[ "$found" == 0 ]] || { echo "xdebug still in Zend Modules after disable"; false; }
}
