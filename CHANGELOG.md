# Changelog

Kept per [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Notable changes grouped by release. Not yet cut a first release
(pre-`0.1.0`). Log below is chronological within `[Unreleased]`.

## [Unreleased]

### Added

- `share/asdf-php-ini`: user ini-override helper (`list` / `get` /
  `set` / `unset`). Writes to
  `<install>/etc/php/<MAJMIN>/conf.d/99-asdf-php-user.ini`. The 99-
  prefix loads last in conf.d scan order so user settings win over
  bundled + enabled defaults. `get` returns the effective value via
  `php -r ini_get` (routed through our wrapper). Values with
  whitespace / `;` / `#` / `"` auto-quoted. Idempotent set.
- 10 regression assertions in `test/regression/ini-helper.bats`
  covering: presence in bin/, empty-file list output, quoted vs
  unquoted values, idempotent set, effective get, 99- precedence
  over 50-, unset removal, unset-of-unknown error, dot-in-key
  handling (opcache.enable vs opcache.enabled independent).

### Added (since last CHANGELOG entry)

- `share/asdf-php-ext` `install <name>` subcommand: pulls the
  prebuilt extension bottle from `shivammathur/homebrew-extensions`,
  walks tap-sibling deps plus one hop of homebrew-core deps, stages
  and relocates the `.so` into the unified ext dir, writes
  `50-<name>.ini`, and verifies with `php -m`. Rolls back staged
  files if verification fails (documented in troubleshooting).
- `.github/workflows/test.yml`: matrix over `macos-14` / `macos-15`
  running unit + integration + regression suites on every push and
  PR. gh CLI auth uses the workflow-provided `GITHUB_TOKEN`.
- `test/integration/`: 4 files behind `ASDF_PHP_RUN_INTEGRATION=1`.
  - `install-current.bats`: full install of the latest 8.1.x from
    the tap (8 assertions).
  - `install-latest.bats`: full install of the highest X.Y.Z the tap
    ships (6 assertions). Catches formula-format drift on newer
    bottles before it breaks the fast path.
  - `install-historical.bats`: `mise install php@8.1.27` via the
    git-history + contemporary-core-ref path (5 assertions).
  - `ext-pecl-flow.bats`: pecl compile + `asdf-php-ext enable`
    end to end (3 assertions).
  - `ext-tap-install.bats`: `asdf-php-ext install xdebug` end to end
    (4 assertions).
- `test/helpers.bash` `any_php_81_install`: picks whichever real
  8.1.x is currently installed, skipping mise's convenience symlinks
  (`8`, `8.1`, `latest`). Regression tests use it so they don't
  break when the installed patch changes.

### Changed (since last CHANGELOG entry)

- Composer bundling reverted from wrapper to raw phar. Semantics
  now match every other mise-managed tool: composer follows the
  cwd's PHP version pin through mise's shim. Direct
  `<install>/bin/composer` works from a pinned dir; `mise exec php
  -- composer <cmd>` works from anywhere. Wrapper approach hardcoded
  THIS install's php via absolute paths, which caused surprising
  version-pin behavior for users with multiple PHPs installed.
- `asdf-php-ext install` now supports both `<name>@<majmin>` and
  `php<name>@<majmin>` formula naming (e.g., `redis` finds
  `phpredis@8.1`).
- README section on extensions promotes `asdf-php-ext install` as
  the primary path; pecl compile stays documented as the fallback.

### Fixed (since last CHANGELOG entry)

- Backtick in the wrapper heredoc executed `pecl install X` at
  install time, generating a broken `bin/php` with `line 21:
  invalid: command not found`. Reworded the comment.
- Integration test caught composer runtime failure ("Tool not
  installed for shim") from a mise-shims host with a wrong-pinned
  cwd. Fix + revert are covered above.
- Regression test suite is now version-agnostic (`any_php_81_install`
  instead of hardcoded `8.1.27`).

### Added (initial run)

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
