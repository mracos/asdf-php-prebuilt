#!/usr/bin/env bash
# Parse shivammathur/homebrew-php formula files.
#
# A "majmin" is the formula key, e.g. "8.1" → Formula/php@8.1.rb. Each
# formula pins exactly one patch version (e.g. php@8.1 currently = 8.1.34),
# parsed either from an explicit `version "X.Y.Z"` line or derived from the
# `url` field (`php-X.Y.Z.tar.xz`).
#
# Functions:
#   asdf_php_formula_list_majmins   → echo "8.1", "8.2", ... (one per line)
#   asdf_php_formula_fetch <majmin> → raw .rb content to stdout, cached
#   asdf_php_formula_version <content> → "8.1.34"

set -euo pipefail

ASDF_PHP_TAP_REPO="${ASDF_PHP_TAP_REPO:-shivammathur/homebrew-php}"
ASDF_PHP_TAP_REF="${ASDF_PHP_TAP_REF:-master}"
ASDF_PHP_CACHE_DIR="${ASDF_PHP_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/asdf-php}"

# List stable majmin keys in the tap (skip -debug, -zts variants).
asdf_php_formula_list_majmins() {
  local api="https://api.github.com/repos/${ASDF_PHP_TAP_REPO}/contents/Formula?ref=${ASDF_PHP_TAP_REF}"
  curl -fsSL "$api" \
    | awk -F'"' '/"name":/ {print $4}' \
    | grep -E '^php@[0-9]+\.[0-9]+\.rb$' \
    | sed -E 's/^php@//; s/\.rb$//' \
    | sort -V
}

# Fetch the raw formula for a majmin (e.g. "8.1") at a given ref. The ref
# defaults to ASDF_PHP_TAP_REF (master). For historical lookups, pass a
# commit sha. Cached on disk under (majmin, ref-short).
asdf_php_formula_fetch() {
  local majmin="$1" ref="${2:-$ASDF_PHP_TAP_REF}"
  local ref_short="${ref:0:12}"
  local cache_file="${ASDF_PHP_CACHE_DIR}/formula-php@${majmin}-${ref_short}.rb"
  if [[ ! -f "$cache_file" ]]; then
    mkdir -p "$ASDF_PHP_CACHE_DIR"
    local url="https://raw.githubusercontent.com/${ASDF_PHP_TAP_REPO}/${ref}/Formula/php@${majmin}.rb"
    curl -fsSL "$url" -o "$cache_file" \
      || asdf_php_die "could not fetch formula php@${majmin} from $url"
  fi
  cat "$cache_file"
}

# Fetch a formula from shivammathur/homebrew-extensions by name (e.g.
# "phpredis@8.1", "xdebug@8.1", "igbinary@8.1"). ref defaults to master.
# Not sharded — the tap keeps every formula at Formula/<name>.rb.
asdf_php_formula_fetch_ext() {
  local name="$1" ref="${2:-master}"
  local safe ref_short cache_file url
  safe="${name//\//_}"
  ref_short="${ref:0:12}"
  cache_file="${ASDF_PHP_CACHE_DIR}/formula-ext-${safe}-${ref_short}.rb"
  if [[ ! -f "$cache_file" ]]; then
    mkdir -p "$ASDF_PHP_CACHE_DIR"
    url="https://raw.githubusercontent.com/shivammathur/homebrew-extensions/${ref}/Formula/${name}.rb"
    curl -fsSL "$url" -o "$cache_file" 2>/dev/null \
      || { rm -f "$cache_file"; return 1; }
  fi
  cat "$cache_file"
}

# Fetch a homebrew-core formula by name at a given ref (e.g. "gettext",
# "openssl@3"). Homebrew-core shards Formula/ by first character of the
# formula name (lib* under lib/). ref defaults to "master".
# Returns non-zero on miss without dying — some deps may not exist there
# (caller decides whether to skip or escalate).
asdf_php_formula_fetch_core() {
  local name="$1" ref="${2:-master}"
  local shard safe ref_short cache_file url
  if [[ "$name" == lib* ]]; then
    shard="lib"
  else
    shard="${name:0:1}"
  fi
  safe="${name//\//_}"
  ref_short="${ref:0:12}"
  cache_file="${ASDF_PHP_CACHE_DIR}/formula-core-${safe}-${ref_short}.rb"
  if [[ ! -f "$cache_file" ]]; then
    mkdir -p "$ASDF_PHP_CACHE_DIR"
    url="https://raw.githubusercontent.com/Homebrew/homebrew-core/${ref}/Formula/${shard}/${name}.rb"
    curl -fsSL "$url" -o "$cache_file" 2>/dev/null \
      || { rm -f "$cache_file"; return 1; }
  fi
  cat "$cache_file"
}

