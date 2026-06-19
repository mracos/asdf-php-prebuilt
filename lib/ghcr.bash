#!/usr/bin/env bash
# GHCR (GitHub Container Registry) helpers for OCI bottle pulls.
#
# brew publishes bottles as OCI blobs on ghcr.io. Each formula gets an
# image whose path is `<tap-owner>/<tap-stripped>/<formula-munged>`, where
# `formula-munged` is the formula name with `@` replaced by `/`
# (e.g. php@8.1 → php/8.1, openssl@3 → openssl/3).
#
# The bottle layer is published as a blob whose sha256 is the value the
# formula declares for the matching platform tag. That means we can skip
# the manifest entirely and pull the blob directly by digest.
#
# Functions:
#   asdf_php_ghcr_repo_path <root_url> <formula>
#       → repo path suitable for OCI scope/URL (e.g. shivammathur/php/php/8.1)
#   asdf_php_ghcr_token <repo_path>
#       → anonymous bearer token (cached for the script's lifetime)
#   asdf_php_ghcr_fetch_blob <repo_path> <digest> <dest>
#       → download blob, verify sha256

set -euo pipefail

# Derive the GHCR repo path from a brew root_url + formula name.
#
# Inputs:
#   root_url: e.g. https://ghcr.io/v2/shivammathur/php
#   formula: e.g. php@8.1
# Output:
#   shivammathur/php/php/8.1
asdf_php_ghcr_repo_path() {
  local root_url="$1" formula="$2"
  local path_part="${root_url#https://ghcr.io/v2/}"
  path_part="${path_part%/}"
  # @ → /, lowercase (brew's image_name_for)
  local munged="${formula//@//}"
  munged="$(echo "$munged" | tr '[:upper:]' '[:lower:]')"
  echo "${path_part}/${munged}"
}

# Get an anonymous pull token for a repo path. Cheap (~30ms per call) so
# we refetch per blob rather than caching — keeps the lib bash 3.2-safe
# (assoc arrays would otherwise be tempting).
asdf_php_ghcr_token() {
  local repo="$1" resp token
  resp=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull") \
    || asdf_php_die "could not fetch GHCR token for repo: $repo"
  token=$(echo "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  [[ -n "$token" ]] || asdf_php_die "empty GHCR token in response: $resp"
  echo "$token"
}

# Download a blob by sha256 digest and verify the digest matches.
#
# Inputs:
#   repo: GHCR repo path (from asdf_php_ghcr_repo_path)
#   digest: sha256 hex (no `sha256:` prefix)
#   dest: file path to write
asdf_php_ghcr_fetch_blob() {
  local repo="$1" digest="$2" dest="$3"
  local token url got

  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] \
    || asdf_php_die "invalid sha256 digest: $digest"

  token="$(asdf_php_ghcr_token "$repo")"
  url="https://ghcr.io/v2/${repo}/blobs/sha256:${digest}"

  mkdir -p "$(dirname -- "$dest")"
  curl -fsSL -H "Authorization: Bearer $token" "$url" -o "$dest" \
    || asdf_php_die "download failed: $url"

  got="$(shasum -a 256 "$dest" | awk '{print $1}')"
  if [[ "$got" != "$digest" ]]; then
    rm -f "$dest"
    asdf_php_die "sha256 mismatch for $url: got $got, want $digest"
  fi
}
