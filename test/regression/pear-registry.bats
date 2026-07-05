#!/usr/bin/env bats
# Regression: PEAR .reg files must unserialize cleanly.
#
# Diagnosis lived in TODO for a long time: `pecl / pear` operations
# emitted `Notice: unserialize(): Error at offset N of M bytes in
# .../PEAR/Registry.php` every time. Cause: brew's post_install
# substitutes `@@HOMEBREW_CELLAR@@` (19 chars) with
# `/opt/homebrew/Cellar` (20 chars), and the bottled .reg files ship
# with `s:N:` length prefixes baked for the RESOLVED brew path. With
# the placeholder still in the file, every prefix is off by 1 per
# substitution site, unserialize fails at the first mismatch, and
# PEAR falls back to compiled-in defaults with a noisy Notice.
#
# Fix: lib/install.bash asdf_php_install_seed_etc runs a
# preg_replace_callback pass over `.registry/*.reg` and
# `.channels/**/*.reg`, substituting the placeholder with the actual
# install Cellar path AND recomputing each `s:N:` prefix.

load ../helpers

INSTALL="$(any_php_81_install)"

setup() {
  require_install "$INSTALL"
}

@test "every .reg file under Cellar unserializes cleanly" {
  local pear_dir
  pear_dir="$(find "$INSTALL/Cellar/php@8.1" -type d -name pear -maxdepth 4 2>/dev/null | head -1)"
  [[ -d "$pear_dir" ]] || skip "no pear registry in this install"

  local failed=0
  while IFS= read -r reg; do
    if ! "$INSTALL/bin/php" -r '
      $r = @unserialize(file_get_contents($argv[1]));
      exit($r === false ? 1 : 0);
    ' "$reg"; then
      echo "unserialize failed: ${reg##*/}"
      failed=1
    fi
  done < <(find "$pear_dir" -name '*.reg' 2>/dev/null)

  [[ "$failed" -eq 0 ]] \
    || { echo "at least one .reg still broken"; false; }
}

@test "no .reg still carries the @@HOMEBREW_CELLAR@@ placeholder" {
  local pear_dir
  pear_dir="$(find "$INSTALL/Cellar/php@8.1" -type d -name pear -maxdepth 4 2>/dev/null | head -1)"
  [[ -d "$pear_dir" ]] || skip "no pear registry in this install"

  # After the fixer, all .reg values should have real Cellar paths
  # (or be paths without any placeholder at all).
  local hits
  hits="$(find "$pear_dir" -name '*.reg' -exec grep -lF '@@HOMEBREW_CELLAR@@' {} + 2>/dev/null || true)"
  [[ -z "$hits" ]] \
    || { echo "leftover placeholders in:"; echo "$hits"; false; }
}

@test "pecl config-show completes without unserialize notices" {
  # This is the visible symptom users hit before the fix landed.
  # Guard against regression in the base install pipeline.
  run "$INSTALL/bin/pecl" config-show
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "unserialize" ]] \
    || { echo "unserialize notice reappeared: $output"; false; }
}

@test "pecl list runs cleanly (proves .reg reads actually parse)" {
  # `pecl list` only shows pecl.php.net installs. If no user extension
  # is installed via pecl, it prints "(no packages installed from
  # channel pecl.php.net)". Either output is fine, the key check is
  # that we don't get unserialize notices.
  run "$INSTALL/bin/pecl" list
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "unserialize" ]]
}

@test "pear list works and shows bundled packages" {
  # PEAR packages (Archive_Tar, Console_Getopt, PEAR, Structures_Graph,
  # XML_Util) ship with every shivammathur bottle. If the .reg files
  # unserialize, pear list should enumerate at least those.
  run "$INSTALL/bin/pear" list
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "unserialize" ]]
  [[ "$output" == *"INSTALLED PACKAGES"* ]] \
    || { echo "unexpected pear list output: $output"; false; }
}
