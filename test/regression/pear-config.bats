#!/usr/bin/env bats
# Regression: pecl/pear must not read the wrapper's `-c` arg as PEAR's
# config file path.
#
# History: the initial wrapper passed `-c <install>/etc/php/<majmin>` to
# every binary under bin/. For php that means "look for php.ini here",
# but pecl / pear are shell scripts that forward args to peclcmd.php,
# which parses `-c <path>` as PEAR's config-file path. When <path> was
# a directory, PEAR erred out with:
#   "<install>/etc/php/8.1/ is not a valid config file or is corrupted."
# Fix: wrapper uses PHPRC + PHP_INI_SCAN_DIR env vars instead of -c.
# This test guards against a regression.

load ../helpers

INSTALL="$HOME/.local/share/mise/installs/php/8.1.27"

setup() {
  require_install "$INSTALL"
}

@test "pecl version runs without 'is not a valid config file' error" {
  run "$INSTALL/bin/pecl" version
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "is not a valid config file" ]] \
    || { echo "unexpected PEAR config error: $output"; false; }
  [[ "$output" =~ "PEAR Version" ]] \
    || { echo "expected 'PEAR Version' in output, got: $output"; false; }
}

@test "pecl config-show returns a serialized config, not an error" {
  run "$INSTALL/bin/pecl" config-show
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "is not a valid config file" ]]
  # config-show emits key/value rows; look for the standard 'php_bin' one.
  [[ "$output" =~ "php_bin" ]]
}

@test "wrapper for pecl doesn't pass -c as a positional arg" {
  run cat "$INSTALL/bin/pecl"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PHPRC=" ]] \
    || { echo "wrapper missing PHPRC export: $output"; false; }
  [[ ! "$output" =~ 'exec "$prefix/opt/php@'*'/bin/pecl" -c' ]] \
    || { echo "wrapper still passes -c to pecl (regression): $output"; false; }
}

@test "php reads OUR php.ini (via PHPRC), not the host's brew one" {
  # `php -i | grep 'Loaded Configuration'` should point at our install prefix.
  run "$INSTALL/bin/php" -i
  [ "$status" -eq 0 ]
  loaded_line=$(printf '%s\n' "$output" | grep -E '^Loaded Configuration File')
  [[ "$loaded_line" == *"$INSTALL"* ]] \
    || { echo "PHP loading foreign ini: $loaded_line"; false; }
}
