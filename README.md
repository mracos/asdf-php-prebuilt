# asdf-php

asdf/mise plugin that installs PHP on macOS by wrapping
[`shivammathur/homebrew-php`](https://github.com/shivammathur/homebrew-php)
bottles. No Homebrew runtime dependency. Bottles and their transitive
deps are pulled from GHCR, relocated with `install_name_tool`, and
ad-hoc codesigned into the plugin's install prefix.

## Why this exists

The upstream `asdf-php` / `vfox-php` plugins build PHP from source and
hardcode `brew --prefix libxml2` in their install scripts. On modern
macOS toolchains with libxml2 ≥ 2.14, that build is broken for any PHP
version that didn't backport the libxml2 const-correctness fix (which
is everything in the 8.1 series, EOL since Dec 2024, plus a long tail
of older patch releases). This plugin sidesteps the compile path
entirely.

Full background, decision, and migration plan: [ADR
0001](docs/adrs/0001-php-homebrew-bottles.md).

## Install

```sh
# mise
mise plugin install php https://github.com/mracos/asdf-php
mise install php@8.1.34

# asdf
asdf plugin add php https://github.com/mracos/asdf-php
asdf install php 8.1.34
```

Historical patch versions (those the tap no longer pins on `master`)
also work. The plugin walks the tap's git history to find the right
commit:

```sh
mise install php@8.1.27   # any patch that's ever been in the tap
```

Every install also bundles the latest stable [Composer](https://getcomposer.org)
at `<install>/bin/composer`. Nothing extra to do:

```sh
mise exec php -- composer --version
```

To skip the composer bundle: `ASDF_PHP_BUNDLE_COMPOSER=0 mise install php@...`.

## PHP extensions

Extensions are managed with the `asdf-php-ext` helper, shipped in
`<install>/bin/` alongside `php` and `composer`.

```sh
# what's on disk (opcache always; intl too on newer patches; anything
# you've compiled via pecl)
mise exec php -- asdf-php-ext list

# turn on / off a shared extension that already has a .so file
mise exec php -- asdf-php-ext enable opcache
mise exec php -- asdf-php-ext disable opcache
```

To add a shared extension that isn't in the bottle (redis, xdebug,
igbinary, msgpack, ...), compile it with pecl and enable it:

```sh
mise exec php -- pecl install redis
mise exec php -- asdf-php-ext enable redis
```

The `.so` lands at `<install>/opt/php@<MAJMIN>/pecl/<api>/`, and enable
writes `<install>/etc/php/<MAJMIN>/conf.d/50-<name>.ini`. Extension
uninstall / disable removes the ini file only; the `.so` stays on disk.

The conf.d layout is:

```
00-asdf-php.ini      extension_dir bootstrap (do not touch)
10-<name>.ini        bundled by asdf-php at install time (opcache, intl if shared)
50-<name>.ini        enabled by asdf-php-ext (enable, install)
```

`disable` refuses to remove `00-*.ini`.

## What `mise install` does under the hood

1. Read `Formula/php@<MAJMIN>.rb` from the tap. If the requested patch
   matches what HEAD pins, skip to step 3.
2. Otherwise walk `shivammathur/homebrew-php`'s git history (shallow
   clone cached at `~/.cache/asdf-php/tap-clone/`) for the latest
   commit pinning that patch. Resolve a contemporary
   `Homebrew/homebrew-core` ref via `gh api commits?until=<iso>` so
   transitive deps match the era when the bottle was built.
3. Pull the PHP bottle and every transitive runtime dep from GHCR
   anonymously, verifying each blob's sha256.
4. Extract under `<install>/Cellar/`, plant `<install>/opt/<formula>`
   symlinks. PHP's bottled binary uses
   `@loader_path/../../../../opt/<formula>/lib/<dylib>` references, so
   this layout makes everything resolve.
5. Walk every Mach-O file, rewrite `@@HOMEBREW_PREFIX@@` and
   `@@HOMEBREW_CELLAR@@` placeholders to `@loader_path`-relative form
   via `install_name_tool -change` / `-id`, ad-hoc re-codesign.
6. Text-relocate shell/PHP scripts in the Cellar (`pecl`, `pear`,
   `phpize`, `php-config`) with the same placeholders. Skip `phar.phar`
   because its built-in SHA1 signature was computed for the resolved
   shebang and can't be rewritten without invalidating.
