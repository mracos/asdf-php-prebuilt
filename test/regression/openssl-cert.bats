#!/usr/bin/env bats
# Regression: PHP's SSL streams must find a readable CA bundle.
#
# History: PHP's bottle bakes
#   openssl.cafile = "@@HOMEBREW_PREFIX@@/etc/openssl@3/cert.pem"
# into php.ini. Our placeholder rewrite turned that into
#   <install>/etc/openssl@3/cert.pem
# — but that path was never populated, because the bundle comes from
# brew's `ca-certificates` formula, which is data-only with no bottle.
# Any PHP SSL client (composer, file_get_contents over HTTPS,
# curl w/ verifypeer) died with:
#   Warning: failed loading cafile stream: '<install>/etc/openssl@3/cert.pem'
#   Warning: copy(): Failed to enable crypto
# Fix: bin/install symlinks <install>/etc/openssl@3/cert.pem to macOS's
# system store (/etc/ssl/cert.pem), matching what brew's openssl@3
# post_install does when ca-certificates isn't present.

load ../helpers

INSTALL="$(any_php_81_install)"

setup() {
  require_install "$INSTALL"
}

@test "openssl@3 cert.pem exists at the expected path" {
  [ -e "$INSTALL/etc/openssl@3/cert.pem" ] \
    || { echo "cert.pem missing at $INSTALL/etc/openssl@3/cert.pem"; false; }
}

@test "cert.pem is readable and non-empty" {
  # -L: follow symlink. -r: readable. -s: non-empty.
  [ -r "$INSTALL/etc/openssl@3/cert.pem" ]
  [ -s "$INSTALL/etc/openssl@3/cert.pem" ]
}

@test "cert.pem is a real PEM bundle (contains CERTIFICATE blocks)" {
  run grep -c "BEGIN CERTIFICATE" "$INSTALL/etc/openssl@3/cert.pem"
  [ "$status" -eq 0 ]
  # A minimally-useful bundle has at least a few dozen roots; 20 is a
  # very conservative lower bound.
  [ "$output" -gt 20 ] \
    || { echo "cert.pem only has $output BEGIN CERTIFICATE lines"; false; }
}

@test "php completes an HTTPS handshake without cert errors" {
  require_network
  # If openssl.cafile pointed at a bogus path, PHP would emit
  # "failed loading cafile stream" / "Failed to enable crypto" as an
  # E_WARNING before the stream ever opened. We check the last error
  # explicitly: if TLS worked, no such warning appears (the fetched
  # URL's HTTP status is irrelevant — any completed handshake proves
  # cert.pem is being read successfully).
  run "$INSTALL/bin/php" -r '
    @file_get_contents("https://example.com/", false,
      stream_context_create(["http" => ["timeout" => 5, "ignore_errors" => true]]));
    $err = error_get_last();
    if ($err !== null && (
        strpos($err["message"], "failed loading cafile") !== false
     || strpos($err["message"], "Failed to enable crypto") !== false)) {
      echo "SSL_BROKEN: " . $err["message"];
      exit(1);
    }
    echo "OK";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OK" ]] \
    || { echo "SSL setup broken: $output"; false; }
}

@test "composer --version works (SSL not required, but proves the phar runs)" {
  # Composer's phar itself doesn't need SSL to print --version, but
  # this is a broad "the whole toolchain runs" check.
  run "$INSTALL/bin/composer" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Composer version" ]] \
    || { echo "composer misbehaving: $output"; false; }
}
