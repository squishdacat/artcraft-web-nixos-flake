# Pure nginx-config generator for a single virtual host serving one or more
# ArtCraft WASM apps. Kept free of nixpkgs so it can be evaluated (and its
# output diffed/tested) on its own.
#
# The ordering of the regex locations below is load-bearing: nginx tries regex
# locations in the order they appear and takes the first match. That is why the
# whole thing is emitted as one `extraConfig` block instead of
# `services.nginx.virtualHosts.<name>.locations`, whose attribute names Nix
# would sort alphabetically.
{ lib }:

let
  inherit (lib) concatStringsSep concatMapStrings optionalString;

  # add_header in a location replaces every inherited add_header, so the common
  # set has to be repeated in each location that sets any header at all.
  mkCommon =
    { crossOriginIsolation, allowEmbedding, extraHeaders }:
    concatStringsSep "\n" (
      [ ''add_header X-Content-Type-Options "nosniff" always;'' ]
      # None of the apps shipped so far use SharedArrayBuffer, so isolation is
      # off by default; it is here for builds that start using wasm threads.
      ++ lib.optionals crossOriginIsolation [
        ''add_header Cross-Origin-Opener-Policy "same-origin" always;''
        ''add_header Cross-Origin-Embedder-Policy "require-corp" always;''
        ''add_header Cross-Origin-Resource-Policy "same-origin" always;''
      ]
      # The apps are explicitly designed to be iframe-embeddable, so this is
      # opt-in rather than the usual DENY default.
      ++ lib.optionals (!allowEmbedding) [
        ''add_header X-Frame-Options "SAMEORIGIN" always;''
      ]
      ++ extraHeaders
    );

  indent = n: s:
    let pad = concatStringsSep "" (lib.genList (_: " ") n);
    in concatStringsSep "\n" (map (l: if l == "" then "" else pad + l) (lib.splitString "\n" s));
in
{ apps                            # [ { name; basePath; } ] - for comments only
, crossOriginIsolation ? false
, allowEmbedding ? true
, brotli ? false
, extraHeaders ? [ ]
, immutableMaxAge ? 31536000
, mutableMaxAge ? 300
, assetMaxAge ? 86400
, extraConfig ? ""
}:

let
  common = mkCommon { inherit crossOriginIsolation allowEmbedding extraHeaders; };
  c = indent 4 common;

  appComment =
    concatMapStrings (a: "#   ${a.basePath} -> ${a.name}\n") apps;
in
''
  # ArtCraft WASM apps served from this host:
  ${appComment}
  index index.html;

  # .wasm MUST be application/wasm or the browser will not stream-compile it.
  # Declaring a types block replaces the inherited map, so everything the apps
  # ship has to be listed here.
  types {
    text/html                  html;
    text/javascript            js mjs;
    application/wasm           wasm;
    application/json           json;
    application/manifest+json  webmanifest;
    image/png                  png;
    image/svg+xml              svg;
    image/x-icon               ico;
    image/jpeg                 jpg jpeg;
    font/woff2                 woff2;
    text/css                   css;
    text/plain                 txt md;
  }
  default_type application/octet-stream;

  # The packages precompress index.html, *.js and *.wasm at build time, so the
  # big payloads are served straight from disk with no per-request CPU. The
  # on-the-fly gzip below only catches anything without a precompressed twin.
  gzip_static on;
  ${optionalString brotli "brotli_static on;"}
  gzip on;
  gzip_vary on;
  gzip_min_length 1024;
  gzip_comp_level 5;
  gzip_types application/wasm text/javascript application/json
             application/manifest+json image/svg+xml text/css text/plain;

  # Multi-megabyte .wasm responses: don't buffer the whole thing.
  sendfile on;
  tcp_nopush on;

  # 0. The precompressed twins are delivered through gzip_static/brotli_static
  #    for the real URI, so a direct hit is only a mistyped URL. (Hiding them
  #    does not affect gzip_static, which reads the file internally rather
  #    than re-running location matching.)
  location ~* "\.(?:gz|br)$" {
      return 404;
  }

  # 1. Entry page and service worker must always revalidate. This has to come
  #    before the .js rule below so sw.js is never cached as code.
  location ~* "/(?:index\.html|sw\.js)$" {
  ${c}
      add_header Cache-Control "no-cache" always;
      try_files $uri =404;
  }

  # 2. Content-hashed artifacts, e.g. photocraft-web-<hex>.js and
  #    <app>-web-<hex>_bg.wasm. Safe to pin forever.
  location ~* "-[0-9a-f]{8,}(?:_bg)?\.(?:js|wasm)$" {
  ${c}
      add_header Cache-Control "public, max-age=${toString immutableMaxAge}, immutable" always;
      try_files $uri =404;
  }

  # 3. Un-hashed code. Several releases (lightcraft, filmcraft, effectcraft)
  #    ship <app>_web.js, <app>_web_bg.wasm, worker.js and audio-worklet.js
  #    with no hash in the name, so pinning them for a year - which is what the
  #    bundled _headers/.htaccess samples do - would serve a stale app after an
  #    update. These revalidate instead.
  location ~* "\.(?:js|wasm)$" {
  ${c}
      add_header Cache-Control "public, max-age=${toString mutableMaxAge}, must-revalidate" always;
      try_files $uri =404;
  }

  # 4. Icons, fonts, manifests.
  location ~* "\.(?:png|jpe?g|svg|ico|woff2?|webmanifest|css)$" {
  ${c}
      add_header Cache-Control "public, max-age=${toString assetMaxAge}" always;
      try_files $uri =404;
  }

  # 5. Everything else (licenses, READMEs, wasm-bindgen snippets/).
  location / {
  ${c}
      try_files $uri $uri/ =404;
  }
''
+ optionalString (extraConfig != "") "\n${extraConfig}\n"
