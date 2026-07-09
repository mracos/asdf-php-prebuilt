#!/usr/bin/env bats
# Integration: install whatever the tap currently ships as the highest
# PHP patch overall (regardless of major/minor). Different from
# install-current.bats which pins to 8.1.x.
#
# Purpose: catches formula-format drift on newer bottles that 8.1
# wouldn't. If shivammathur ships a new PHP major.minor and the tap's
# bottle shape changes (extra `cellar:` qualifiers, new dep-graph
# shapes), this test breaks before the ecosystem-wide default does.
#
# Skipped unless ASDF_PHP_RUN_INTEGRATION=1.

load ../helpers

setup_file() {
  [[ "${ASDF_PHP_RUN_INTEGRATION:-0}" == "1" ]] \
    || skip "set ASDF_PHP_RUN_INTEGRATION=1 to run integration tests"

  # Highest stable version listed. Tap may ship pre-release patches
  # (`8.6.0-dev` etc.) that we don't want to test against; filter to
  # X.Y.Z-only via the version regex.
  LATEST="$(mise ls-remote php 2>/dev/null \
             | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
             | sort -V | tail -1)"
  [[ -n "$LATEST" ]] || skip "could not resolve latest php from mise ls-remote"
  export LATEST
  export INSTALL="$HOME/.local/share/mise/installs/php/${LATEST}"

  mise uninstall -y "php@${LATEST}" >/dev/null 2>&1 || true
  mise install "php@${LATEST}" >&2 \
    || { echo "mise install php@${LATEST} failed"; return 1; }
}

@test "bin/php runs and reports the latest version" {
  [ -x "$INSTALL/bin/php" ]
  run "$INSTALL/bin/php" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "PHP $LATEST"* ]] \
    || { echo "wrong version reported: $output"; false; }
}

@test "config paths are inside the install" {
  run "$INSTALL/bin/php" -i
  [ "$status" -eq 0 ]
  loaded="$(printf '%s\n' "$output" | grep -E '^Loaded Configuration File')"
  scan="$(printf '%s\n' "$output"   | grep -E '^Scan this dir')"
  [[ "$loaded" == *"$INSTALL"* ]]
  [[ "$scan"   == *"$INSTALL"* ]]
}

@test "core Laravel extension surface loads on the latest" {
  # Same fixed list install-current uses. If a future PHP drops one
  # of these (unlikely for these staples), this test flags it.
  run "$INSTALL/bin/php" -r '
    $want = ["curl","mbstring","openssl","pdo_mysql","pdo_pgsql",
             "intl","sqlite3","gd","zip","mysqli","ldap","xml"];
    foreach ($want as $e) {
      if (!extension_loaded($e)) echo "MISSING:$e ";
    }
    echo "DONE";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "DONE" ]] \
    || { echo "extensions missing on latest: $output"; false; }
}

@test "unified extension_dir works on the latest" {
  local ext_dir
  ext_dir="$("$INSTALL/bin/php-config" --extension-dir)"
  [[ "$ext_dir" == "$INSTALL"/* ]]
  if [ ! -e "$ext_dir/opcache.so" ]; then
    echo "opcache.so not in unified ext_dir on latest: $(ls "$ext_dir")"
    echo "--- opcache.so search across install:"
    find "$INSTALL" -name 'opcache.so' 2>/dev/null | head -20
    echo "--- lib/php tree under keg:"
    find "$INSTALL"/Cellar/php@*/*/lib/php -maxdepth 3 2>/dev/null | head -40
    false
  fi
}

@test "asdf-php-ext list works on the latest" {
  run "$INSTALL/bin/asdf-php-ext" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"opcache"* ]]
}

@test "composer runs via mise exec against the latest" {
  run mise exec "php@$LATEST" -- "$INSTALL/bin/composer" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"Composer version"* ]]
  [[ "$output" == *"$LATEST"* ]] \
    || { echo "composer's PHP version doesn't match: $output"; false; }
}
