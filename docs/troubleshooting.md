# Troubleshooting

Common failures and how to recover. Listed roughly by frequency.

## `mise install` fails immediately with "could not fetch formula php@X.Y from ..."

The tap's `Formula/php@X.Y.rb` doesn't exist on `master` (or the
branch your `ASDF_PHP_TAP_REF` env var points at). Verify the file
exists at
`https://github.com/shivammathur/homebrew-php/blob/master/Formula/php@<MAJMIN>.rb`.
If not, the major.minor isn't supported by the tap.

For older majors (5.6, 7.x), the tap covers them but you may still
need historical resolution — see below.

## "no tap commit found pinning php@X.Y=Z"

The patch version you asked for has never been pinned in the tap's
history of that file. Either it's a typo, or it predates the tap
covering that major.

Check what patches the tap has shipped for that major:

```sh
git -C ~/.cache/asdf-php/tap-clone log --format='%H %cI' \
  -- Formula/php@<MAJMIN>.rb \
  | head -20
```

(if the clone doesn't exist yet, any `mise install php@<historical-patch>`
will create it).

## "gh CLI required for historical installs"

Historical patch resolution looks up the contemporary
`Homebrew/homebrew-core` ref via `gh api commits?until=<iso>`. That
needs `gh` authenticated. Either:

```sh
brew install gh && gh auth login
```

or pick the patch version the current tap pins (`mise ls-remote php`
shows what HEAD has) and you stay on the fast path that doesn't need
`gh`.

## "failed loading cafile stream" when PHP makes HTTPS requests