7. Generate `<install>/bin/<exe>` wrapper scripts that export
   `PHPRC`, `PHP_INI_SCAN_DIR`, and `PHP_PEAR_SYSCONF_DIR` pointing at
   `<install>/etc/php/<MAJMIN>/`. Without those env vars, PHP and PEAR
   default to `/opt/homebrew/etc/php/<MAJMIN>/` (baked into the
   binary at brew's build time) and pick up the host's stale config.
8. Copy and placeholder-rewrite the bottle's `.bottle/etc/` files.
   Also perl-fix the PHP-serialized `s:N:"..."` length prefixes in
   `pear.conf` because sed rewrote the values but not the lengths,
   which would otherwise make PEAR fall back to compiled-in defaults.
9. Unify `extension_dir` on the `pecl/<api>/` path (where pecl compiles
   new `.so` files). Symlink each bundled `.so` from `lib/php/<api>/`
   into `pecl/<api>/` so both bundled and pecl-installed extensions
   live in one directory.
10. Generate `conf.d/00-asdf-php.ini` (extension_dir) and one
    `conf.d/10-<name>.ini` per shared extension the bottle shipped.
11. Symlink `<install>/etc/openssl@3/cert.pem` to macOS's system store
    (`/etc/ssl/cert.pem`). PHP's `openssl.cafile` in php.ini points
    there, and without the symlink SSL streams fail with "failed
    loading cafile stream".
12. Drop `<install>/bin/composer` (latest stable phar) and
    `<install>/bin/asdf-php-ext` (extension manager).
13. Verify by running `<install>/bin/php --version`.

Roughly 110 seconds end-to-end on a fast network. ~250MB of bottles
across ~50 transitive deps. The 24-hour tap-clone cache and the
content-addressable GHCR blobs mean second installs of the same
version are mostly download-bound.

## Platform support

| OS                          | arch   | Status                         |
|-----------------------------|--------|--------------------------------|
| macOS 11+ (Big Sur to Tahoe) | arm64  | Working                        |
| macOS 11+ (Big Sur to Tahoe) | x86_64 | Should work; untested          |
| Linux                       | any    | Not supported (see [TODO](TODO.md)) |

Host platform detection walks back through brew codename tags
(`arm64_tahoe` → `arm64_sequoia` → `arm64_sonoma` → ...) so newer hosts
install older bottles via forward compatibility.

## Caching / state directories

| Path                                 | What |
|--------------------------------------|------|
| `~/.cache/asdf-php/tap-clone/`       | shallow clone of `shivammathur/homebrew-php` (~10MB). Refreshed at most once per 24h. |
| `~/.cache/asdf-php/formula-*.rb`     | per-(formula, ref) on-disk formula cache. |
| `~/.cache/asdf-php/core-ref-*.sha`   | resolved homebrew-core sha per timestamp. |
| `<mise-installs>/php/<version>/`     | the install prefix. Fully self-contained, safe to `rm -rf`. |

## Requirements

- macOS 11+ (Big Sur or newer)
- `git`, `curl`, `awk`, `perl`, `bash` 3.2+ (macOS defaults are fine)
- `gh` CLI authenticated (`gh auth login`) is only needed for
  historical patch installs. Current-tap installs work without it.
- `jq` is NOT required.

## Known limitations

- macOS only. Linux bottles exist on GHCR but this plugin doesn't
  handle them yet (see [TODO](TODO.md)).
- Coverage is bounded by the tap. PHP versions that predate
  `shivammathur/homebrew-php` (< 5.6) aren't installable.
- `phar.phar` (the phar CLI archive) can't be wrapped. Its built-in
  SHA1 signature was computed by brew for the resolved-path shebang
  and can't be rewritten. Users who need Phar functionality can use
  the `Phar::` API from their own PHP scripts.
- Extensions with heavy C dependencies (imagemagick for imagick,
  etc.) still need those libraries installed separately. `pecl
  install imagick` will fail if it can't find `MagickWand`, for
  example. Long-term direction: pull prebuilt extension bottles from
  `shivammathur/homebrew-extensions` (in progress).
- `asdf-php-ext install imagick` fetches the bottle chain but
  imagick's runtime graph (imagemagick, libheif, libde265, x265,
  freetype, jbig, tiff, cairo, pango, ghostscript, ...) exceeds what
  the current dep walker resolves. The install rolls itself back
  cleanly on the resulting segfault so PHP stays runnable, but the
  extension doesn't load. Track:
  [TODO.md](TODO.md#full-dep-chain-for-heavy-c-extensions).

## Testing

```sh
npm install              # get bats
npm test                 # unit tests (fast, offline, ~1s)
npm run test:regression  # regression tests (requires an active install)
npm run test:all         # both
```

Tests are documented in [CONTRIBUTING](CONTRIBUTING.md).

## Documentation

- [ADR 0001](docs/adrs/0001-php-homebrew-bottles.md) explains why
  bottles, how the historical-resolution path works, and the
  migration plan to self-built static binaries.
- [CHANGELOG](CHANGELOG.md) tracks releases.
- [TODO](TODO.md) explicitly deferred work.
- [Troubleshooting](docs/troubleshooting.md) common install failures
  and fixes.
- [CONTRIBUTING](CONTRIBUTING.md) local dev setup.

## License

MIT. See [LICENSE](LICENSE).
