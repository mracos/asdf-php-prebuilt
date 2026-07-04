# asdf-php

asdf/mise plugin that installs PHP on macOS by wrapping
[`shivammathur/homebrew-php`](https://github.com/shivammathur/homebrew-php)
bottles. No Homebrew runtime dependency: bottles and their transitive
deps are pulled from GHCR, relocated with `install_name_tool`, and
ad-hoc codesigned into the plugin's install prefix.

## Why this exists

The upstream `asdf-php` / `vfox-php` plugins build PHP from source and
hardcode `brew --prefix libxml2` in their install scripts. On modern
macOS toolchains with libxml2 ≥ 2.14, that build is broken for any PHP
version that didn't backport the libxml2 const-correctness fix —
including everything in the 8.1 series (EOL since Dec 2024) and a long
tail of older patch releases. This plugin sidesteps the compile path
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
also work — the plugin walks the tap's git history to find the right
commit:

```sh
mise install php@8.1.27   # any patch that's ever been in the tap
```

Every install also bundles the latest stable [Composer](https://getcomposer.org)
at `<install>/bin/composer`. Nothing extra to do:

```sh
mise exec php -- composer --version
```

To skip the composer bundle: `ASDF_PHP_BUNDLE_COMPOSER=0 mise install php@…`.

## What `mise install` does under the hood

1. Read `Formula/php@<MAJMIN>.rb` from the tap. If the requested patch
   matches what HEAD pins, skip to step 3.
2. Otherwise: walk `shivammathur/homebrew-php`'s git history (shallow
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
5. Walk every Mach-O file, rewrite `@@HOMEBREW_PREFIX@@` /
   `@@HOMEBREW_CELLAR@@` placeholders to `@loader_path`-relative form
   via `install_name_tool -change` / `-id`, ad-hoc re-codesign.
6. Generate `<install>/bin/<exe>` wrapper scripts that pin PHP at
   `<install>/etc/php/<MAJMIN>/` via `-c` and `PHP_INI_SCAN_DIR`.
   Without this, PHP would default to `/opt/homebrew/etc/php/<MAJMIN>/`
   (baked in at brew's build time) and pick up the host's stale
   conf.d on machines that have brew installed.
7. Copy and placeholder-rewrite the bottle's `.bottle/etc/` configs,
   then synthesize `conf.d/00-asdf-php.ini` that points
   `extension_dir` at the bottle's shared-extension directory and
   registers `intl.so` + `opcache.so`.
8. Verify by running `<install>/bin/php --version`.

Roughly 110 seconds end-to-end on a fast network — ~250MB of bottles
across ~50 transitive deps. The 24-hour tap-clone cache and the
content-addressable GHCR blobs mean second installs of the same
version are mostly download-bound.

## Platform support

| OS | arch | Status |
|---|---|---|
| macOS 11+ (Big Sur → Tahoe) | arm64 | Working |
| macOS 11+ (Big Sur → Tahoe) | x86_64 | Should work — untested |
| Linux | any | Not supported (see [TODO](TODO.md)) |

Host platform detection walks back through brew codename tags
(`arm64_tahoe → arm64_sequoia → arm64_sonoma → …`) so newer hosts
install older bottles via forward compatibility.

## Caching / state directories

| Path | What |
|---|---|
| `~/.cache/asdf-php/tap-clone/` | shallow clone of `shivammathur/homebrew-php` (~10MB). Refreshed at most once per 24h. |
| `~/.cache/asdf-php/formula-*.rb` | per-(formula, ref) on-disk formula cache. |
| `~/.cache/asdf-php/core-ref-*.sha` | resolved homebrew-core sha per timestamp. |
| `<mise-installs>/php/<version>/` | the install prefix — fully self-contained, safe to `rm -rf`. |

## Requirements

- macOS 11+ (Big Sur or newer)
- `git`, `curl`, `awk`, `bash` 3.2+ (macOS default is fine)
- `gh` CLI authenticated (`gh auth login`) — only for **historical**
  patch installs; current-tap installs work without it
- `jq` is NOT required

## Known limitations

- macOS only. Linux bottles exist on GHCR but this plugin doesn't
  handle them yet — see [TODO](TODO.md).
- No PHP extensions support (phpredis, igbinary, msgpack, etc.).
  These ship via a separate tap (`shivammathur/homebrew-extensions`)
  and need their own wiring — also in [TODO](TODO.md).
- Coverage is bounded by the tap. PHP versions that predate
  `shivammathur/homebrew-php` (< 5.6) aren't installable.

## Documentation

- [ADR 0001](docs/adrs/0001-php-homebrew-bottles.md) — why bottles,
  how the historical-resolution path works, and the migration plan
  to self-built static binaries.
- [TODO](TODO.md) — explicitly deferred work.
- [Troubleshooting](docs/troubleshooting.md) — common install
  failures and fixes.
- [CONTRIBUTING](CONTRIBUTING.md) — local dev setup.

## License

MIT. See [LICENSE](LICENSE).
