# ADR mracos/asdf-php - 0001: Wrap shivammathur/homebrew-php bottles as PHP binary source

> Date: 2026/06/18
>
> Authors: `Marcos Ferreira`

> Status: Accepted

## Context

Installing PHP on modern macOS via the existing asdf/mise PHP plugins is
broken for older PHP versions. Both `asdf-php` and `vfox-php` (the only two
PHP backends in mise's registry) compile from source and hardcode
`--with-libxml-dir=$(brew --prefix libxml2)` in their `bin/install`. With
Homebrew shipping libxml2 ≥ 2.14, the `xmlError` const-correctness change
breaks `ext/libxml/libxml.c` for any PHP that didn't backport the fix —
which is most of 8.1 (EOL Dec 2024) and a long tail of older patch releases.

Constraints:

- Several active projects pin specific PHP patch versions in `.tool-versions`
  (`koltin-dev/sales` is on `php 8.1.27`). Telling teams to bump off an EOL
  major is out of scope for this fix.
- We don't want a hard runtime dependency on Homebrew. The whole point is
  to avoid brew's libxml2 version dictating whether PHP builds.
- We want versions to live in `.tool-versions` / `mise.toml` so the tool
  surface looks like every other tool the team uses.

Two binary sources were evaluated:

| | static-php-cli (build in CI) | shivammathur/homebrew-php bottles |
|---|---|---|
| Are PHP binaries prebuilt? | No — `spc` is a builder we'd have to run in our own GH Actions matrix. | Yes — published as OCI artifacts on GHCR. |
| Time-to-first-working install | Days (CI matrix, build pinning, extension list curation). | Hours (download, relocate, codesign). |
| Extension surface | What we configure in `spc build`. No FPM by default, no `dl()`. | Full — FPM, all standard extensions, dynamic `dl()`. |
| Brittleness | We own the failure modes. | Brew bottle format has changed before; we'd track it. |
| Maintenance | Build pipeline ownership, runner minutes, signing. | Periodically refresh the formula → bottle URL mapping; track relocation placeholder changes. |

## Decision

Ship bottles now. Plan the migration to self-built static binaries later.

**1. Binary source: shivammathur/homebrew-php bottles.**

For each requested PHP version, the plugin:

- Fetches the matching `Formula/php@<MAJOR.MINOR>.rb` from
  `shivammathur/homebrew-php` (raw GitHub).
- Parses `bottle do { root_url, sha256 <platform>: ... }` for the
  platform tag matching the host (`arm64_sequoia`, `arm64_sonoma`,
  `arm64_tahoe`, `sonoma`, etc.).
- Pulls an anonymous GHCR token, fetches the OCI manifest, downloads the
  blob, verifies sha256.

**2. Transitive deps come along.**

PHP bottles link dynamically to `libxml2`, `gettext`, `gmp`, `icu4c@78`,
`libsodium`, `readline`, `libpng`, `libzip`, `libpq`, `libiconv`, etc. The
plugin parses `depends_on` from the formula, resolves bottle URLs for each
dep (from Homebrew core or shivammathur tap as appropriate), and stages
them under a Cellar-shaped layout inside the install prefix.

**3. Relocation via `install_name_tool`.**

Bottles use `@@HOMEBREW_PREFIX@@` and `@@HOMEBREW_CELLAR@@` placeholders
in their `LC_LOAD_DYLIB` / `LC_ID_DYLIB` entries (or hard `/opt/homebrew/...`
references in older bottles). Per Mach-O file in `bin/` and `lib/`, the
plugin runs `otool -L`, rewrites every brew-prefixed entry to the install
prefix via `install_name_tool -change`, then ad-hoc codesigns
(`codesign --force --sign -`) so macOS's dyld doesn't reject the
re-signed binary.

**4. Plugin contract: asdf-style bash.**

- `bin/list-all` — lists available PHP versions by enumerating
  `Formula/php@*.rb` in the tap.
- `bin/download` — bottle + dep pull into `$ASDF_DOWNLOAD_PATH`.
- `bin/install` — extract, stage, relocate, codesign, verify
  `php --version`.

Lives at `~/src/github.com/mracos/asdf-php`. Distributed via
`mise plugin install php https://github.com/mracos/asdf-php` and the equivalent
asdf invocation.

## Consequences

**Positive:**

- Unblocks teams pinned to PHP versions whose source no longer compiles
  cleanly against modern macOS toolchains.
- Full extension surface (FPM, PECL surface, `dl()`) — closer to "the
  PHP we'd actually run in prod" than a static build.
- Zero compile time per install. Bottle download + relocate is seconds, not
  minutes.
- No Homebrew dependency at runtime. Bottles and deps are owned by the
  install prefix.

**Negative:**

- Reimplements a slice of Homebrew's install logic (placeholder rewriting,
  codesigning, dep DAG walking). Brittle to upstream bottle format changes.
