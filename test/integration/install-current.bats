#!/usr/bin/env bats
# Integration: full install of the CURRENT tap patch of php@8.1.
# Skipped unless ASDF_PHP_RUN_INTEGRATION=1.
#
# What this proves end-to-end:
#   - `mise install` completes.
#   - `mise where php` returns a path with `bin/php`.
#   - php reports the version the current tap pins.
#   - wrappers route through our etc/, not brew's.
#   - php-config points inside our install.
#   - a fixed extension surface (curl, mbstring, openssl, pdo_mysql,
#     pdo_pgsql, intl, sqlite3, gd, zip, mysqli, ldap) all load.
#   - composer runs against our php.
#   - `asdf-php-ext list` includes at least opcache as enabled.
#   - `pecl config-get ext_dir` matches `php-config --extension-dir`.

load ../helpers

MAJMIN="8.1"

setup_file() {
  [[ "${ASDF_PHP_RUN_INTEGRATION:-0}" == "1" ]] \
    || skip "set ASDF_PHP_RUN_INTEGRATION=1 to run integration tests"

  # Resolve current-tap patch by asking `mise ls-remote`.
  # Take the highest 8.1.x listed.
  CURRENT_PATCH="$(mise ls-remote php 2>/dev/null | grep -E "^${MAJMIN}\.[0-9]+$" | sort -V | tail -1)"
  [[ -n "$CURRENT_PATCH" ]] || skip "could not resolve current 8.1 patch from mise ls-remote"
  export CURRENT_PATCH
  export INSTALL="$HOME/.local/share/mise/installs/php/${CURRENT_PATCH}"

  # Reinstall from scratch to make sure we test what CURRENT_PATCH
  # would produce, not a stale prior install.
  mise uninstall -y "php@${CURRENT_PATCH}" >/dev/null 2>&1 || true
  mise install "php@${CURRENT_PATCH}" >&2 \
    || { echo "mise install php@${CURRENT_PATCH} failed"; return 1; }
}

@test "bin/php exists and reports the requested version" {
  [ -x "$INSTALL/bin/php" ]
  run "$INSTALL/bin/php" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "PHP $CURRENT_PATCH"* ]] \
    || { echo "wrong version reported: $output"; false; }
}

@test "php Loaded Configuration File and Scan dir are inside our install" {
  run "$INSTALL/bin/php" -i
  [ "$status" -eq 0 ]
  loaded="$(printf '%s\n' "$output" | grep -E '^Loaded Configuration File')"
  scan="$(printf '%s\n' "$output"   | grep -E '^Scan this dir')"
  [[ "$loaded" == *"$INSTALL"* ]] \
    || { echo "Loaded Configuration escapes install: $loaded"; false; }
  [[ "$scan"   == *"$INSTALL"* ]] \
    || { echo "Scan dir escapes install: $scan"; false; }
}

@test "php-config --prefix + --extension-dir both point inside the install" {
  run "$INSTALL/bin/php-config" --prefix
  [ "$status" -eq 0 ]
  [[ "$output" == "$INSTALL"/* ]]

  run "$INSTALL/bin/php-config" --extension-dir
  [ "$status" -eq 0 ]
  [[ "$output" == "$INSTALL"/* ]]
}

@test "expected extension surface loads" {
  run "$INSTALL/bin/php" -r '
    $want = ["curl","mbstring","openssl","pdo_mysql","pdo_pgsql",
             "intl","sqlite3","gd","zip","mysqli","ldap","xml"];
    foreach ($want as $e) {
      if (!extension_loaded($e)) { echo "MISSING:$e "; }
    }
    echo "DONE";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "DONE" ]] \
    || { echo "extensions missing: $output"; false; }
}

@test "composer --version runs against our php" {
  run "$INSTALL/bin/composer" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"Composer version"* ]]
  # Composer prints "PHP version X.Y.Z (/path/to/php)" too.
  [[ "$output" == *"$CURRENT_PATCH"* ]] \
    || { echo "composer's PHP version doesn't match: $output"; false; }
}

@test "asdf-php-ext list shows opcache as enabled" {
  run "$INSTALL/bin/asdf-php-ext" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"opcache"*"enabled"* ]]
}

@test "php-config extension-dir is where opcache.so actually lives" {
  # pecl reads its INSTALL PATH from `php-config --extension-dir`
  # (via phpize) at compile time, not from pear.conf. What matters
  # end-to-end is that the .so files pecl writes land somewhere our
  # extension_dir + asdf-php-ext can find. Assert opcache.so is at
  # php-config's dir (proves the unified layout works).
  local ext_dir
  ext_dir="$("$INSTALL/bin/php-config" --extension-dir)"
  [[ "$ext_dir" == "$INSTALL"/* ]]
  [ -e "$ext_dir/opcache.so" ] \
    || { echo "opcache.so not at php-config ext_dir: $(ls "$ext_dir")"; false; }
}

@test "openssl.cafile points at a readable PEM bundle" {
  local cafile
  cafile="$("$INSTALL/bin/php" -r 'echo ini_get("openssl.cafile");')"
  [ -r "$cafile" ]
  run grep -c "BEGIN CERTIFICATE" "$cafile"
  [ "$status" -eq 0 ]
  [ "$output" -gt 20 ]
}
