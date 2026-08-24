# asdf-php-prebuilt

[![test](https://github.com/mracos/asdf-php-prebuilt/actions/workflows/test.yml/badge.svg)](https://github.com/mracos/asdf-php-prebuilt/actions/workflows/test.yml)

PHP plugin for [asdf](https://asdf-vm.com) and [mise](https://mise.jdx.dev)
that installs prebuilt [`shivammathur/homebrew-php`](https://github.com/shivammathur/homebrew-php)
bottles on macOS instead of compiling from source. No Homebrew runtime
dependency: bottles and their transitive deps are pulled from GHCR, relocated
with `install_name_tool`, and ad-hoc codesigned into the install prefix.

The upstream `asdf-php` / `vfox-php` plugins build from source and hardcode
`brew --prefix libxml2`, which is broken on toolchains with libxml2 >= 2.14 for
every PHP that didn't backport the const-correctness fix (all of 8.1, EOL since
Dec 2024, plus a long tail of older patches). This plugin skips the compile path
entirely. Rationale: [ADR 0001](docs/adrs/0001-php-homebrew-bottles.md).

## Install

```sh
# mise
mise plugin install php https://github.com/mracos/asdf-php-prebuilt
mise install php@8.1.34

# asdf
asdf plugin add php https://github.com/mracos/asdf-php-prebuilt
asdf install php 8.1.34
```

Historical patch versions work too (those the tap no longer pins on `master`).
The plugin walks the tap's git history for the commit that pinned them:

```sh
mise install php@8.1.27
```

## Composer

Every install bundles the latest stable [Composer](https://getcomposer.org) as a
raw phar at `<install>/bin/composer`. Its `#!/usr/bin/env php` shebang resolves
through mise's shim, so composer follows whichever PHP the cwd pins, same
semantics as every other mise-managed tool.

```sh
mise exec php -- composer --version
```

Calling `<install>/bin/composer` directly works from a directory pinning a
matching PHP version; from an unpinned cwd you'll hit mise's "Tool not installed
for shim: php". Skip the bundle with `ASDF_PHP_BUNDLE_COMPOSER=0`.

## Extensions

`asdf-php-ext` ships in `<install>/bin/` alongside `php` and `composer`. It lists
what's on disk, toggles a shared `.so` on and off, and pulls prebuilt extension
bottles from
[`shivammathur/homebrew-extensions`](https://github.com/shivammathur/homebrew-extensions):

```sh
mise exec php -- asdf-php-ext install redis
mise exec php -- asdf-php-ext --help
```

`install` also fetches the ext-tap siblings (redis brings igbinary and msgpack),
writes the `50-*.ini` files, and verifies `php -m` loads them. On failure it
rolls itself back so `php` stays runnable.

The pecl compile path works for extensions the tap doesn't carry:

```sh
mise exec php -- pecl install redis
mise exec php -- asdf-php-ext enable redis
```

Either path lands the `.so` at `<install>/opt/php@<MAJMIN>/pecl/<api>/` and an
ini under `<install>/etc/php/<MAJMIN>/conf.d/`, where the numeric prefix sets
load order (`00-` bootstrap, `10-` bundled, `50-` enabled, `99-` user).
Details: [ADR 0002](docs/adrs/0002-extension-management.md).

## ini settings

`asdf-php-ini` manages user overrides in `99-asdf-php-user.ini`, which loads last
in the conf.d scan, so they win over bundled and enabled entries.

```sh
mise exec php -- asdf-php-ini set memory_limit 512M
mise exec php -- asdf-php-ini get memory_limit   # effective value via php ini_get
mise exec php -- asdf-php-ini --help
```

`set` is idempotent and double-quotes values containing whitespace, `;`, `#`, or
`"`. `get` reflects the full conf.d merge, not just what `asdf-php-ini` wrote.

Completions ship at `<install>/share/completions/`, covering the subcommands and
the directive name for `get` / `set` / `unset`:

```sh
# zsh: add to fpath before compinit
fpath=(~/.local/share/mise/installs/php/*/share/completions $fpath)
autoload -Uz compinit && compinit

# bash
source ~/.local/share/mise/installs/php/*/share/completions/asdf-php-ini.bash
```

## Requirements

macOS 11+ (Big Sur to Tahoe), arm64 tested, x86_64 should work. Platform
detection walks back through brew codename tags (`arm64_tahoe`,
`arm64_sequoia`, `arm64_sonoma`, ...) so newer hosts install older bottles.
Linux isn't supported yet ([TODO](TODO.md#linux-support)).

Needs `git`, `curl`, `awk`, `perl`, and bash 3.2+ (macOS defaults are fine). No
`jq`. `gh auth login` is only required for historical patch installs.

Coverage is bounded by the tap, so PHP older than 5.6 isn't installable, and
extensions with heavy C dependencies (imagick and friends) still fail to load
after install ([TODO](TODO.md#full-dep-chain-for-heavy-c-extensions)).

## Development

`npm install && npm test`. Local plugin linking, the three test tiers, and lint
targets: [CONTRIBUTING](CONTRIBUTING.md).

## Docs

- [How it works](docs/how-it-works.md): the install pipeline step by step,
  relocation, caching.
- [Troubleshooting](docs/troubleshooting.md): common install failures and fixes.
- [ADR 0001](docs/adrs/0001-php-homebrew-bottles.md): why bottles, historical
  resolution, migration plan to self-built statics.
- [ADR 0002](docs/adrs/0002-extension-management.md): the extension subsystem.
- [CHANGELOG](CHANGELOG.md) and [TODO](TODO.md).

## License

MIT. See [LICENSE](LICENSE).
