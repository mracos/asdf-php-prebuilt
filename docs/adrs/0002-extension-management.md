# ADR mracos/asdf-php-prebuilt - 0002: Extension management

> Date: 2026/07/05 \
> Authors: `Marcos Ferreira` \
> Status: Accepted (backfill of decisions already in code)

## Context

ADR 0001 established the plugin's binary source (bottles from
`shivammathur/homebrew-php`) and the install pipeline (extract,
relocate, wrap, verify). It said nothing about how PHP extensions get
managed after the base install lands. In practice a Laravel or
Symfony project needs a handful of extensions on top of what the
bottle ships (redis for cache, igbinary for compact serialization,
xdebug for stepdebug, sometimes imagick), and the plugin needed a
coherent answer.

Constraints encountered while adding extension support:

- brew's PHP keg has **two** extension directories:
  `<keg>/lib/php/<api>/` for shared `.so` files the bottle built
  (opcache, intl on newer patches), and `<keg>/pecl/<api>/` for
  `pecl install`-compiled ones. `php-config --extension-dir` reports
  the pecl path. Without intervention, PHP's `extension_dir` setting
  and `pecl install`'s output land in different directories.
- PEAR's config file resolution reads `PHP_PEAR_SYSCONF_DIR` env
  first, else compile-time `PHP_SYSCONFDIR` (which brew set to
  `/opt/homebrew/etc/php/<MAJMIN>/`). Without exporting the env var,
  `pecl config-get ext_dir` returns brew's path even on machines
  where the plugin owns everything else.
- `pear.conf` is PHP-serialized (`a:N:{s:K:"key";s:V:"value";...}`).
  Sed-rewriting the values shifts string lengths without updating the
  `s:V:` prefixes, so PEAR's unserialize silently falls back to
  compiled-in defaults (brew paths again).
- Two extension install paths coexist in the ecosystem: `pecl
  install X` (compile from source, needs autoconf + PHP dev
  headers) and prebuilt bottles from `shivammathur/homebrew-extensions`
  (download, relocate, install like a mini-bottle).
- `phar.phar` carries its own SHA1 signature over the whole archive,
  so the shebang embedded in it can't be rewritten. We skip wrapping
  it entirely; that's an artifact of ADR 0001's relocation strategy,
  not something extension-specific.

## Decision

**1. Unify `extension_dir` on the `pecl/<api>/` path.**

At install time, symlink each bundled `.so` from
`<keg>/lib/php/<api>/` into `<keg>/pecl/<api>/`, then point our
generated `conf.d/00-asdf-php.ini` at `<keg>/pecl/<api>/`. Result:
one directory holds both bundled shared extensions and pecl-compiled
ones. `php-config --extension-dir` matches PHP's actual
`extension_dir` matches our helper's lookup path. brew does the
equivalent for its own installs by symlinking `<prefix>/lib/php/pecl/<api>`
to `<keg>/pecl/<api>` during post_install.

**2. conf.d file naming: 00, 10, 50.**

Each shared extension gets its own ini file in
`<install>/etc/php/<MAJMIN>/conf.d/`. Three tiers by prefix:

| Prefix | Written by | Removable by disable? |
|---|---|---|
| `00-*.ini` | asdf-php at install time (extension_dir bootstrap) | No, refused |
| `10-<name>.ini` | asdf-php at install time (one per bundled shared `.so`) | Yes |
| `50-<name>.ini` | asdf-php-ext at user command time (enable, install) | Yes |

The split lets `asdf-php-ext disable <name>` remove exactly one file
without touching neighbors. Numeric prefixes control load order in
case one extension has to load before another (opcache, typically).
Refusing to remove `00-*` protects the extension_dir setting from
accidental disable.

**3. `asdf-php-ext` CLI shape.**

Four subcommands, all operating on `<install>/etc/php/<MAJMIN>/conf.d`
and `<php-config --extension-dir>` inside the same install prefix:

- `list`: enumerate `.so` files under ext_dir, mark each
  `enabled (<file>.ini)` or `available`.
- `enable <name>`: assert `<name>.so` exists at ext_dir; write
  `50-<name>.ini` with the right directive (`zend_extension=` for
  opcache/xdebug/xhprof/blackfire, `extension=` for the rest).
- `disable <name>`: find the ini file registering `<name>`, refuse
  if it's `00-*`, remove it. Leaves the `.so` on disk so re-enable
  is a one-liner.
- `install <name>`: fetch the extension bottle from
  `shivammathur/homebrew-extensions`, walk deps, relocate, place the
  `.so`, enable via the `enable` code path, verify with `php -m`.

The helper lives at `<install>/bin/asdf-php-ext` (copied from
`share/asdf-php-ext` at install time, with `__PLUGIN_LIB_DIR__`
substituted for the plugin's `lib/` path so `install` can reuse the
GHCR + relocate machinery).

**4. Two install paths, one enable path.**

Extensions land in the ext_dir via either:

- `pecl install <name>` (compiles from source; needs autoconf, PHP
  dev headers, and any C libraries the extension links to). Works
  for everything on pecl.php.net.
- `asdf-php-ext install <name>` (pulls the prebuilt bottle from
  `shivammathur/homebrew-extensions`, no compile). Faster; fails on
  extensions with heavy transitive C deps that the walker doesn't
  fully resolve (imagick, grpc). Recovers cleanly via rollback.

Both write `.so` files to the same unified ext_dir. `enable`
doesn't care where the `.so` came from.

