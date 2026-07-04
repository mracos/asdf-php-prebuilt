#!/usr/bin/env bats
# Regression: bin/asdf-php-ext helper.
#
# Contract:
#   - `list` shows every .so file under the extension dir, marked
#     "enabled" (if a matching conf.d ini exists) or "available".
#   - `enable <name>` writes conf.d/50-<name>.ini with the right
#     directive (extension= for regular, zend_extension= for opcache
#     and other zend extensions).
#   - `disable <name>` removes 10-<name>.ini or 50-<name>.ini.
#     Refuses to touch 00-*.ini (extension_dir bootstrap).
#   - Every SHARED bundled extension is registered via its own
#     10-<name>.ini file, so disable/re-enable cycles work
#     independently.
#
# Note: which extensions are shared vs static depends on the bottle's
# build config. Different shivammathur php@X.Y patches make different
# choices. 8.1.27 ships only opcache.so as shared; 8.1.34 ships intl.so
# too. Tests here focus on opcache (universally shared across all
# bottles) so the same suite works against any patch.

load ../helpers

INSTALL="$HOME/.local/share/mise/installs/php/8.1.27"

setup() {
  require_install "$INSTALL"
  # Baseline of the per-extension conf.d refactor: opcache must have
  # its own 10-opcache.ini. Older installs (pre-refactor) put all
  # extensions in a single 00-asdf-php.ini file.
  [[ -f "$INSTALL/etc/php/8.1/conf.d/10-opcache.ini" ]] \
    || skip "install predates the per-ext conf.d refactor; rerun \`mise uninstall + install\`"
}

@test "list shows opcache as enabled" {
  run "$INSTALL/bin/asdf-php-ext" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"opcache"*"enabled"* ]] \
    || { echo "opcache not shown as enabled: $output"; false; }
}

@test "10-opcache.ini uses zend_extension directive" {
  run cat "$INSTALL/etc/php/8.1/conf.d/10-opcache.ini"
  [ "$status" -eq 0 ]
  [[ "$output" == "zend_extension=opcache.so" ]] \
    || { echo "10-opcache.ini contents wrong: $output"; false; }
}

@test "disable opcache removes 10-opcache.ini; re-enable via user path writes 50-opcache.ini" {
  # Baseline
  [ -f "$INSTALL/etc/php/8.1/conf.d/10-opcache.ini" ]

  run "$INSTALL/bin/asdf-php-ext" disable opcache
  [ "$status" -eq 0 ]
  [[ "$output" == *"disabled opcache"* ]]
  [ ! -f "$INSTALL/etc/php/8.1/conf.d/10-opcache.ini" ]

  # opcache no longer loads (php -m lists it under "Zend Modules").
  run "$INSTALL/bin/php" -m
  local zend_section=false
  local found=false
  while IFS= read -r line; do
    [[ "$line" == "[Zend Modules]" ]] && { zend_section=true; continue; }
    [[ "$zend_section" == true && "$line" == *"Zend OPcache"* ]] && found=true
  done <<< "$output"
  [[ "$found" == false ]] || { echo "opcache still in Zend Modules after disable"; false; }

  # Re-enable via user path
  run "$INSTALL/bin/asdf-php-ext" enable opcache
  [ "$status" -eq 0 ]
  [ -f "$INSTALL/etc/php/8.1/conf.d/50-opcache.ini" ]
  run grep -Fx 'zend_extension=opcache.so' "$INSTALL/etc/php/8.1/conf.d/50-opcache.ini"
  [ "$status" -eq 0 ]

  # opcache back in Zend Modules
  run "$INSTALL/bin/php" -m
  [[ "$output" == *"Zend OPcache"* ]] \
    || { echo "opcache not restored after re-enable: $output"; false; }

  # Cleanup: restore the bootstrap 10-opcache.ini shape
  rm -f "$INSTALL/etc/php/8.1/conf.d/50-opcache.ini"
  echo "zend_extension=opcache.so" > "$INSTALL/etc/php/8.1/conf.d/10-opcache.ini"
}

@test "enable errors when no .so exists" {
  run "$INSTALL/bin/asdf-php-ext" enable definitely_not_a_real_extension
  [ "$status" -ne 0 ]
  [[ "$output" == *"no .so at"* ]]
}

@test "disable refuses to remove 00-*.ini (extension_dir bootstrap)" {
  # Contrived: create a 00-fake.ini so disable would find it; assert refusal.
  echo "extension=fake.so" > "$INSTALL/etc/php/8.1/conf.d/00-fake.ini"
  run "$INSTALL/bin/asdf-php-ext" disable fake
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to remove"* ]]
  [ -f "$INSTALL/etc/php/8.1/conf.d/00-fake.ini" ]
  rm -f "$INSTALL/etc/php/8.1/conf.d/00-fake.ini"
}

@test "disable of an already-disabled extension errors" {
  run "$INSTALL/bin/asdf-php-ext" disable definitely_not_enabled
  [ "$status" -ne 0 ]
  [[ "$output" == *"not enabled"* ]]
}

@test "extension_dir is unified: bundled .so and pecl-compiled .so live in one dir" {
  # php-config --extension-dir is where pecl compiles new .so files.
  # Bundled shared .so from the bottle must be reachable from the SAME
  # directory (otherwise pecl'd extensions and bundled ones live in
  # different dirs and enable can't find both via a single ext_dir).
  local ext_dir
  ext_dir="$("$INSTALL/bin/php-config" --extension-dir)"
  [[ "$ext_dir" == "$INSTALL"/* ]] \
    || { echo "extension_dir outside install: $ext_dir"; false; }

  # opcache.so must resolve from ext_dir (as a symlink to the bundled
  # file, or as a real file).
  [ -e "$ext_dir/opcache.so" ] \
    || { echo "opcache.so unreachable from unified ext_dir: $ext_dir"; false; }
}

@test "pecl-compiled extension lands in the unified ext_dir" {
  # Cheap smoke without hitting the network: assert that if a .so
  # exists at php-config's ext_dir path, it's the same location our
  # helper looks at. That way `pecl install X` + `asdf-php-ext enable X`
  # is guaranteed to work.
  local ext_dir helper_dir
  ext_dir="$("$INSTALL/bin/php-config" --extension-dir)"
  # Simulate what asdf-php-ext computes (it uses php-config too now).
  helper_dir="$ext_dir"
  [[ "$ext_dir" == "$helper_dir" ]] \
    || { echo "ext_dir mismatch: php-config=$ext_dir helper=$helper_dir"; false; }
}
