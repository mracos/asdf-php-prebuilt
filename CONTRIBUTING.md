# Contributing

## Local development

Link this checkout into mise as the active php plugin:

```sh
mise plugin uninstall php   # if you have one already
mise plugin link php /path/to/this/repo
```

mise calls `bin/list-all`, `bin/download`, and `bin/install` from
this directory directly — edits take effect on the next `mise
install` invocation, no reinstall needed. Clear mise's version cache
after touching `bin/list-all`:

```sh
mise cache clear
```

## Trying changes without going through mise

```sh
tmp=$(mktemp -d)
export ASDF_INSTALL_VERSION=8.1.34
export ASDF_DOWNLOAD_PATH=$tmp/dl
export ASDF_INSTALL_PATH=$tmp/install
mkdir -p "$ASDF_DOWNLOAD_PATH" "$ASDF_INSTALL_PATH"

./bin/download
./bin/install
"$ASDF_INSTALL_PATH/bin/php" --version
```

`$ASDF_DOWNLOAD_PATH` ends up with `manifest.txt` plus one bottle
tarball per formula. `$ASDF_INSTALL_PATH` ends up with the
relocated, self-contained install.

To exercise the historical path, pick a non-HEAD patch:

```sh
export ASDF_INSTALL_VERSION=8.1.27
```

## Code conventions

- **Bash 3.2 safe.** macOS still ships `/bin/bash` 3.2. No
  associative arrays, no `${var^^}`, no `mapfile` / `readarray`.
  Use indexed arrays with `${arr[@]+"${arr[@]}"}` to handle empty
  cases under `set -u`.
- **`set -euo pipefail` at the top of every script and lib file.**
  Watch for SIGPIPE traps: `cmd | head -1` will fail under pipefail
  if `cmd` writes more than one line. Use parameter expansion
  (`var="${full%%$'\n'*}"`) instead.
- **Function naming.** Public helpers prefixed `asdf_php_<module>_*`
  (matches the file: `lib/formula.bash` → `asdf_php_formula_*`).
  Private helpers prefixed with `_`.
- **Stdin for content, args for parameters.** Parsers that consume
  formula content read it from stdin; identifiers (formula name,
  platform tag, version) come through positional args. Keeps the
  callers composable via pipes.
- **Cache by content key, not by version.** Formula caches include
  the ref (commit sha or branch name) so historical and current
  fetches coexist.

## Architecture decisions

Significant choices and trade-offs live in [docs/adrs/](docs/adrs/).
If you're proposing structural changes (a new binary source, a
different relocation strategy, Linux support), write or extend an
ADR first and link it from the PR description.

The migration trigger conditions for switching off bottles to
self-built static binaries are in
[docs/adrs/0001-php-homebrew-bottles.md](docs/adrs/0001-php-homebrew-bottles.md#migration-plan--bottles--self-built-statics).

## Tests

There aren't any yet. Verification is manual: end-to-end via the
recipe above, plus checking `php -m` for the expected extensions.
A bats suite is on the [TODO](TODO.md).

## Commits

`<scope>: <what changed>` in present-tense imperative. Scopes match
the file/area touched (`download:`, `install:`, `history:`,
`docs:`, etc.). One logical change per commit; cluster fixes for
the same change into one commit, not several.
