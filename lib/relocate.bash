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

set -euo pipefail

# Count directories above a file inside the install prefix.
# Args: <file> <install_path>
# Returns: integer depth (4 for <prefix>/Cellar/X/Y/bin/foo)
asdf_php_relocate_depth() {
  local file="$1" install_path="$2"
  local rel="${file#${install_path%/}/}"
  awk -v s="$rel" 'BEGIN{n=gsub("/","/",s); print n}'
}

# Build the "../../../.." prefix for a given depth.
asdf_php_relocate_up() {
  local depth="$1" up="" i
  for ((i=0; i<depth; i++)); do up="${up}../"; done
  echo "${up%/}"
}

# Rewrite a single Mach-O file's placeholder dylib refs and re-codesign.
# Failures are warned and skipped (one file shouldn't block the whole install).
# Args: <file> <install_path>
asdf_php_relocate_file() {
  local file="$1" install_path="$2"
  local depth up
  depth="$(asdf_php_relocate_depth "$file" "$install_path")"
  up="$(asdf_php_relocate_up "$depth")"

  local touched=0 dep new id

  # Map a placeholder-prefixed path to a @loader_path-relative form.
  # Echoes the rewritten path, or echoes empty and returns 1 if no
  # placeholder matched.
  _asdf_php_relocate_path() {
    local p="$1"
    if [[ "$p" == @@HOMEBREW_PREFIX@@/* ]]; then
      echo "@loader_path/${up}/${p#@@HOMEBREW_PREFIX@@/}"
    elif [[ "$p" == @@HOMEBREW_CELLAR@@/* ]]; then
      echo "@loader_path/${up}/Cellar/${p#@@HOMEBREW_CELLAR@@/}"
    else
      return 1
    fi
  }

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    new="$(_asdf_php_relocate_path "$dep")" || continue
    if install_name_tool -change "$dep" "$new" "$file" 2>/dev/null; then
      touched=1
    else
      asdf_php_warn "install_name_tool -change failed for $file: $dep"
    fi
  done < <(otool -L "$file" 2>/dev/null | awk 'NR>1 {print $1}')

  id="$(otool -D "$file" 2>/dev/null | awk 'NR==2 {print $1}')"
  if new="$(_asdf_php_relocate_path "$id")"; then
    if install_name_tool -id "$new" "$file" 2>/dev/null; then
      touched=1
    else
      asdf_php_warn "install_name_tool -id failed for $file"
    fi
  fi
  unset -f _asdf_php_relocate_path

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
  magic="$(head -c 4 "$f" 2>/dev/null | xxd -p 2>/dev/null)"
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