**5. `install` verifies and rolls back on failure.**

After staging the `.so` + writing `50-<name>.ini`, run `<install>/bin/php
-m`. If it exits non-zero (a missing runtime dylib is the usual
cause), remove `50-<name>.ini` and the staged `.so` so `php` stays
runnable and no half-installed state accumulates. Report the failure
with `otool -L <so>` guidance.

Rollback is the reason `install` uses `enable`'s code path rather
than duplicating it: one place that writes the ini, one place that
verifies, one place that unwinds.

**6. Environment plumbing.**

The `<install>/bin/<exe>` wrappers already generated by ADR 0001's
install pipeline export three env vars that PEAR + PHP consult:

- `PHPRC` for php.ini location.
- `PHP_INI_SCAN_DIR` for conf.d.
- `PHP_PEAR_SYSCONF_DIR` for `pear.conf` location (matters for
  `pecl` specifically).

Without those, mise-shim-invoked binaries would still pick up brew's
paths on machines that have brew installed. This is a shared
prerequisite for both the base install and the extension subsystem,
so it's mentioned here for completeness rather than repeated as its
own decision.

**7. Post-install placeholder fix on `pear.conf`.**

After `seed_etc` sed-rewrites `@@HOMEBREW_*@@` placeholders in every
copied config file, run `perl -pi -e 's{s:\d+:"([^"]*)"}{ "s:" .
length($1) . ":\"$1\"" }ge'` over `pear.conf` to recompute the PHP-
serialized `s:N:` length prefixes to match the new value lengths.
Without this, PEAR's unserialize silently fails and everything falls
back to compiled-in defaults. The same fix applies to `.reg` files
under `share/php@<MAJMIN>/pear/.registry/` and is tracked in
[TODO](../../TODO.md).

## Consequences

**Positive:**

- Single `extension_dir` reachable by every relevant piece (PHP at
  runtime, pecl at install time, our helper). No path divergence.
- Extension enable/disable is a one-line ini write. Zero binary
  patching, safe to rerun.
- `asdf-php-ext install <name>` gives users the "install redis
  without compiling" affordance that upstream `asdf-php` /
  `vfox-php` don't.
- Rollback keeps php runnable across failed extension installs,
  which matters because a broken `.so` in ext_dir makes even `php
  --version` crash.
- The 00/10/50 scheme matches the convention `/etc/php/*/conf.d`
  scripts in shivammathur's tap and Debian's PHP packaging use, so
  it's not a bespoke invention.

**Negative:**

- The pecl-compile path still needs autoconf + dev headers on the
  host, and the host toolchain may not build every extension
  cleanly. Extensions with heavy C deps (imagick, grpc) require
  either a matured `deps_walk_ext` (transitive walk of
  homebrew-core deps of ext-tap formulas, currently one-level) or
  post-install `otool -L` dylib chasing. Tracked in
  [TODO](../../TODO.md).
- `.reg` files under `share/php@<MAJMIN>/pear/.registry/` still have
  the length-prefix drift `pear.conf` had, so pecl emits
  `unserialize()` notices on registry-touching operations. Non-fatal
  but noisy. Same fix as pear.conf, applied to a different glob;
  deferred in [TODO](../../TODO.md).
- Depends on brew's post_install invariant that pecl `.so` files
  belong at `<keg>/pecl/<api>/`. If brew changes that convention
  we'd have to adjust.

## Implementation notes

Extension-related files:

- `share/asdf-php-ext`: the CLI helper. Copied into `<install>/bin/`
  during install with `__PLUGIN_LIB_DIR__` replaced (so `install`
  can source `lib/formula.bash`, `lib/ghcr.bash`, `lib/deps.bash`,
  `lib/relocate.bash`).
- `lib/install.bash` `asdf_php_install_seed_etc`: creates
  `<keg>/pecl/<api>/`, symlinks bundled `.so`s into it, generates
  `conf.d/00-asdf-php.ini` + `conf.d/10-<name>.ini` per bundled
  shared `.so`.
- `lib/deps.bash` `asdf_php_deps_walk_ext`: dep walker specialized
  for the extension tap. Routes `shivammathur/extensions/<name>@X.Y`
  edges to the ext tap fetcher, unqualified edges to homebrew-core.
- `lib/formula.bash` `asdf_php_formula_fetch_ext`: fetches
  `Formula/<name>@<majmin>.rb` from `shivammathur/homebrew-extensions`
  (unsharded).

Verification path:

```text
asdf-php-ext install redis
  → cmd_install "redis"
    → asdf_php_formula_fetch_ext "redis@8.1" (falls back to "phpredis@8.1")
    → asdf_php_formula_bottle_resolve on host tag chain
    → asdf_php_deps_walk_ext (skips deps already in Cellar/)
    → asdf_php_ghcr_fetch_blob per bottle
    → tar extract into Cellar/
    → asdf_php_relocate_all across newly-staged Mach-O
    → cp <ext>.so into pecl/<api>/
    → cmd_enable "redis" (writes 50-redis.ini)
    → php -m | grep redis   → if not there, roll back
```

## Related decisions

- [ADR 0001](0001-php-homebrew-bottles.md): base install, GHCR
  fetch, relocation, wrapper env vars. This ADR builds on 0001's
  wrappers and relocator.
- [TODO](../../TODO.md): "Full dep chain for heavy C extensions",
  "PEAR registry (.reg) length prefixes",
  "`.mise.toml` `ASDF_PHP_EXTS` for declarative extensions".
