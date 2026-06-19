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

# Fetch the raw formula for a majmin (e.g. "8.1"). Cached on disk.
asdf_php_formula_fetch() {
  local majmin="$1"
  local cache_file="${ASDF_PHP_CACHE_DIR}/formula-php@${majmin}-${ASDF_PHP_TAP_REF}.rb"
  if [[ ! -f "$cache_file" ]]; then
    mkdir -p "$ASDF_PHP_CACHE_DIR"
    local url="https://raw.githubusercontent.com/${ASDF_PHP_TAP_REPO}/${ASDF_PHP_TAP_REF}/Formula/php@${majmin}.rb"
    curl -fsSL "$url" -o "$cache_file" \
      || asdf_php_die "could not fetch formula php@${majmin} from $url"
  fi
  cat "$cache_file"
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
