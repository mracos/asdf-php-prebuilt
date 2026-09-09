#!/usr/bin/env bats
# Regression: a Mach-O file that gets *copied* somewhere else in the
# prefix has to be relocated at its destination.
#
# History: `asdf-php-ext install imagick` staged imagick.so and then
# segfaulted php (exit 139) on the verify step. Two causes, both here:
#
#   1. shivammathur's AbstractPhpExtension does
#      `prefix.install "modules/<name>.so"`, so the .so lands at the
#      keg root: `Cellar/imagick@8.2/3.8.1_2/imagick.so`. None of the
#      `*/bin/*`, `*/lib/*`, `*/ext/*` paths asdf_php_relocate_all
#      walks match that, so the file kept its @@HOMEBREW_PREFIX@@ refs.
#   2. Even relocated in place it would have been wrong: the keg root
#      is 3 levels under the prefix, ext_dir (`<keg>/pecl/<api>/`) is
#      5, and @loader_path resolves from wherever dyld loaded the file.
#      A 3-up prefix resolves to <prefix>/Cellar/php@<majmin>.
#
# Fix: _stage_ext_so copies first, then relocates the copy, then
# refuses to enable an extension whose dylibs don't resolve, because
# dyld turns a missing dylib into a segfault with no useful message.

load ../helpers

INSTALL="$(any_php_81_install)"

setup() {
  require_install "$INSTALL"
  load_lib utils
  load_lib relocate

  # A real Mach-O to rewrite. Any dylib from the install works; give it
  # a placeholder reference the way a `cellar: :any` bottle ships one.
  local src
  src="$(find "$INSTALL/Cellar" -type f -name '*.dylib' -size -2000k 2>/dev/null | head -1)"
  [[ -n "$src" ]] || skip "no dylib under $INSTALL/Cellar to build a fixture from"

  FAKE_PREFIX="$BATS_TEST_TMPDIR/prefix"
  EXT_DIR="$FAKE_PREFIX/Cellar/php@8.1/1.0.0/pecl/20210902"
  KEG_SO="$FAKE_PREFIX/Cellar/fixture@8.1/1.0/fixture.so"
  mkdir -p "$EXT_DIR" "$(dirname "$KEG_SO")"

  cp "$src" "$KEG_SO"
  install_name_tool -change /usr/lib/libSystem.B.dylib \
    '@@HOMEBREW_PREFIX@@/opt/fixture/lib/libfixture.dylib' "$KEG_SO" 2>/dev/null
}

# The dylib the fixture links against, present in the prefix.
_provide_fixture_dylib() {
  mkdir -p "$FAKE_PREFIX/opt/fixture/lib"
  touch "$FAKE_PREFIX/opt/fixture/lib/libfixture.dylib"
}

@test "the staged copy is relocated for ext_dir and its dylib resolves" {
  _provide_fixture_dylib
  cp "$KEG_SO" "$EXT_DIR/fixture.so"
  asdf_php_relocate_file "$EXT_DIR/fixture.so" "$FAKE_PREFIX"

  # 5 ups: Cellar / php@8.1 / 1.0.0 / pecl / 20210902.
  run otool -L "$EXT_DIR/fixture.so"
  [[ "$output" == *"@loader_path/../../../../../opt/fixture/lib/libfixture.dylib"* ]] \
    || { echo "wrong @loader_path depth for the copy:"; echo "$output"; false; }

  run asdf_php_unresolved_dylibs "$EXT_DIR/fixture.so"
  [[ "$output" != *"opt/fixture/lib/libfixture.dylib"* ]] \
    || { echo "correctly relocated ref still flagged: $output"; false; }
}

@test "relocating the keg-root source instead points the copy outside the prefix" {
  _provide_fixture_dylib
  asdf_php_relocate_file "$KEG_SO" "$FAKE_PREFIX"
  cp "$KEG_SO" "$EXT_DIR/fixture.so"

  # 3 ups from ext_dir lands in <prefix>/Cellar/php@8.1, where there is
  # no opt/fixture. This is the state that segfaulted php.
  run asdf_php_unresolved_dylibs "$EXT_DIR/fixture.so"
  [[ "$output" == *"opt/fixture/lib/libfixture.dylib"* ]] \
    || { echo "expected the mis-depthed ref to be flagged, got: $output"; false; }
}

@test "unresolved_dylibs flags a dylib that isn't in the prefix at all" {
  cp "$KEG_SO" "$EXT_DIR/fixture.so"
  asdf_php_relocate_file "$EXT_DIR/fixture.so" "$FAKE_PREFIX"

  run asdf_php_unresolved_dylibs "$EXT_DIR/fixture.so"
  [[ "$output" == *"opt/fixture/lib/libfixture.dylib"* ]] \
    || { echo "missing dylib not flagged: $output"; false; }
}

@test "unresolved_dylibs flags an unrewritten @@HOMEBREW_ reference" {
  _provide_fixture_dylib
  cp "$KEG_SO" "$EXT_DIR/fixture.so"

  run asdf_php_unresolved_dylibs "$EXT_DIR/fixture.so"
  [[ "$output" == *"@@HOMEBREW_PREFIX@@/opt/fixture/lib/libfixture.dylib"* ]] \
    || { echo "placeholder ref not flagged: $output"; false; }
}