- Anonymous GHCR pulls are subject to rate limits and could be throttled
  during CI bursts.
- Coverage is bounded by what shivammathur publishes. If a patch version
  predates the tap's history, it won't be installable until we own the
  build pipeline.
- Two binary sources to track (`shivammathur/homebrew-php` for `php@*` and
  `Homebrew/homebrew-core` for transitive deps). Both can move.

## Implementation Notes

Platform tag detection:

```bash
case "$(uname -m)-$(sw_vers -productVersion)" in
  arm64-26.*)   tag=arm64_tahoe ;;
  arm64-15.*)   tag=arm64_sequoia ;;
  arm64-14.*)   tag=arm64_sonoma ;;
  x86_64-14.*)  tag=sonoma ;;
  # ...
esac
```

GHCR anonymous auth:

```bash
token=$(curl -sSL "https://ghcr.io/token?service=ghcr.io&scope=repository:shivammathur/php/php@8.1:pull" \
  | jq -r .token)
```

Relocation placeholder forms observed across brew bottle history:
`@@HOMEBREW_PREFIX@@`, `@@HOMEBREW_CELLAR@@`, hardcoded `/opt/homebrew/Cellar/...`,
and `/usr/local/Cellar/...`. The plugin handles all four.

## Migration Plan — bottles → self-built statics

Bottles are the right call **today** because they unblock the team in a
weekend instead of a month. They're the wrong call **forever** because we
don't own the binary source and the relocation glue accumulates
maintenance.

Replace with self-built static PHP binaries (via `static-php-cli` in a
GH Actions matrix in this repo) when **any** of the following triggers:

1. **Bottle format breakage.** Upstream changes its placeholder scheme or
   bottle layout in a way our relocator doesn't handle, and the fix isn't
   one-line.
2. **Coverage gap.** A pinned PHP version we need isn't published by
   shivammathur, and forking + publishing a one-off bottle is comparable
   work to building our own.
3. **Rate-limit pain.** Anonymous GHCR pulls start failing in CI or local
   bursts (multiple devs setting up the same week) and we're forced to add
   GitHub auth just to install PHP.
4. **Static surface becomes acceptable.** When the team's workflow drops
   the extensions that static builds don't carry well (or `spc`'s
   extension coverage grows to match), the static path becomes clean.

Exit shape:

- Add `.github/workflows/build.yml` matrix `[8.1, 8.2, 8.3, 8.4] x [arm64-macos-15, x86_64-macos-15]`.
- Use `spc` to download source, configure extensions, build, output tarball.
- Publish `php-<version>-<arch>-darwin.tar.xz` to this repo's Releases.
- Switch `bin/install` to a tarball-download path (curl → extract → done).
- Bottle code stays for one release as a fallback, then is removed.

## Related Decisions

- Pending: ADR 0002 on the migration to static builds (will reference the
  trigger that fires).
