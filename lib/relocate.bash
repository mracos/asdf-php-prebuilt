#!/usr/bin/env bash
# Rewrite @@HOMEBREW_PREFIX@@ placeholders in Mach-O dylib references and
# re-codesign the modified binaries.
#
# Why this is needed:
#   homebrew-core bottles with `cellar: :any` ship Mach-O LC_LOAD_DYLIB
#   entries like `@@HOMEBREW_PREFIX@@/opt/openssl@3/lib/libssl.3.dylib`.
#   dyld cannot resolve `@@HOMEBREW_PREFIX@@` (not a valid `@`-prefix)
#   and ends up loading whatever system libssl it finds, which has a
#   different ABI — symbol lookup fails (e.g. _SSL_CIPHER_get_bits).
#
#   shivammathur/homebrew-php's php@* bottles use `cellar: :any_skip_relocation`
#   and ship `@loader_path/../../../../opt/...` directly, so PHP itself
#   needs no rewriting; but its transitive deps in homebrew-core do.
#
# What we rewrite:
#   @@HOMEBREW_PREFIX@@/X  → @loader_path/<up>/X
#   @@HOMEBREW_CELLAR@@/X  → @loader_path/<up>/Cellar/X
#   Applies to LC_LOAD_DYLIB and LC_ID_DYLIB.
#
# Where the `<up>` count comes from:
#   For a file at <prefix>/Cellar/<formula>/<version>/<subpath>/<file>,
#   `<up>` is one `../` per directory between the file and <prefix>.
#   For typical bin/<exe> and lib/<dylib>, that's 4 ups.
#
#   `<up>` is a property of where the file *is loaded from*, not of
#   where it was shipped. Anything that copies a Mach-O file elsewhere
#   in the prefix has to relocate it again at the destination. See
#   `_stage_ext_so` in share/asdf-php-ext.

set -euo pipefail

# Map a placeholder-prefixed path to its @loader_path-relative form.
# Args: <path> <up>. Result lands in $asdf_php_relocated_path; returns
# 1 when the path carries no placeholder.
#
# Sets a global instead of echoing: this runs once per dylib reference
# per file (tens of thousands of times per install), and a command
# substitution costs a fork and a pipe every time.
asdf_php_relocate_map_path() {
  local p="$1" up="$2"
  case "$p" in
    @@HOMEBREW_PREFIX@@/*)
      asdf_php_relocated_path="@loader_path/${up}/${p#@@HOMEBREW_PREFIX@@/}" ;;
    @@HOMEBREW_CELLAR@@/*)
      asdf_php_relocated_path="@loader_path/${up}/Cellar/${p#@@HOMEBREW_CELLAR@@/}" ;;
    *)
      asdf_php_relocated_path=""
      return 1 ;;
  esac
}

# The "../../../.." that walks from <file> back up to <install_path>.
# Result lands in $asdf_php_relocate_up (global, same reason as above).
asdf_php_relocate_up_for() {
  local rel="${1#${2%/}/}" up=""
  while [[ "$rel" == */* ]]; do
    rel="${rel#*/}"
    up="${up}../"
  done
  asdf_php_relocate_up="${up%/}"
}

# Rewrite a single Mach-O file's placeholder dylib refs and re-codesign.
# Failures are warned and skipped (one file shouldn't block the whole install).
# Args: <file> <install_path>
#
# Fork budget matters here: relocate_all calls this ~2k times per
# install and every `$(...)` / `<(...)` is a pipe. A shell that runs out
# of descriptors mid-walk fails with "cannot make pipe for command
# substitution", after which the dep loop reads from a closed fd and
# leaves the file silently unrelocated: a broken install that still
# reports success. Everything below stays in-process except `otool` and
# the rewrite tools themselves.
asdf_php_relocate_file() {
  local file="$1" install_path="$2"
  asdf_php_relocate_up_for "$file" "$install_path"
  local up="$asdf_php_relocate_up"

  local touched=0 out line dep

  if ! out="$(otool -L "$file" 2>/dev/null)"; then
    asdf_php_warn "otool -L failed for $file; left unrelocated"
    return 0
  fi

  # `otool -L` prints the file's own name unindented, then one
  # tab-indented "<path> (compatibility version ...)" per reference.
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]+([^[:space:]]+) ]] || continue
    dep="${BASH_REMATCH[1]}"
    asdf_php_relocate_map_path "$dep" "$up" || continue
    if install_name_tool -change "$dep" "$asdf_php_relocated_path" "$file" 2>/dev/null; then
      touched=1
    else
      asdf_php_warn "install_name_tool -change failed for $file: $dep"
    fi
  done <<< "$out"

  # `otool -D` prints the file's own name, then LC_ID_DYLIB on line 2
  # (unindented, unlike -L).
  local id="" n=0
  if out="$(otool -D "$file" 2>/dev/null)"; then
    while IFS= read -r line; do
      n=$((n + 1))
      if [[ "$n" -eq 2 ]]; then
        id="${line%% *}"
        break
      fi
    done <<< "$out"
  fi
  if [[ -n "$id" ]] && asdf_php_relocate_map_path "$id" "$up"; then
    if install_name_tool -id "$asdf_php_relocated_path" "$file" 2>/dev/null; then
      touched=1
    else
      asdf_php_warn "install_name_tool -id failed for $file"
    fi
  fi

  if [[ "$touched" -eq 1 ]]; then
    codesign --force --sign - "$file" 2>/dev/null \
      || asdf_php_warn "codesign failed for $file"
  fi
}

