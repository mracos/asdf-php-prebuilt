#!/usr/bin/env bats
# Unit tests for lib/formula.bash parsers.
#
# All tests are offline — they feed checked-in fixtures through the
# parsers and assert exact outputs. No network, no gh, no bottle downloads.
# When adding new fixtures, capture with:
#   cp ~/.cache/asdf-php/formula-*-<sha>.rb test/fixtures/<name>.rb

load ../helpers

setup() {
  load_lib utils
  load_lib formula
}

FIXTURES="$PLUGIN_DIR/test/fixtures"

# ---------- version parsing ----------

@test "formula_version: extracts from explicit \`version \"X.Y.Z\"\` line" {
  # php@8.1 current tap has this shape.
  result="$(asdf_php_formula_version < "$FIXTURES/php@8.1-current.rb")"
  [[ "$result" =~ ^8\.1\.[0-9]+$ ]] \
    || { echo "unexpected version: $result"; false; }
}

@test "formula_version: falls back to url-derived version" {
  # Historical 8.1.27 formula has both explicit version + url; version
  # wins. Test the fallback by feeding a stripped fixture.
  local no_version_field
  no_version_field="$(grep -v '^  version ' "$FIXTURES/php@8.1-8.1.27.rb")"
  result="$(printf '%s' "$no_version_field" | asdf_php_formula_version)"
  [[ "$result" == "8.1.27" ]] \
    || { echo "url fallback failed: got $result"; false; }
}

@test "formula_version: returns non-zero when neither version nor url matches" {
  # Use a subshell so the lib source in setup() doesn't leak state.
  run bash -c "source '$PLUGIN_DIR/lib/utils.bash'; source '$PLUGIN_DIR/lib/formula.bash'; printf 'class Foo\nend\n' | asdf_php_formula_version"
  [ "$status" -ne 0 ]
}

# ---------- bottle metadata ----------

@test "formula_bottle_root_url: shivammathur php formula → ghcr.io/v2/shivammathur/php" {
  result="$(asdf_php_formula_bottle_root_url < "$FIXTURES/php@8.1-current.rb")"
  [[ "$result" == "https://ghcr.io/v2/shivammathur/php" ]] \
    || { echo "unexpected root_url: $result"; false; }
}

@test "formula_bottle_root_url: homebrew-core formula has no explicit root_url" {
  # openssl3 in homebrew-core omits root_url (uses the default).
  run bash -c "source '$PLUGIN_DIR/lib/utils.bash'; source '$PLUGIN_DIR/lib/formula.bash'; asdf_php_formula_bottle_root_url < '$FIXTURES/openssl3-2024-02.rb'"
  [ "$status" -ne 0 ]
}

