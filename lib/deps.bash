#!/usr/bin/env bash
# Walk the transitive runtime-dep DAG for a brew formula.
#
# All transitive deps for shivammathur/homebrew-php's php@* formulas live
# in Homebrew/homebrew-core (shivammathur's tap only houses php@* and
# php-related extensions). So this walker assumes deps resolve against
# homebrew-core.
#
# Outputs lines of: "<name> <root_url> <tag> <digest>" for each unique
# dep that has a bottle for the host platform.
#
# Dependencies missing from homebrew-core (e.g. test-only or removed
# formulas) are warned and skipped; bottles missing for our host tag are
# warned and skipped.

set -euo pipefail

# Default GHCR root for homebrew-core formulas that don't declare one.
ASDF_PHP_DEPS_CORE_ROOT_URL="${ASDF_PHP_DEPS_CORE_ROOT_URL:-https://ghcr.io/v2/homebrew/core}"

# Walk transitive deps. Reads the root formula content from stdin.
# Optional arg $1 is the homebrew-core ref to resolve deps against
# (defaults to master). For historical installs, pass the contemporary
# commit so transitive deps come from formulas that match the era when
# the root bottle was built.
asdf_php_deps_walk() {
  local core_ref="${1:-master}"
  local root_content seen queue name content root_url tag digest
  root_content="$(cat)"
  seen=""
  queue=()

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    queue+=("$name")
  done < <(printf '%s' "$root_content" | asdf_php_formula_dependencies)

  while [[ ${#queue[@]} -gt 0 ]]; do
    name="${queue[0]}"
    queue=("${queue[@]:1}")

    # Dedup
    if printf '%s\n' "$seen" | grep -Fxq -- "$name"; then
      continue
    fi
    seen="${seen}"$'\n'"${name}"

    if ! content="$(asdf_php_formula_fetch_core "$name" "$core_ref")"; then
      asdf_php_warn "no homebrew-core formula for dep '$name' at ref ${core_ref:0:8}; skipping"
      continue
    fi

    if ! root_url="$(printf '%s' "$content" | asdf_php_formula_bottle_root_url)"; then
      root_url="$ASDF_PHP_DEPS_CORE_ROOT_URL"
    fi

    if ! read -r tag digest < <(printf '%s' "$content" | asdf_php_formula_bottle_resolve); then
      asdf_php_warn "no bottle for '$name' on $(asdf_php_host_tag) (or fallbacks); skipping"
      continue
    fi

    echo "$name $root_url $tag $digest"

    # Enqueue transitive runtime deps
    while IFS= read -r tdep; do
      [[ -z "$tdep" ]] && continue
      queue+=("$tdep")
    done < <(printf '%s' "$content" | asdf_php_formula_dependencies)
  done
}

# Walk transitive runtime-dep DAG for a php extension. Reads the root
# ext formula content from stdin. Extension formulas can reference
# sibling extensions in shivammathur/homebrew-extensions via a fully
# qualified `shivammathur/extensions/<name>@<majmin>` string, and
# unqualified names for homebrew-core deps.
#
# Args:
#   $1: majmin (used to filter out edges pointing at php itself,
#       which is already installed by our plugin).
#   $2: skip_set — newline-separated list of formula base-names to
#       skip (typically what's already staged in Cellar/). Optional.
#
# Emits `<repo-scoped-name> <root_url> <tag> <digest>` per unique dep.
# The `repo-scoped-name` for ext-tap formulas is prefixed with
# `shivammathur/extensions/` so the caller can compute the correct
# GHCR path; for core deps it's the bare formula name.
asdf_php_deps_walk_ext() {
  local majmin="${1:?asdf_php_deps_walk_ext: majmin required}"
  local skip_set="${2:-}"
  local ext_root_default="https://ghcr.io/v2/shivammathur/extensions"

  local root_content seen queue full name content root_url tag digest
  root_content="$(cat)"
  seen=""
  queue=()

  # Seed with direct deps of the root ext.
  while IFS= read -r full; do
    [[ -z "$full" ]] && continue
    queue+=("$full")
  done < <(printf '%s' "$root_content" | asdf_php_formula_dependencies)

  while [[ ${#queue[@]} -gt 0 ]]; do
    full="${queue[0]}"
    queue=("${queue[@]:1}")

    # Dedup by full identifier (so `foo` and `shivammathur/extensions/foo@8.1`
    # aren't conflated).
    if printf '%s\n' "$seen" | grep -Fxq -- "$full"; then
      continue
    fi
    seen="${seen}"$'\n'"${full}"

    # Skip anything explicitly opted out (usually deps already staged
    # from the base PHP install — no need to re-fetch).
    name="${full##*/}"
    if [[ -n "$skip_set" ]] && printf '%s\n' "$skip_set" | grep -Fxq -- "$name"; then
      continue
    fi

    # Also skip php itself — it's already installed by the plugin.
    [[ "$name" == "php@${majmin}" || "$name" == "php" ]] && continue

    # Route to the right tap fetcher.
    if [[ "$full" == shivammathur/extensions/* ]]; then
      local ext_name="${full#shivammathur/extensions/}"
      if ! content="$(asdf_php_formula_fetch_ext "$ext_name")"; then
        asdf_php_warn "no shivammathur/extensions formula for '$ext_name'; skipping"
        continue
      fi
      root_url="$ext_root_default"
    else
      # Unqualified — homebrew-core.
      if ! content="$(asdf_php_formula_fetch_core "$full")"; then
        asdf_php_warn "no homebrew-core formula for dep '$full'; skipping"
        continue
      fi
      if ! root_url="$(printf '%s' "$content" | asdf_php_formula_bottle_root_url)"; then
        root_url="$ASDF_PHP_DEPS_CORE_ROOT_URL"
      fi
    fi

    if ! read -r tag digest < <(printf '%s' "$content" | asdf_php_formula_bottle_resolve); then
      asdf_php_warn "no bottle for '$full' on $(asdf_php_host_tag) (or fallbacks); skipping"
      continue
    fi

    echo "$full $root_url $tag $digest"

    # Enqueue transitive deps.
    while IFS= read -r tdep; do
      [[ -z "$tdep" ]] && continue
      queue+=("$tdep")
    done < <(printf '%s' "$content" | asdf_php_formula_dependencies)
  done
}
