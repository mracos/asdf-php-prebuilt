#!/usr/bin/env bash
# Resolve historical formula refs so we can install older PHP patch
# versions (e.g. php@8.1.27) that the current tap no longer pins.
#
# Strategy:
#   1. Maintain a shallow clone of shivammathur/homebrew-php under
#      ~/.cache/asdf-php/tap-clone/. `git log -S` finds the commit that
#      introduced a given patch version in milliseconds.
#   2. Look up the contemporary homebrew-core commit by timestamp via
#      `gh api commits?until=<iso>&per_page=1`. Cached on disk so
#      successive dep fetches reuse the same ref.
#
# Functions:
#   asdf_php_history_sync_tap
#       → ensure ~/.cache/asdf-php/tap-clone/ exists + is current.
#   asdf_php_history_find_tap_ref <majmin> <version>
#       → prints "<sha> <iso-date>" of the commit that first pinned
#         `php-<version>.tar.xz` on Formula/php@<majmin>.rb.
#         Exits non-zero if nothing matches.
#   asdf_php_history_find_core_ref <iso-date>
#       → prints homebrew-core sha at-or-before the timestamp. Cached.

set -euo pipefail

ASDF_PHP_TAP_CLONE_DIR="${ASDF_PHP_TAP_CLONE_DIR:-${ASDF_PHP_CACHE_DIR}/tap-clone}"
# Pull at most once per ASDF_PHP_TAP_REFRESH_SECONDS (default: 24h). Older
# than that, do a `git fetch` before searching. Avoids hammering GitHub
# when the user runs several installs back-to-back.
ASDF_PHP_TAP_REFRESH_SECONDS="${ASDF_PHP_TAP_REFRESH_SECONDS:-86400}"

# Clone (or refresh) the tap. Idempotent.
asdf_php_history_sync_tap() {
  local dir="$ASDF_PHP_TAP_CLONE_DIR"
  local marker="$dir/.last-fetch"

  if [[ ! -d "$dir/.git" ]]; then
    asdf_php_log "cloning ${ASDF_PHP_TAP_REPO} (one-time, ~10MB)..."
    mkdir -p "$(dirname -- "$dir")"
    rm -rf "$dir"
    git clone --no-checkout --quiet \
      "https://github.com/${ASDF_PHP_TAP_REPO}.git" "$dir" \
      || asdf_php_die "git clone failed for ${ASDF_PHP_TAP_REPO}"
    touch "$marker"
    return 0
  fi

  # Refresh if stale.
  if [[ -f "$marker" ]]; then
    local now mtime age
    now="$(date +%s)"
    if stat -f %m "$marker" >/dev/null 2>&1; then
      mtime="$(stat -f %m "$marker")"           # BSD stat (macOS)
    else
      mtime="$(stat -c %Y "$marker")"           # GNU stat (Linux)
    fi
    age=$((now - mtime))
    if [[ "$age" -lt "$ASDF_PHP_TAP_REFRESH_SECONDS" ]]; then
      return 0
    fi
  fi

  asdf_php_log "refreshing ${ASDF_PHP_TAP_REPO} clone..."
  git -C "$dir" fetch --quiet origin 2>/dev/null \
    || asdf_php_warn "git fetch failed; continuing with cached refs"
  touch "$marker"
}

# Find the latest tap commit whose Formula/php@<majmin>.rb pins the
# given patch version. Walks the file's commit history newest-first and
# returns the first commit whose parsed version matches.
#
# Why not just `git log -S '...' --reverse | head`: the tap sometimes
# bumps the source `url` to the new patch a few seconds before the
# rebuilt bottle sha256s land in a follow-up commit. The earliest
# commit with the new URL still has the previous patch's bottle hashes.
# Picking the latest 8.1.27 commit guarantees we get the bottles that
# were actually built for 8.1.27.
asdf_php_history_find_tap_ref() {
  local majmin="$1" version="$2"
  asdf_php_history_sync_tap

  local commits sha date v
  commits="$(git -C "$ASDF_PHP_TAP_CLONE_DIR" log --format='%H %cI' \
                -- "Formula/php@${majmin}.rb" 2>/dev/null)"
  [[ -n "$commits" ]] \
    || asdf_php_die "no commits touch Formula/php@${majmin}.rb in $ASDF_PHP_TAP_CLONE_DIR"

  while IFS=' ' read -r sha date; do
    [[ -z "$sha" ]] && continue
    v="$(git -C "$ASDF_PHP_TAP_CLONE_DIR" show "${sha}:Formula/php@${majmin}.rb" 2>/dev/null \
            | asdf_php_formula_version)" || continue
    if [[ "$v" == "$version" ]]; then
      echo "$sha $date"
      return 0
    fi
  done <<< "$commits"

  asdf_php_die "no tap commit found pinning php@${majmin}=${version}"
}

# Find homebrew-core sha at-or-before an ISO-8601 timestamp. Cached.
asdf_php_history_find_core_ref() {
  local ts="$1"
  local safe_ts="${ts//:/_}"
  safe_ts="${safe_ts//+/_}"
  local cache_file="${ASDF_PHP_CACHE_DIR}/core-ref-${safe_ts}.sha"

  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return 0
  fi

  command -v gh >/dev/null 2>&1 \
    || asdf_php_die "gh CLI required for historical installs; install with: brew install gh"

  local sha
  sha="$(gh api "repos/Homebrew/homebrew-core/commits?until=${ts}&per_page=1" \
            --jq '.[0].sha' 2>/dev/null)"
  if [[ -z "$sha" || "$sha" == "null" ]]; then
    asdf_php_die "could not resolve homebrew-core ref at-or-before $ts"
  fi

  mkdir -p "$ASDF_PHP_CACHE_DIR"
  printf '%s' "$sha" > "$cache_file"
  echo "$sha"
}
