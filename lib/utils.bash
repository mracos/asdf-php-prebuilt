#!/usr/bin/env bash
# Shared helpers for asdf-php scripts.
#
# Sections:
#   1. Logging       — log, warn, die
#   2. Platform      — host arch + macOS codename → bottle tag
#   3. Filesystem    — tmpdir lifecycle

set -euo pipefail

# --- Logging ---

asdf_php_log()  { printf 'asdf-php: %s\n' "$*" >&2; }
asdf_php_warn() { printf 'asdf-php: warning: %s\n' "$*" >&2; }
asdf_php_die() { printf 'asdf-php: error: %s\n' "$*" >&2; exit 1; }

# --- Platform detection ---

# Print host arch in the brew bottle convention: arm64 or x86_64.
asdf_php_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo arm64 ;;
    x86_64|amd64)  echo x86_64 ;;
    *) asdf_php_die "unsupported arch: $(uname -m)" ;;
  esac
}

# Print macOS major version (e.g. 15 for Sequoia, 26 for Tahoe).
asdf_php_macos_major() {
  [[ "$(uname -s)" == "Darwin" ]] || asdf_php_die "this plugin currently supports macOS only"
  sw_vers -productVersion | awk -F. '{print $1}'
}

# Print the brew bottle tag matching the host (arm64_sequoia, sonoma, etc.).
# Falls back are the caller's job (bottle lookup walks older tags on miss).
asdf_php_host_tag() {
  local arch codename major
  arch="$(asdf_php_arch)"
  major="$(asdf_php_macos_major)"

  case "$major" in
    26) codename=tahoe ;;
    15) codename=sequoia ;;
    14) codename=sonoma ;;
    13) codename=ventura ;;
    12) codename=monterey ;;
    11) codename=big_sur ;;
    *)  asdf_php_die "unsupported macOS major: $major" ;;
  esac

  if [[ "$arch" == arm64 ]]; then
    echo "arm64_${codename}"
  else
    echo "$codename"
  fi
}

# Print the ordered fallback list of bottle tags for the host, newest-first.
# Bottles are forward-compatible — a Sonoma bottle runs on Sequoia. So when
# the exact host tag is missing, walk back to older codenames within the
# same arch.
asdf_php_host_tag_fallbacks() {
  local arch="$(asdf_php_arch)"
  local major="$(asdf_php_macos_major)"
  local codenames=(tahoe sequoia sonoma ventura monterey big_sur)
  local start_idx=-1 i codename

  case "$major" in
    26) start_idx=0 ;;
    15) start_idx=1 ;;
    14) start_idx=2 ;;
    13) start_idx=3 ;;
    12) start_idx=4 ;;
    11) start_idx=5 ;;
  esac
  [[ $start_idx -ge 0 ]] || asdf_php_die "unsupported macOS major: $major"

  for ((i=start_idx; i<${#codenames[@]}; i++)); do
    codename="${codenames[$i]}"
    if [[ "$arch" == arm64 ]]; then
      echo "arm64_${codename}"
    else
      echo "$codename"
    fi
  done
}

# --- Filesystem ---

# Create a tmpdir under the plugin's namespace. Caller is responsible for
# trapping cleanup. Prints the path.
asdf_php_mktempdir() {
  mktemp -d "${TMPDIR:-/tmp}/asdf-php.XXXXXX"
}
