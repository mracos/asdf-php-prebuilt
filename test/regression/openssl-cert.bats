#!/usr/bin/env bats
# Regression: PHP's SSL streams must find a readable CA bundle.
#
# History: PHP's bottle bakes
#   openssl.cafile = "@@HOMEBREW_PREFIX@@/etc/openssl@3/cert.pem"
# (openssl@4 since php@8.1 8.1.34_3) into php.ini. Our placeholder
# rewrite turned that into
#   <install>/etc/openssl@3/cert.pem
# — but that path was never populated, because the bundle comes from
# brew's `ca-certificates` formula, which is data-only with no bottle.
# Any PHP SSL client (composer, file_get_contents over HTTPS,
# curl w/ verifypeer) died with:
#   Warning: failed loading cafile stream: '<install>/etc/openssl@3/cert.pem'
#   Warning: copy(): Failed to enable crypto
# Fix: bin/install symlinks whatever path php.ini's openssl.cafile names
# to macOS's system store (/etc/ssl/cert.pem), matching what brew's
# openssl post_install does when ca-certificates isn't present.

load ../helpers

INSTALL="$(any_php_81_install)"

setup() {
  require_install "$INSTALL"
  CAFILE="$("$INSTALL/bin/php" -r 'echo ini_get("openssl.cafile");')"
}

@test "openssl.cafile is inside the install and exists" {
  [[ "$CAFILE" == "$INSTALL"/* ]] \
    || { echo "openssl.cafile outside install: $CAFILE"; false; }
  [ -e "$CAFILE" ] \
    || { echo "cert.pem missing at $CAFILE"; false; }
}

@test "cert.pem is readable and non-empty" {
  # -L: follow symlink. -r: readable. -s: non-empty.
  [ -r "$CAFILE" ]
  [ -s "$CAFILE" ]
}

@test "cert.pem is a real PEM bundle (contains CERTIFICATE blocks)" {
  run grep -c "BEGIN CERTIFICATE" "$CAFILE"
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

@test "composer phar is bundled (chmod +x, env-php shebang, >1MB)" {
  # composer is a raw phar under $INSTALL/bin/composer with the standard
  # `#!/usr/bin/env php` shebang, following whichever php mise's shim
  # resolves in the cwd. Direct execution requires a matching pin;
  # from unpinned dirs users invoke via `mise exec php -- composer …`.
  # Just check the phar shape here.
  local composer="$INSTALL/bin/composer"
  [ -x "$composer" ]
  local size
  size="$(stat -f %z "$composer" 2>/dev/null || stat -c %s "$composer")"
  [ "$size" -gt 1000000 ]
  run head -1 "$composer"
  [[ "$output" == '#!/usr/bin/env php' ]] \
    || { echo "unexpected composer shebang: $output"; false; }
}
