# asdf-php

asdf/mise plugin that installs PHP on macOS by wrapping
[`shivammathur/homebrew-php`](https://github.com/shivammathur/homebrew-php)
bottles. No Homebrew runtime dependency: bottles and their transitive deps are
downloaded from GHCR, relocated with `install_name_tool`, and ad-hoc codesigned
into the plugin's install prefix.

## Status

Early. Tracks the macOS bottle for the requested PHP version and stages it
self-contained under the asdf/mise install prefix.

## Install

```sh
# mise
mise plugin install php https://github.com/mracos/asdf-php
mise install php@8.1.34

# asdf
asdf plugin add php https://github.com/mracos/asdf-php
asdf install php 8.1.34
```

## Why

Long version in [`docs/adrs/0001-php-homebrew-bottles.md`](docs/adrs/0001-php-homebrew-bottles.md).

Short version: the upstream `asdf-php` / `vfox-php` plugins build PHP from
source and hardcode `brew --prefix libxml2`. On modern macOS toolchains with
libxml2 ≥ 2.14, that build is broken for any PHP version that didn't backport
the const-correctness fix (which is everything 8.1 — EOL — and most older
patch releases). Wrapping bottles sidesteps the entire compile path.

## Roadmap

Bottles is a stepping stone. Target is to replace the binary source with
self-built static binaries via GitHub Actions matrix in this repo, using
`static-php-cli` as the builder. ADR 0001 documents the migration trigger.
