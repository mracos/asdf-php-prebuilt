#!/usr/bin/env bats
# Integration: full pecl-install + asdf-php-ext-enable flow against
# an active PHP install. Uses `redis` because it's a pure PHP
# extension (no external C deps like imagick's imagemagick).
#
# Skipped unless ASDF_PHP_RUN_INTEGRATION=1.

load ../helpers

setup_file() {
  [[ "${ASDF_PHP_RUN_INTEGRATION:-0}" == "1" ]] \
    || skip "set ASDF_PHP_RUN_INTEGRATION=1 to run integration tests"

  # Pick whichever 8.1 install is already active.
  export INSTALL
  INSTALL="$(mise where php@8.1 2>/dev/null)"
  if [[ ! -x "$INSTALL/bin/php" ]]; then
    # Fall back to any installed 8.1.x.
    for d in "$HOME/.local/share/mise/installs/php/8.1"*; do
      [[ -x "$d/bin/php" ]] && { INSTALL="$d"; break; }
    done
  fi
  [[ -x "$INSTALL/bin/php" ]] \
    || skip "no php@8.1.x install to test against; run install-current first"
}

setup() {
  # Uninstall + clean up if a prior run left redis around.
  "$INSTALL/bin/pecl" uninstall redis >/dev/null 2>&1 || true
  rm -f "$INSTALL/etc/php/8.1/conf.d/50-redis.ini" 2>/dev/null || true
  rm -f "$INSTALL/opt/php@8.1/pecl/"*/redis.so 2>/dev/null || true
}

teardown() {
  # Leave the install clean between test files.
  "$INSTALL/bin/pecl" uninstall redis >/dev/null 2>&1 || true
  rm -f "$INSTALL/etc/php/8.1/conf.d/50-redis.ini" 2>/dev/null || true
  rm -f "$INSTALL/opt/php@8.1/pecl/"*/redis.so 2>/dev/null || true
}

@test "pecl install redis compiles the .so into the unified ext_dir" {
  # This proves the whole PEAR-config-in-our-install chain works:
  # pecl reads our pear.conf, ext_dir points at pecl/<api>/, compiler
  # emits redis.so there.
  run "$INSTALL/bin/pecl" install --force redis
  [ "$status" -eq 0 ] \
    || { echo "pecl install failed: $output"; false; }

  # The .so should now be at php-config's extension_dir.
  local ext_dir
  ext_dir="$("$INSTALL/bin/php-config" --extension-dir)"
  [ -f "$ext_dir/redis.so" ] \
    || { echo "redis.so not at $ext_dir: $(ls "$ext_dir")"; false; }
}

@test "asdf-php-ext enable redis writes conf.d/50-redis.ini + redis loads" {
  # Prereq: .so present from previous test's pecl install.
  "$INSTALL/bin/pecl" install --force redis >/dev/null 2>&1

  run "$INSTALL/bin/asdf-php-ext" enable redis
  [ "$status" -eq 0 ]
  [ -f "$INSTALL/etc/php/8.1/conf.d/50-redis.ini" ]
  run grep -Fx 'extension=redis.so' "$INSTALL/etc/php/8.1/conf.d/50-redis.ini"
  [ "$status" -eq 0 ]

  run "$INSTALL/bin/php" -r 'exit(extension_loaded("redis") ? 0 : 1);'
  [ "$status" -eq 0 ] \
    || { echo "redis didn't load after enable"; false; }
}

@test "asdf-php-ext disable redis removes conf.d entry; extension gone" {
  "$INSTALL/bin/pecl" install --force redis >/dev/null 2>&1
  "$INSTALL/bin/asdf-php-ext" enable redis >/dev/null 2>&1

  run "$INSTALL/bin/asdf-php-ext" disable redis
  [ "$status" -eq 0 ]
  [ ! -f "$INSTALL/etc/php/8.1/conf.d/50-redis.ini" ]

  run "$INSTALL/bin/php" -r 'exit(extension_loaded("redis") ? 1 : 0);'
  [ "$status" -eq 0 ] \
    || { echo "redis still loaded after disable"; false; }
}
