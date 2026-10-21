# How it works

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
11. Symlink the `openssl.cafile` / `openssl.capath` paths php.ini names
    (`<install>/etc/openssl@N/...`) to macOS's system store
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

## Caching / state directories

| Path                                 | What |
|--------------------------------------|------|
| `~/.cache/asdf-php/tap-clone/`       | shallow clone of `shivammathur/homebrew-php` (~10MB). Refreshed at most once per 24h. |
| `~/.cache/asdf-php/formula-*.rb`     | per-(formula, ref) on-disk formula cache. |
| `~/.cache/asdf-php/core-ref-*.sha`   | resolved homebrew-core sha per timestamp. |
| `<mise-installs>/php/<version>/`     | the install prefix. Fully self-contained, safe to `rm -rf`. |