`composer` (or any script using PHP's SSL streams) fails with

```
Warning: failed loading cafile stream: `<install>/etc/openssl@3/cert.pem'
Warning: copy(): Failed to enable crypto
```

PHP's `openssl.cafile` was originally pointed at
`@@HOMEBREW_PREFIX@@/etc/openssl@3/cert.pem`, which our placeholder
rewrite turns into `<install>/etc/openssl@3/cert.pem`. That file
comes from the `ca-certificates` brew formula, which is data-only
with no bottle (we skip it during `bin/download`).

The plugin now symlinks `<install>/etc/openssl@3/cert.pem` to the
macOS system cert bundle (`/etc/ssl/cert.pem`) during install. Older
installs done before this fix need it patched by hand:

```sh
inst=~/.local/share/mise/installs/php/<version>
mkdir -p "$inst/etc/openssl@3"
ln -sf /etc/ssl/cert.pem "$inst/etc/openssl@3/cert.pem"
ln -sf /etc/ssl/certs    "$inst/etc/openssl@3/certs"
```

Or `mise uninstall php@<version> && mise install php@<version>` to
regenerate the install with the fix applied.

## "Symbol not found: _SSL_CIPHER_get_bits" (or similar) after install

Usually means a dep bottle's ABI doesn't match what PHP / libpq /
freetds was built against. The historical install path picks a
contemporary `homebrew-core` ref specifically to avoid this; if you
still hit it, the contemporary-ref selection is off.

Clear caches and retry:

```sh
rm -rf ~/.cache/asdf-php/core-ref-*.sha \
       ~/.cache/asdf-php/formula-core-*.rb
mise uninstall php@<version>
mise install php@<version>
```

If it persists, file an issue with the version + macOS major.

## "no bottle for '<dep>' on arm64_tahoe (or fallbacks); skipping"

A homebrew-core dep doesn't have a macOS bottle for any codename in
our fallback chain (`arm64_tahoe → arm64_sequoia → arm64_sonoma →
arm64_ventura → arm64_monterey → arm64_big_sur`). For most deps this
is non-fatal — the dep is data-only (e.g. `ca-certificates`) and PHP
runs fine without it.

If the missing dep is something PHP actually links against, the
install will succeed but `php` will fail at load time with
`dyld: Library not loaded`. In that case the dep's formula was
probably renamed or moved; check
`https://github.com/Homebrew/homebrew-core/tree/HEAD/Formula/`.

## Stale ini scan directory

PHP's binary has `/opt/homebrew/etc/php/<MAJMIN>/conf.d` baked in.
Our `bin/<exe>` wrappers override that by exporting `PHPRC`,
`PHP_INI_SCAN_DIR`, and `PHP_PEAR_SYSCONF_DIR`. If you bypass the
wrapper (e.g. by running `Cellar/php@8.1/8.1.34_1/bin/php` directly),
PHP picks up the host's brew conf.d instead. Always go through
`<install>/bin/php` or `mise exec php@<version>`.

## Bottle download fails with HTTP 429

GHCR anonymous pull rate limits. Either wait an hour, or authenticate
your client. The plugin doesn't currently use auth tokens for the
bottle pulls (only for `gh api` during historical resolution).

## Wrapper scripts override too much

The auto-generated `<install>/bin/<exe>` wrappers export three env
vars pointing at our install's `etc/`:

- `PHPRC` (where PHP looks for php.ini)
- `PHP_INI_SCAN_DIR` (extra conf.d files)
- `PHP_PEAR_SYSCONF_DIR` (PEAR / pecl's pear.conf location)

Each is set with the `${VAR:-default}` idiom, so exporting your own
value before invoking the wrapper wins:

```sh
PHP_INI_SCAN_DIR=/path/to/your/conf.d <install>/bin/php script.php
```

Or bypass the wrapper entirely and call the raw binary at
`<install>/opt/php@<MAJMIN>/bin/php`. That's the escape hatch if
your workflow needs the compile-time defaults.

## `pecl install X` succeeds but `asdf-php-ext enable X` says "no .so at ..."

Symptom:

```
$ mise exec php -- pecl install redis
install ok: channel://pecl.php.net/redis-6.2.0
$ mise exec php -- asdf-php-ext enable redis
asdf-php-ext: no .so at <install>/opt/php@8.1/lib/php/20210902/redis.so
```

Root cause: your install predates the unified `extension_dir` fix.
brew's PHP keg has two extension directories (`lib/php/<api>/` for
bundled `.so` files, `pecl/<api>/` for pecl-compiled `.so` files) and
`php-config --extension-dir` reports the latter. Without our
unification, the two dirs diverge.

Fix: reinstall. `mise uninstall php@<version> && mise install
php@<version>`. The current bin/install symlinks bundled `.so` files
into `pecl/<api>/`, so both live in one directory (matching what pecl
uses).

## `pecl config-get ext_dir` returns `/opt/homebrew/lib/php/pecl/...`

pecl is reading brew's `pear.conf` instead of ours. Two possible
causes:

1. The wrapper isn't exporting `PHP_PEAR_SYSCONF_DIR`. Reinstall to
   pick up the current wrapper.
2. A stale `~/.pearrc` (per-user PEAR config) is overriding. Check
   with `ls ~/.pearrc`. If it exists and points at brew paths, remove
   it: `rm ~/.pearrc`.

## `unserialize(): Error at offset N of M bytes in PEAR/Registry.php`

pecl / pear emits these as `Notice:` during install. Non-fatal. The
extension still compiles and installs. The `.reg` files under
`<install>/share/php@<MAJMIN>/pear/.registry/` are PHP-serialized
and their `s:N:"..."` length prefixes drifted when we sed-rewrote
their path values. `pear.conf` gets a perl length-fix pass in
`bin/install`; the `.reg` files don't yet. Track:
[TODO.md](../TODO.md) "PEAR registry length prefixes".

To silence for a specific pecl run, redirect stderr:

```sh
mise exec php -- pecl install X 2>&1 | grep -v 'unserialize()'
```

## `asdf-php-ext install imagick` errors with "php -m failed (exit N)"

Symptom, after running `asdf-php-ext install imagick`:

```
asdf-php: relocated N Mach-O files
enabled imagick via 50-imagick.ini
asdf-php-ext: php -m failed (exit 139) after enabling imagick
asdf-php-ext: this usually means a required dylib isn't present or isn't relocated.
asdf-php-ext: rolling back 1 staged extension(s) to keep php runnable
asdf-php-ext: check missing deps with: otool -L <staged>.so
```

The plugin's rollback removes `50-imagick.ini` and the staged
`imagick.so` before exiting. `php -m` and `composer` should work
again immediately after.

Root cause: `imagick.so` links against MagickWand + MagickCore
(from `imagemagick`), which in turn depend on libheif, libde265,
x265, freetype, cairo, pango, ghostscript, and a long tail of image
codecs. The current dep walker doesn't resolve the full transitive
graph for tap-linked C libraries, so a few dylibs go missing at
runtime and dyld exits non-zero, which surfaces as a segfault.

Workarounds:

- Skip imagick locally. Most Laravel projects can substitute GD
  (bundled statically in every 8.x install) for basic image work.
- If you need imagick and have Homebrew already, run
  `brew install imagick@8.1` in the shivammathur tap and let brew's
  full opt-tree resolve. That extension `.so` won't work through
  asdf-php's install (baked-in Cellar path is wrong), but a `pecl
  install imagick` against brew's imagemagick can — messy but
  documented.

The right fix is expanding the walker to catch nested homebrew-core
deps of ext-tap formulas. Tracked in [TODO.md](../TODO.md).

## Clearing all cache

```sh
rm -rf ~/.cache/asdf-php
```

Forces the next `mise install` to re-clone the tap and re-fetch every
formula and bottle blob. Use sparingly — that's ~10MB of git +
re-resolution overhead.

## Removing an install

`<mise-installs>/php/<version>/` is fully self-contained. Either:

```sh
mise uninstall php@<version>
```

or just:

```sh
rm -rf ~/.local/share/mise/installs/php/<version>
```

Both leave the global caches intact.
