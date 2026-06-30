# TODO

Explicitly deferred work. Each bullet is in scope someday — just not
right now. Ordered loosely by likely value, not by when they'll
happen.

## PHP extensions support

The shivammathur tap also publishes pre-built PHP extensions:
`phpredis@<MAJMIN>`, `igbinary@<MAJMIN>`, `msgpack@<MAJMIN>`,
`xdebug@<MAJMIN>`, plus a couple dozen more, in
`shivammathur/homebrew-extensions`.

Shape: `mise install php-ext-redis@8.1` (or per-php sub-tools, or
`[ext]` config in `mise.toml`). Reuses the same bottle pull, dep
walk, relocate, codesign machinery. The new bit is: each extension
gets a `<ext>.ini` synthesized in
`<php-install>/etc/php/<MAJMIN>/conf.d/` pointing at its `.so`.

Probably the most impactful next iteration since Laravel projects
typically need `phpredis` + `igbinary` + `msgpack`.

## GH Actions CI

Matrix on `macos-14` / `macos-15` (and `macos-26` once GitHub
provides it) running `bin/install` for a curated version set,
asserting `php --version` matches and that a fixed list of
extensions load. Catches regressions when the tap or homebrew-core
changes their formula format.

Bats test suite would slot in here too — see Tests.

## Tests (bats)

Unit tests for `lib/*` parsers — version parsing, dependency
extraction (on_macos vs on_linux block handling), bottle digest
resolution with `cellar: :any` qualifiers. Fixtures from real
formula files at known refs.

Integration tests live in CI; bats tests run in isolation.

## Linux support

GHCR bottles include `arm64_linux` and `x86_64_linux` tags. Most of
the work is generalizing platform detection
(`asdf_php_host_tag` / `asdf_php_host_tag_fallbacks` in
`lib/utils.bash`).

The relocation strategy changes: Linux uses RPATH / RUNPATH, not
`@loader_path`. Brew's Linux bottles ship with `RUNPATH` references
like `$ORIGIN/../lib`. The placeholder rewriting still needs to
happen (with `patchelf --set-rpath` instead of `install_name_tool
-change`), and codesign becomes a no-op.

Worth a separate ADR (`docs/adrs/0002-linux-support.md`) covering
the relocation differences and how `bin/install` branches.

## Static-build migration (ADR 0001's escape valve)

If any of the migration triggers in
[ADR 0001](docs/adrs/0001-php-homebrew-bottles.md#migration-plan--bottles--self-built-statics)
fires (bottle format break, coverage gap, GHCR rate-limit pain,
static surface becomes acceptable), replace the binary source with
`static-php-cli` builds running in this repo's GH Actions matrix.

Open question for future-me: does the static path keep the same
`bin/list-all` / `bin/download` / `bin/install` shape, or does it
become a separate plugin?

## Self-update for the tap clone

Right now the tap clone refreshes at most once per 24h via a marker
file. That's mostly fine but means brand-new patches the tap just
shipped can take up to a day to be installable. Could be smarter:
refresh on demand when a requested version isn't on the local clone
yet.

## Resumable downloads

A failed `bin/download` (network blip on dep #45 of 50) currently
starts over. Could check existing tarballs against manifest sha256s
and skip already-verified ones.

## Better diagnostics

When `bin/install` fails partway through relocation, the partial
install dir is left behind and the next attempt's "remove previous"
heuristic blows it away with no record. A `<install>/.asdf-php-log`
that captures the install steps would help post-mortems.
