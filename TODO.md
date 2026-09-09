# TODO

Explicitly deferred work. Each bullet is in scope someday, just not
right now. Ordered loosely by likely value, not by when they'll
happen.

## Pin ext-tap deps to a contemporary homebrew-core ref

<a id="full-dep-chain-for-heavy-c-extensions"></a>
`deps_walk_ext` resolves homebrew-core deps against `master`, so an
extension bottle gets whatever version of its C deps homebrew-core
ships *today*, not the ones it was linked against. When upstream
bumps a soname in between, the extension can't load.

Live example (2026-09): the `imagick@8.2` 3.8.1_2 bottle for
`arm64_tahoe` was built 2025-11-26 against imagemagick 7.1.2-8, which
shipped `libMagickWand-7.Q16HDRI.10.dylib`. homebrew-core is on
7.1.2-31 now, which ships `.11`. Everything downloads and relocates
cleanly; the two Magick refs just don't exist, and `asdf-php-ext`
rolls back naming them. Nothing to fix on our side until either the
tap rebuilds imagick or we pin.

`bin/download` already does the pinning for historical php installs:
`asdf_php_history_find_core_ref <iso-date>` → a homebrew-core sha, fed
to `deps_walk` as `core_ref`. The ext path needs the same, and the
open question is where the date comes from:

1. The bottle's GHCR manifest annotation
   (`org.opencontainers.image.created`): available before download,
   one extra request, no clone.
2. A shallow clone of `shivammathur/homebrew-extensions` + `git log`
   on the formula, mirroring `history.bash`. Consistent with what's
   there, but a second ~10MB clone.

Caveats either way: old bottles may not have an `arm64_tahoe` build
(the host-tag fallback chain covers some of this), and the ext's deps
would then come from a different era than the base php install's,
which `skip_set` leaves at `master`.

Symptom to guard against: `php -m` segfaulting mid-install. Covered by
`test/regression/ext-so-relocation.bats`, which builds a Mach-O with
an unresolvable `LC_LOAD_DYLIB` entry rather than depending on
imagick's dep tree, which changes over time.

## `.mise.toml` `ASDF_PHP_EXTS` for declarative extensions

`bin/install` reads `ASDF_PHP_EXTS` (comma-separated list) at the
end of its run and calls `asdf-php-ext install <name>` for each.
Then a repo can declare:

```toml
[tools]
php = "8.1.34"
[env]
ASDF_PHP_EXTS = "redis,igbinary,msgpack"
```

and a teammate's `git clone && mise install` lands a fully-
configured PHP + extension surface. Same wiring shape as
`ASDF_PHP_BUNDLE_COMPOSER=0` uses today, extended to a list.

## Alternative direction: `mracos/asdf-composer` sibling plugin

We ship composer as a raw phar bundled with php. Semantics: composer
follows the cwd's PHP pin via mise's shim. The principled alternative
is publishing a separate `asdf-composer` plugin so composer gets its
own `.tool-versions` entry with its own pin. Composer 2.x supports
PHP 7.2 through 8.4, so it truly is orthogonal.

Blocker: we did try `ubi:composer/composer@latest` and it fails
because composer publishes a PHAR, not a native binary. A dedicated
plugin (`list-all` from https://getcomposer.org/versions, `install`
downloads the versioned phar) is ~30 lines but a separate repo.

## `bin/latest-stable` asdf hook (only needed for upstream asdf)

Adds a proper hook for `asdf install php latest`. Mise already
resolves `@latest` to the last line of `bin/list-all` output (which
is our highest stable X.Y.Z), so `mise install php@latest` works
today without the hook. Upstream asdf (Ruby) requires the file
explicitly. Two lines:

```sh
#!/usr/bin/env bash
"$(dirname "$0")/list-all" | sort -V | tail -1
```

Nice-to-have if we ever care about asdf-native compatibility;
skipped for now since mise is the primary target.

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
