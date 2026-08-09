# asdf-php-prebuilt

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
mise plugin install php https://github.com/mracos/asdf-php-prebuilt
mise install php@8.1.34

# asdf
asdf plugin add php https://github.com/mracos/asdf-php-prebuilt
asdf install php 8.1.34
```

Historical patch versions (those the tap no longer pins on `master`)
also work. The plugin walks the tap's git history to find the right
commit:

```sh
mise install php@8.1.27   # any patch that's ever been in the tap
```

Every install also bundles the latest stable [Composer](https://getcomposer.org)
as a raw phar at `<install>/bin/composer`. Its `#!/usr/bin/env php`
shebang resolves through mise's shim, so composer follows whichever
PHP the cwd pins (same semantics as every other mise-managed tool).

```sh
mise exec php -- composer --version
```

Direct `<install>/bin/composer` also works from a directory pinning a
matching PHP version. From an unpinned or wrong-pinned cwd you'll hit
mise's usual "Tool not installed for shim: php" — invoke through
`mise exec` when in doubt.

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

To add a shared extension that isn't bundled (redis, xdebug,
igbinary, msgpack, ...), pull the prebuilt bottle from
`shivammathur/homebrew-extensions`:

```sh
mise exec php -- asdf-php-ext install redis
```

This downloads the extension bottle and its ext-tap sibling deps
(e.g. redis pulls in igbinary + msgpack), stages every `.so` in the
unified ext dir, relocates placeholders, writes the `50-*.ini`
files, and verifies `php -m` loads them all. If verification fails
(usually a missing runtime dylib the walker didn't catch, see
[known limitations](#known-limitations)) the install rolls itself
back so `php` stays runnable.

The pecl compile path also works for extensions that aren't in the
tap:

```sh
mise exec php -- pecl install redis
mise exec php -- asdf-php-ext enable redis
```

Either path lands the `.so` at `<install>/opt/php@<MAJMIN>/pecl/<api>/`
and writes `<install>/etc/php/<MAJMIN>/conf.d/50-<name>.ini`.
`disable` removes the ini file only; the `.so` stays on disk so
`enable` can bring it back.

The conf.d layout is:

```text
00-asdf-php.ini      extension_dir bootstrap (do not touch)
10-<name>.ini        bundled by asdf-php at install time (opcache, intl if shared)
50-<name>.ini        enabled by asdf-php-ext (enable, install)
```

`disable` refuses to remove `00-*.ini`.

## PHP ini settings

`asdf-php-ini` manages user ini overrides in
`<install>/etc/php/<MAJMIN>/conf.d/99-asdf-php-user.ini`. The `99-`
prefix loads last in the conf.d scan order, so user settings win
over `10-*` (bundled) and `50-*` (enabled) entries.

```sh
mise exec php -- asdf-php-ini list                        # user settings only
mise exec php -- asdf-php-ini list --all                  # every directive with effective value
mise exec php -- asdf-php-ini keys                        # every directive name (one per line)
mise exec php -- asdf-php-ini set memory_limit 512M       # set / update
mise exec php -- asdf-php-ini set date.timezone UTC
mise exec php -- asdf-php-ini get memory_limit            # effective value via php ini_get
mise exec php -- asdf-php-ini unset memory_limit
```

Shell completions ship at `<install>/share/completions/`:

```sh
# zsh: add the completions dir to your fpath before compinit
fpath=(~/.local/share/mise/installs/php/*/share/completions $fpath)
autoload -Uz compinit && compinit

# bash
source ~/.local/share/mise/installs/php/*/share/completions/asdf-php-ini.bash
```

Tab-completes subcommands (`list`, `get`, `set`, `unset`, `keys`) and
the second positional for `get` / `set` / `unset` against `asdf-php-ini
keys` output (all 280+ directives PHP knows about).

Values containing whitespace, `;`, `#`, or `"` get double-quoted
automatically. `set` is idempotent: setting the same key twice
replaces, doesn't append. `get` returns the effective value via
`php -r 'echo ini_get(...)'`, so it reflects the full conf.d merge,
not just what asdf-php-ini has written.

## Platform support

| OS                          | arch   | Status                         |
|-----------------------------|--------|--------------------------------|
| macOS 11+ (Big Sur to Tahoe) | arm64  | Working                        |
| macOS 11+ (Big Sur to Tahoe) | x86_64 | Should work; untested          |
| Linux                       | any    | Not supported (see [TODO](TODO.md)) |

Host platform detection walks back through brew codename tags
(`arm64_tahoe` → `arm64_sequoia` → `arm64_sonoma` → ...) so newer hosts
install older bottles via forward compatibility.

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

## Testing + linting

```sh
npm install              # get bats + shellcheck + markdownlint + prettier
npm test                 # unit tests (fast, offline, ~1s)
npm run test:regression  # regression tests (requires an active install)
npm run test:all         # unit + regression
npm run lint             # shellcheck + markdownlint + prettier
```

Individual lint targets: `lint:shell`, `lint:md`, `lint:fmt`. CI
runs `lint` before the test jobs on every push.

Tests + lint policy: [CONTRIBUTING](CONTRIBUTING.md).

## Documentation

- [ADR 0001](docs/adrs/0001-php-homebrew-bottles.md) explains why
  bottles, how the historical-resolution path works, and the
  migration plan to self-built static binaries.
- [ADR 0002](docs/adrs/0002-extension-management.md) covers the
  extension subsystem: unified `extension_dir`, conf.d 00/10/50
  convention, `asdf-php-ext` CLI, pecl vs tap-bottle install paths,
  rollback on verify failure.
- [CHANGELOG](CHANGELOG.md) tracks releases.
- [TODO](TODO.md) explicitly deferred work.
- [Troubleshooting](docs/troubleshooting.md) common install failures
  and fixes.
- [CONTRIBUTING](CONTRIBUTING.md) local dev setup.
- [How it works](/docs/how-it-works.md) tells a bit about internals.

## License

MIT. See [LICENSE](LICENSE).