@test "formula_bottle_digest: extracts arm64_sonoma from historical php@8.1=8.1.27" {
  result="$(asdf_php_formula_bottle_digest arm64_sonoma < "$FIXTURES/php@8.1-8.1.27.rb")"
  [[ "$result" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "expected 64-hex digest, got: $result"; false; }
}

@test "formula_bottle_digest: handles \`sha256 cellar: :any, arm64_sonoma:\` shape" {
  # libpq's bottle lines have the `cellar: :any` qualifier. The regex
  # has to skip past it to find the tag.
  result="$(asdf_php_formula_bottle_digest arm64_sonoma < "$FIXTURES/libpq-2024-02.rb")"
  [[ "$result" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "cellar-qualified digest not parsed: $result"; false; }
}

@test "formula_bottle_digest: handles the arch-independent \`all:\` tag" {
  # ca-certificates ships data, not Mach-O, so brew bottles it once under
  # `all:` with no per-codename tags at all.
  result="$(asdf_php_formula_bottle_digest all < "$FIXTURES/ca-certificates-2026-08.rb")"
  [[ "$result" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "all-tag digest not parsed: $result"; false; }
}

@test "formula_bottle_resolve: falls through the codename chain to \`all\`" {
  # The host has no ca-certificates codename bottle to match, so resolution
  # only succeeds if the chain ends at `all`.
  local out
  out="$(asdf_php_formula_bottle_resolve < "$FIXTURES/ca-certificates-2026-08.rb")"
  [[ "$out" =~ ^all\ [0-9a-f]{64}$ ]] \
    || { echo "expected 'all <digest>', got: $out"; false; }
}

@test "formula_bottle_digest: returns non-zero for a missing platform tag" {
  run bash -c "source '$PLUGIN_DIR/lib/utils.bash'; source '$PLUGIN_DIR/lib/formula.bash'; asdf_php_formula_bottle_digest arm64_ancient_moon < '$FIXTURES/php@8.1-current.rb'"
  [ "$status" -ne 0 ]
}

# ---------- dependencies ----------

@test "formula_dependencies: lists runtime deps, skipping :build and :test" {
  local deps
  deps="$(asdf_php_formula_dependencies < "$FIXTURES/php@8.1-current.rb")"
  # Should include curl, gmp, openssl@3 (all runtime, unconditional).
  [[ "$deps" == *curl* ]]         || { echo "missing curl"; false; }
  [[ "$deps" == *gmp* ]]          || { echo "missing gmp"; false; }
  [[ "$deps" == *openssl@3* ]]    || { echo "missing openssl@3"; false; }
  # Should NOT include :build-scoped tools (bison, re2c, pkgconf/pkg-config).
  [[ ! "$deps" =~ ^bison$ ]]      || { echo "leaked bison (:build)"; false; }
  [[ ! "$deps" =~ ^re2c$ ]]       || { echo "leaked re2c (:build)"; false; }
}

@test "formula_dependencies: includes on_macos block deps, excludes on_linux" {
  local deps
  deps="$(asdf_php_formula_dependencies < "$FIXTURES/php@8.1-current.rb")"
  # gettext is in an on_macos block in the current formula.
  [[ "$deps" == *gettext* ]] \
    || { echo "missing gettext (on_macos)"; false; }
  # zlib-ng-compat is in the on_linux block (should be excluded).
  [[ ! "$deps" =~ zlib-ng-compat ]] \
    || { echo "leaked zlib-ng-compat (on_linux)"; false; }
}

@test "formula_dependencies: order-agnostic count sanity" {
  # php@8.1 has ~20 runtime deps unconditional + gettext under
  # on_macos. Assert we get more than a handful and no wild inflation.
  local count
  count="$(asdf_php_formula_dependencies < "$FIXTURES/php@8.1-current.rb" | wc -l | tr -d ' ')"
  [ "$count" -ge 15 ] \
    || { echo "unexpectedly low dep count: $count"; false; }
  [ "$count" -le 35 ] \
    || { echo "unexpectedly high dep count: $count"; false; }
}

# ---------- ghcr repo path derivation ----------

@test "ghcr_repo_path: shivammathur php@8.1 → shivammathur/php/php/8.1" {
  load_lib ghcr
  result="$(asdf_php_ghcr_repo_path "https://ghcr.io/v2/shivammathur/php" "php@8.1")"
  [[ "$result" == "shivammathur/php/php/8.1" ]] \
    || { echo "unexpected repo path: $result"; false; }
}

@test "ghcr_repo_path: openssl@3 in homebrew-core → homebrew/core/openssl/3" {
  load_lib ghcr
  result="$(asdf_php_ghcr_repo_path "https://ghcr.io/v2/homebrew/core" "openssl@3")"
  [[ "$result" == "homebrew/core/openssl/3" ]] \
    || { echo "unexpected repo path: $result"; false; }
}

@test "ghcr_repo_path: no-@ formula name maps identically" {
  load_lib ghcr
  result="$(asdf_php_ghcr_repo_path "https://ghcr.io/v2/homebrew/core" "gettext")"
  [[ "$result" == "homebrew/core/gettext" ]]
}

# ---------- platform tag fallback chain ----------

@test "host_tag_fallbacks: newer host walks back through older codenames" {
  # We can't set uname/sw_vers from the test process, but we can call
  # the function and assert its output has the expected shape (walks
  # from newest to oldest, only within the host arch).
  local tags
  tags="$(asdf_php_host_tag_fallbacks)"

  # Every emitted tag matches a known codename, or the arch-independent `all`.
  while IFS= read -r tag; do
    [[ "$tag" =~ ^((arm64_)?(golden_gate|tahoe|sequoia|sonoma|ventura|monterey|big_sur)|all)$ ]] \
      || { echo "unexpected tag in fallback chain: $tag"; false; }
  done <<< "$tags"

  # The first tag is the direct host match.
  [[ "$(echo "$tags" | head -1)" == "$(asdf_php_host_tag)" ]] \
    || { echo "first fallback isn't the host tag"; false; }

  # `all` is last, so a real codename bottle always wins over it.
  [[ "$(echo "$tags" | tail -1)" == "all" ]] \
    || { echo "fallback chain doesn't end at 'all'"; false; }
}

@test "host_tag_fallbacks: chain only walks to older codenames, never newer" {
  # A newer bottle on an older host is a dyld error (LC_BUILD_VERSION minos),
  # so the chain must be a suffix of the release table starting at the host.
  local releases tags expected
  releases="$(printf '%s\n' "$ASDF_PHP_MACOS_RELEASES" | awk '{print $2}')"
  tags="$(asdf_php_host_tag_fallbacks | sed '$d; s/^arm64_//')"
  expected="$(printf '%s\n' "$releases" | grep -A100 -x "$(echo "$tags" | head -1)")"

  [[ "$tags" == "$expected" ]] \
    || { echo "chain: $tags"; echo "expected suffix: $expected"; false; }
}

@test "host_tag: dies on a macOS major that isn't in the release table" {
  run bash -c "source '$PLUGIN_DIR/lib/utils.bash'
    asdf_php_macos_major() { echo 99; }
    asdf_php_host_tag"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported macOS major: 99"* ]] \
    || { echo "unexpected error: $output"; false; }
}
