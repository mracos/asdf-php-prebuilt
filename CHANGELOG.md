# Changelog

Kept per [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Notable changes grouped by release. Not yet cut a first release
(pre-`0.1.0`). Log below is chronological within `[Unreleased]`.

## [Unreleased]

### Added

- Plugin scaffold with asdf-style `bin/list-all`, `bin/download`,
  `bin/install`, `bin/help.overview` (ADR 0001).
- `lib/utils.bash`: host arch + macOS codename detection, fallback
  chain (`arm64_tahoe` → `arm64_sequoia` → ...).
- `lib/formula.bash`: fetch tap + homebrew-core formulas at any ref,
  parse bottle metadata (root_url, sha256 per platform, `cellar: :any`
  qualifier tolerated), parse runtime deps (skips `:build` / `:test`,
  handles `on_macos` / `on_linux` blocks). Extended to
  `shivammathur/homebrew-extensions` too.
- `lib/ghcr.bash`: anonymous GHCR pull with sha256 verification.
  Correct `@` → `/` munging (`php@8.1` → `php/8.1`).
- `lib/deps.bash`: BFS walk of transitive runtime deps against a
  contemporary homebrew-core ref. Second walker for extension
  formulas that routes tap-qualified deps to
  `shivammathur/extensions` and unqualified to core.
- `lib/relocate.bash`: `install_name_tool` rewrite of
  `@@HOMEBREW_PREFIX@@` / `@@HOMEBREW_CELLAR@@` Mach-O placeholders
  to `@loader_path`-relative form, ad-hoc re-codesign. Text-script
  placeholder rewrite for `pecl`, `pear`, `phpize`, `php-config`
  (skipping `.phar` archives whose SHA1 signature can't be
  regenerated).
- `lib/history.bash`: shallow clone of `shivammathur/homebrew-php`,
  `git log` walk for the latest tap commit pinning a given patch,
  `gh api commits?until=<iso>` for the contemporary homebrew-core
  ref. Enables `mise install php@<any-past-patch>`.
- `lib/install.bash` orchestrator: extract bottles into `Cellar/`,
  plant `opt/<formula>` symlinks, relocate Mach-O + text placeholders,
  seed `etc/` with placeholder-rewritten configs, perl-fix
  PHP-serialized length prefixes in `pear.conf`, generate conf.d,
  bundle composer, drop `asdf-php-ext`.
- Unified `extension_dir` on the `pecl/<api>/` path. Bundled `.so`
  files from `lib/php/<api>/` are symlinked into `pecl/<api>/` so
  `pecl install X` and bundled extensions coexist in one directory.
- Wrapper scripts at `<install>/bin/<exe>` that export `PHPRC`,
  `PHP_INI_SCAN_DIR`, and `PHP_PEAR_SYSCONF_DIR` so PHP and PEAR read
  our config, not the host's brew `/opt/homebrew/etc/php/<MAJMIN>/`
  which is baked into the binaries at brew's build time.
- openssl CA bundle symlink to macOS's `/etc/ssl/cert.pem` (matches
  what brew's `openssl@3` post_install does when `ca-certificates`
  isn't present). Without it, PHP's SSL streams fail with
  "failed loading cafile stream".
- `share/asdf-php-ext` extension manager (`list`, `enable`, `disable`,
  scaffolded `install`) with the `00-` / `10-` / `50-` conf.d file
  convention. Uses `php-config --extension-dir` as the single source
  of truth for the extension directory.
- Composer bundled at `<install>/bin/composer` (latest stable phar),
  opt out via `ASDF_PHP_BUNDLE_COMPOSER=0`.
- Bats test harness with unit + regression suites. 43 assertions
  across 6 suites (as of the last commit): pear-config,
  ext-helper, openssl-cert, libpq-ssl, text-relocation, and unit
  tests for `lib/formula.bash` parsers.
- Docs: ADR 0001, README, CONTRIBUTING, TODO, troubleshooting.

### Fixed

- libpq / freetds "Symbol not found: _SSL_CIPHER_get_bits" on
  historical installs. Fixed by resolving deps against the
  contemporary homebrew-core ref instead of `master`.
- Composer `failed loading cafile stream` on SSL requests. Fixed by
  symlinking the openssl CA bundle to macOS's system store.
- `pecl` and friends dying with
  `@@HOMEBREW_CELLAR@@/php@8.1/…/bin/php: No such file or directory`.
  Fixed by placeholder-rewriting text scripts in the Cellar (not just
  Mach-O files), with `LC_ALL=C` sed and a `.phar` skip.
- `phar.phar` breaking with
  `Phar::mapPhar()` "SHA1 signature could not be verified". The
  bottle's phar signature was computed for the resolved-path shebang;
  we can't rewrite it without invalidating. Wrappers for `phar` and
  `phar.phar` are now intentionally skipped (users can still call
  the `Phar::` API from PHP).
- PEAR "<install>/etc/php/8.1/ is not a valid config file or is
  corrupted". Wrapper was passing `-c <dir>` to every binary; pecl /
  pear scripts forward that as PEAR's config-file path (which
  expects a file, not a directory). Fix: wrapper uses `PHPRC` +
  `PHP_INI_SCAN_DIR` env vars, no `-c` positional arg.
- `pecl config-get ext_dir` returning brew's path instead of ours.
  PEAR reads pear.conf from `PHP_PEAR_SYSCONF_DIR` env var, else the
  compile-time `PHP_SYSCONFDIR` (`/opt/homebrew/etc/php/<MAJMIN>/`).
  Wrapper now exports `PHP_PEAR_SYSCONF_DIR` too.
- `pear.conf` reads returning defaults instead of our values. Sed
  rewrote path values but not the PHP-serialized `s:N:` length
  prefixes, so unserialize silently fell back to compiled-in
  defaults. Fix: `perl -pi -e` recomputes prefixes after the sed
  pass.
- `pecl install X` compiling `.so` files somewhere `asdf-php-ext
  enable X` couldn't find them. Fixed by unifying `extension_dir` on
  the `pecl/<api>/` path and symlinking bundled `.so` files there.

### Known limitations

- macOS only. Linux support is deferred (needs ADR 0002).
- `phar.phar` can't be wrapped.
- `.reg` files under `share/php@<MAJMIN>/pear/.registry/` have the
  same length-prefix issue as `pear.conf` did. Non-fatal but produces
  `unserialize()` notices during pecl operations. TODO.
- Extension install from `shivammathur/homebrew-extensions` is
  scaffolded but not yet verified end to end.
