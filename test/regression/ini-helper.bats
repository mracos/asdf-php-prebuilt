#!/usr/bin/env bats
# Regression: bin/asdf-php-ini helper.
#
# Contract:
#   - `list` prints "(no user settings)" when 99-asdf-php-user.ini
#     doesn't exist, else its contents.
#   - `set <key> <value>` writes/updates the entry in
#     conf.d/99-asdf-php-user.ini. Values with whitespace/;/#/" get
#     double-quoted.
#   - `get <key>` returns the EFFECTIVE ini value (via php ini_get,
#     routed through our wrapper).
#   - `unset <key>` removes the entry; errors if not set.
#   - Idempotent set: second set of the same key REPLACES, doesn't
#     duplicate.
#   - 99- prefix wins over 50- prefix (user override precedence).

load ../helpers

INSTALL="$(any_php_81_install)"
USER_INI="$INSTALL/etc/php/8.1/conf.d/99-asdf-php-user.ini"

setup() {
  require_install "$INSTALL"
  # Clean state per test.
  rm -f "$USER_INI"
}

teardown() {
  rm -f "$USER_INI"
}

@test "asdf-php-ini is present alongside php/composer" {
  [ -x "$INSTALL/bin/asdf-php-ini" ]
}

@test "list prints '(no user settings)' when the file doesn't exist" {
  run "$INSTALL/bin/asdf-php-ini" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no user settings"* ]] \
    || { echo "unexpected list output: $output"; false; }
}

@test "set writes 99-asdf-php-user.ini with unquoted simple value" {
  run "$INSTALL/bin/asdf-php-ini" set memory_limit 256M
  [ "$status" -eq 0 ]
  [ -f "$USER_INI" ]
  run grep -Fx 'memory_limit = 256M' "$USER_INI"
  [ "$status" -eq 0 ]
}

@test "set quotes a value that contains whitespace" {
  run "$INSTALL/bin/asdf-php-ini" set error_log "/tmp/php error.log"
  [ "$status" -eq 0 ]
  run grep -F 'error_log = "/tmp/php error.log"' "$USER_INI"
  [ "$status" -eq 0 ]
}

@test "set of the same key replaces the previous line (idempotent)" {
  "$INSTALL/bin/asdf-php-ini" set memory_limit 128M
  "$INSTALL/bin/asdf-php-ini" set memory_limit 512M

  run grep -c '^memory_limit' "$USER_INI"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ] \
    || { echo "expected 1 memory_limit line, got $output"; false; }

  run grep -Fx 'memory_limit = 512M' "$USER_INI"
  [ "$status" -eq 0 ]
}

@test "get returns the effective value via php ini_get" {
  "$INSTALL/bin/asdf-php-ini" set date.timezone UTC
  run "$INSTALL/bin/asdf-php-ini" get date.timezone
  [ "$status" -eq 0 ]
  [[ "$output" == "UTC" ]] \
    || { echo "get returned: $output"; false; }
}

@test "user 99-*.ini wins over 50-*.ini (precedence check)" {
  # Fake a 50-<name>.ini that sets memory_limit low; ours should win.
  echo 'memory_limit = 8M' > "$INSTALL/etc/php/8.1/conf.d/50-fake-memlimit.ini"
  "$INSTALL/bin/asdf-php-ini" set memory_limit 512M

  run "$INSTALL/bin/asdf-php-ini" get memory_limit
  [ "$status" -eq 0 ]
  [[ "$output" == "512M" ]] \
    || { echo "user override lost to 50-*: $output"; false; }

  rm -f "$INSTALL/etc/php/8.1/conf.d/50-fake-memlimit.ini"
}

@test "unset removes an entry" {
  "$INSTALL/bin/asdf-php-ini" set memory_limit 256M
  run "$INSTALL/bin/asdf-php-ini" unset memory_limit
  [ "$status" -eq 0 ]
  run grep -E '^memory_limit' "$USER_INI"
  [ "$status" -ne 0 ]
}

@test "unset of an unknown key errors" {
  run "$INSTALL/bin/asdf-php-ini" unset never_set_this
  [ "$status" -ne 0 ]
  [[ "$output" == *"not set"* ]]
}

@test "keys with dots are treated as single keys (not regex-glob)" {
  # opcache.enable and opcache.enabled should be independent lines.
  "$INSTALL/bin/asdf-php-ini" set opcache.enable 1
  "$INSTALL/bin/asdf-php-ini" set opcache.enabled 0

  run grep -c '^opcache' "$USER_INI"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]

  # Removing one doesn't remove the other.
  "$INSTALL/bin/asdf-php-ini" unset opcache.enable
  run grep -c '^opcache' "$USER_INI"
  [ "$output" -eq 1 ]
  run grep -Fx 'opcache.enabled = 0' "$USER_INI"
  [ "$status" -eq 0 ]
}