# True if a regular file is Mach-O (any subtype: 32/64-bit, FAT, x86_64, arm64).
asdf_php_is_macho() {
  local f="$1"
  [[ -f "$f" && ! -L "$f" ]] || return 1
  local magic
  magic="$(xxd -p -l 4 "$f" 2>/dev/null)"
  case "$magic" in
    cefaedfe|cffaedfe|feedface|feedfacf|cafebabe|bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}

# Walk all Mach-O files under Cellar/ and rewrite their placeholders.
# Args: <install_path>
asdf_php_relocate_all() {
  local install_path="$1"
  local count=0 f
  while IFS= read -r f; do
    asdf_php_is_macho "$f" || continue
    asdf_php_relocate_file "$f" "$install_path"
    count=$((count + 1))
  done < <(find "$install_path/Cellar" -type f \
    \( -path '*/bin/*' -o -path '*/sbin/*' -o -path '*/lib/*' \
    -o -path '*/libexec/*' -o -path '*/ext/*' \) 2>/dev/null)
  asdf_php_log "relocated $count Mach-O files"
}

# Text-file placeholder rewrite. Bottles ship shell/PHP scripts like
# `pecl`, `pear`, `phpize`, `php-config`, `phar.phar` with
# `@@HOMEBREW_CELLAR@@/...` paths hardcoded in their shebangs / exec
# lines. Not Mach-O, so our LC_LOAD_DYLIB relocator skips them, and
# bash treats the unresolved `@@` prefix as a relative path (yielding
# nonsense like `<cwd>/@@HOMEBREW_CELLAR@@/php@8.1/.../bin/php: No such
# file or directory`). Sed-rewrite these in place.
# Args: <install_path>
asdf_php_relocate_text_scripts() {
  local install_path="$1"
  local count=0 f

  # Only look in Cellar/*/bin, Cellar/*/sbin, Cellar/*/libexec — that's
  # where the entry-point scripts live. include/share/lib have build
  # artifacts that carry the same placeholders but PHP doesn't consult
  # them at runtime.
  while IFS= read -r f; do
    asdf_php_is_macho "$f" && continue
    # .phar archives can't be rewritten at all: the whole file is
    # SHA1-signed at the tail (Phar's built-in integrity check). Even a
    # shebang tweak invalidates `Phar::mapPhar()`. Leave the placeholder
    # in place and have the top-level `bin/phar` wrapper invoke
    # `php phar.phar` directly, bypassing the shebang entirely.
    [[ "$f" == *.phar ]] && continue
    grep -qF '@@HOMEBREW_' "$f" 2>/dev/null || continue

    # LC_ALL=C so BSD sed treats bytes as bytes (some scripts contain
    # non-UTF-8 payloads and locale-aware sed rejects them).
    LC_ALL=C sed -i '' \
      -e "s|@@HOMEBREW_CELLAR@@|${install_path}/Cellar|g" \
      -e "s|@@HOMEBREW_PREFIX@@|${install_path}|g" "$f"
    count=$((count + 1))
  done < <(find "$install_path/Cellar" -type f \
    \( -path '*/bin/*' -o -path '*/sbin/*' -o -path '*/libexec/*' \) 2>/dev/null)
  asdf_php_log "relocated $count text scripts"
}
