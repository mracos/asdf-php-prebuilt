# TODO

Explicitly deferred work. Each bullet is in scope someday, just not
right now. Ordered loosely by likely value, not by when they'll
happen.

## Full dep chain for heavy C extensions

<a id="full-dep-chain-for-heavy-c-extensions"></a>
`asdf-php-ext install imagick` currently pulls the imagick, imagemagick,
libomp, libheif, libde265, x265 bottles and stops. imagick.so
links against libraries buried deeper (jbig, tiff, lcms, freetype,
pango, cairo, ghostscript, and probably more) that we don't fetch.
Result: dyld exits non-zero on `php -m`, cmd_install detects it, and
rolls back. imagick just isn't installable through this path.

Two mechanisms to fix. Either:

1. Fully walk homebrew-core deps of ext-tap formulas. `deps_walk_ext`
   already recurses through the tap side; the missing piece is
   pushing homebrew-core deps' own `depends_on` chains, not just
   their bottles. That means switching from "resolve one level"
   to full transitive walk on the homebrew-core side too, with
   dedup + cycle protection.
2. Post-install dyld scan: `otool -L` each staged `.so`, walk the
   `@loader_path/../../../../opt/<X>/lib/<Y>.dylib` targets, verify
   each exists, fetch the missing ones. Simpler code, roughly the
   same effect. Doesn't reuse the tap formula's `depends_on` info.

Approach 2 is probably the smaller change. Approach 1 keeps the
formula file as single source of truth. Pick when someone actually
needs imagick.

Symptom to guard against: `php -m` segfaulting mid-install. The
rollback in `cmd_install` catches it today; adding a regression test
requires an intentionally-broken .so (fake shared lib with an
unresolvable LC_LOAD_DYLIB entry) instead of relying on imagick
specifically since its dep tree changes over time.

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
