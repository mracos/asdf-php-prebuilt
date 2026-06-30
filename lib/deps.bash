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
