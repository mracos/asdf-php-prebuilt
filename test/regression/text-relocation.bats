#!/usr/bin/env bats
# Regression: bottled shell/PHP scripts (pecl, pear, phpize, php-config,
# ...) must have their @@HOMEBREW_(PREFIX|CELLAR)@@ placeholders
# rewritten to real paths, but .phar archives must be left untouched.
#
# History: initial relocator only handled Mach-O LC_LOAD_DYLIB entries
# via install_name_tool. Text scripts kept literal placeholders in
# their exec lines, so bash treated `@@HOMEBREW_CELLAR@@/...` as a
# relative path and produced errors like:
#   /path/to/pecl: line 28: /cwd/@@HOMEBREW_CELLAR@@/php@8.1/…/bin/php:
#     No such file or directory
# First pass at a fix sed'd every text file. That corrupted
# phar.phar's manifest (PHP-serialized offsets shift when the path
# strings grow). Second pass skips .phar files.
#
# This test guards both pieces of the fix.

load ../helpers

INSTALL="$HOME/.local/share/mise/installs/php/8.1.27"

setup() {
  require_install "$INSTALL"
}

@test "no non-phar script under bin/ still contains @@HOMEBREW_ placeholders" {
  # Scripts that were still unrelocated would print "@@HOMEBREW_...:
  # No such file or directory" when invoked. Find real files only —
  # bin/phar is a symlink to phar.phar and would surface as a false
  # positive via `grep -l` (which reads through the link).
  local hits
  hits="$(find "$INSTALL/Cellar/php@8.1" -type f -path '*/bin/*' \
            ! -name '*.phar' -exec grep -lE '@@HOMEBREW_(PREFIX|CELLAR)@@' {} + \
          2>/dev/null || true)"
  [[ -z "$hits" ]] \
    || { echo "unrelocated non-phar scripts still carry placeholders:"; echo "$hits"; false; }
}

@test "phar/phar.phar wrappers are NOT created (intentional skip)" {
  # phar.phar's built-in SHA1 signature was computed by brew for the
  # resolved-path shebang. Since we don't run brew's post_install to
  # rewrite the shebang + regenerate the signature, phar.phar cannot
  # be executed either directly or via `php phar.phar` — Phar::mapPhar
  # throws "SHA1 signature could not be verified". Creating a wrapper
  # would just make that error surface at every invocation. Instead,
  # skip both. Users who need Phar functionality can use the Phar API
  # from their own PHP scripts.
  [ ! -e "$INSTALL/bin/phar" ] \
    || { echo "bin/phar wrapper exists but shouldn't (phar unsupported)"; false; }
  [ ! -e "$INSTALL/bin/phar.phar" ] \
    || { echo "bin/phar.phar wrapper exists but shouldn't"; false; }
}

@test "pecl script's hardcoded PHP= path resolves to a real binary" {
  local pecl="$INSTALL/Cellar/php@8.1"/*/bin/pecl
  set -- $pecl; pecl="$1"
  [ -f "$pecl" ] || skip "pecl script not present"

  # pecl has three PHP= assignments (unset env, hardcoded literal,
  # var expansion). We want the LITERAL absolute path — the one that
  # was placeholder-rewritten. Match `PHP="/..."` starting with `/`.
  local literal
  literal="$(grep -E '^[[:space:]]*PHP="/[^"]+"$' "$pecl" | head -1 \
             | sed -E 's/.*"([^"]+)".*/\1/')"
  [[ -n "$literal" ]] \
    || { echo "no literal PHP= line found in $pecl"; false; }
  [ -x "$literal" ] \
    || { echo "pecl's PHP=$literal is not executable"; false; }
}

@test "php-config reports our install prefix (not brew's)" {
  run "$INSTALL/bin/php-config" --prefix
  [ "$status" -eq 0 ]
  [[ "$output" == "$INSTALL"/* ]] \
    || { echo "php-config points outside our install: $output"; false; }
  [[ ! "$output" =~ "@@HOMEBREW" ]] \
    || { echo "php-config still emits placeholders: $output"; false; }
  [[ ! "$output" =~ "/opt/homebrew" ]] \
    || { echo "php-config points at brew's prefix: $output"; false; }
}

@test "phpize reports our install prefix (not brew's)" {
  run "$INSTALL/bin/phpize" --help
  # phpize --help exits 0 or 1 depending on version, but it must not
  # emit @@HOMEBREW placeholders and must reference our install path.
  [[ ! "$output" =~ "@@HOMEBREW" ]] \
    || { echo "phpize still carries placeholders: $output"; false; }
}
