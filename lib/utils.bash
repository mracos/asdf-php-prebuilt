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

# Ordered newest-first "<major> <codename>" table. Single source of truth for
# the host tag and its fallback chain; mirrors Homebrew's MacOSVersion::RELEASES
# in Library/Homebrew/macos_version.rb.
ASDF_PHP_MACOS_RELEASES="27 golden_gate
26 tahoe
15 sequoia
14 sonoma
13 ventura
12 monterey
11 big_sur"

# Print the brew bottle tag matching the host (arm64_sequoia, sonoma, etc.).
# Fallbacks are the caller's job (bottle lookup walks the chain below on miss).
asdf_php_host_tag() {
  local tags
  tags="$(asdf_php_host_tag_fallbacks)"
  printf '%s\n' "${tags%%$'\n'*}"
}

# Print the ordered fallback list of bottle tags for the host, newest-first.
#
# Bottles are backward-compatible (a Sonoma bottle runs on Sequoia) but never
# forward-compatible: dyld refuses a dylib whose LC_BUILD_VERSION minos is newer
# than the running OS. So on a miss we walk to *older* codenames only, then to
# `all`: the OS- and arch-independent tag brew gives data-only formulas such as
# ca-certificates, which carry no per-codename bottle at all.
asdf_php_host_tag_fallbacks() {
  local arch major found=0 m codename
  arch="$(asdf_php_arch)"
  major="$(asdf_php_macos_major)"

  while read -r m codename; do
    if [[ $found -eq 0 && "$m" != "$major" ]]; then
      continue
    fi
    found=1
    if [[ "$arch" == arm64 ]]; then
      echo "arm64_${codename}"
    else
      echo "$codename"
    fi
  done <<< "$ASDF_PHP_MACOS_RELEASES"

  [[ $found -eq 1 ]] || asdf_php_die "unsupported macOS major: $major"

  echo all
}

# --- Filesystem ---

# Create a tmpdir under the plugin's namespace. Caller is responsible for
# trapping cleanup. Prints the path.
asdf_php_mktempdir() {
  mktemp -d "${TMPDIR:-/tmp}/asdf-php.XXXXXX"
}