# Parse the bottle root_url from formula content (stdin).
# E.g. `root_url "https://ghcr.io/v2/shivammathur/php"`
asdf_php_formula_bottle_root_url() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*root_url[[:space:]]+\"([^\"]+)\" ]]; then
      echo "${BASH_REMATCH[1]}"; return 0
    fi
  done
  return 1
}

# Parse the bottle sha256 digest for a given platform tag from formula
# content (stdin). Handles both shapes:
#   sha256 arm64_sequoia: "1692b3df..."
#   sha256 cellar: :any, arm64_tahoe: "..."
#   sha256 cellar: :any_skip_relocation, x86_64_linux: "..."
#
# Args:
#   $1 — platform tag (e.g. arm64_sequoia, sonoma)
asdf_php_formula_bottle_digest() {
  local want="$1" line
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*sha256[[:space:]] ]] || continue
    # Greedy .* eats any "cellar: :any," qualifier so the capture lands on
    # the trailing <tag>: "<digest>" pair.
    if [[ "$line" =~ [[:space:]]([a-z0-9_]+):[[:space:]]+\"([0-9a-f]{64})\" ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$want" ]]; then
        echo "${BASH_REMATCH[2]}"; return 0
      fi
    fi
  done
  return 1
}

# Resolve a bottle digest by walking the host's fallback tag chain.
# Reads formula content from stdin. Prints "tag digest" of the first match.
asdf_php_formula_bottle_resolve() {
  local content tag digest
  content="$(cat)"
  while read -r tag; do
    [[ -z "$tag" ]] && continue
    if digest=$(printf '%s' "$content" | asdf_php_formula_bottle_digest "$tag"); then
      echo "$tag $digest"; return 0
    fi
  done < <(asdf_php_host_tag_fallbacks)
  return 1
}

# Parse runtime dependencies from formula content (stdin), one per line.
#
# - Skips `=> :build` / `=> :test` (and any combination in arrays).
# - Treats unconditional `depends_on` and those inside `on_macos do ... end`
#   as runtime deps on macOS.
# - Skips `on_linux do ... end` deps.
# - Block tracking is shallow: nested do/end inside on_* blocks confuse it,
#   but we haven't observed that in php@*.rb. Revisit if needed.
asdf_php_formula_dependencies() {
  awk '
    /^[[:space:]]*on_macos[[:space:]]+do[[:space:]]*$/ { in_macos=1; next }
    /^[[:space:]]*on_linux[[:space:]]+do[[:space:]]*$/ { in_linux=1; next }
    /^[[:space:]]*end[[:space:]]*$/ {
      if (in_macos) { in_macos=0; next }
      if (in_linux) { in_linux=0; next }
    }
    in_linux { next }
    /^[[:space:]]*depends_on[[:space:]]+"[^"]+"/ {
      # Skip build/test-scoped deps.
      if ($0 ~ /=>[[:space:]]*:build/) next
      if ($0 ~ /=>[[:space:]]*:test/) next
      if ($0 ~ /=>[[:space:]]*\[[^]]*:build/) next
      if ($0 ~ /=>[[:space:]]*\[[^]]*:test/) next
      # Extract first quoted name.
      n = split($0, a, "\"")
      if (n >= 2) print a[2]
    }
  '
}

# Parse the patch version from formula content (stdin).
# Tries `version "X.Y.Z"` first, falls back to `url ".../php-X.Y.Z.tar.xz"`.
asdf_php_formula_version() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*version[[:space:]]+\"([0-9]+\.[0-9]+\.[0-9]+)\" ]]; then
      echo "${BASH_REMATCH[1]}"; return 0
    fi
    if [[ "$line" =~ url[[:space:]]+\"[^\"]*php-([0-9]+\.[0-9]+\.[0-9]+)\.tar ]]; then
      echo "${BASH_REMATCH[1]}"; return 0
    fi
  done
  return 1
}
