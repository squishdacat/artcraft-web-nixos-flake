# artcraft-web

A Nix flake that packages the prebuilt **WASM/web** releases of the
[storytold](https://github.com/storytold) `*craft` apps and serves them with
nginx through a NixOS module — one app per subdomain.

```nix
# flake.nix
{
  inputs.artcraft-web.url = "github:squishdacat/artcraft-web-nixos-flake";

  outputs = { nixpkgs, artcraft-web, ... }: {
    nixosConfigurations.web = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        artcraft-web.nixosModules.default
        ({ config, pkgs, ... }: {
          services.artcraft-web = {
            enable = true;
            baseDomain = "example.com";
            useACMEHost = "example.com";   # one wildcard cert for all of them

            apps = {
              photocraft = { };                      # photocraft.example.com
              lightcraft = { };                      # lightcraft.example.com
              printcraft.domain = "pdf.example.com"; # override the hostname
              vectorcraft.package = pkgs.artcraftWebApps.fromZip {
                pname = "vectorcraft";
                version = "0.4.0";
                zip = ./vectorcraft-web-0.4.0.zip;
              };
            };
          };

          # The cert useACMEHost points at. nginx needs to read the key, hence
          # the group.
          security.acme = {
            acceptTerms = true;
            defaults.email = "you@example.com";
            certs."example.com" = {
              domain = "*.example.com";
              dnsProvider = "cloudflare";
              credentialsFile = "/run/secrets/acme-cloudflare";
              group = config.services.nginx.group;
            };
          };
        })
      ];
    };
  };
}
```

Each app is served at `/` on `<name>.<baseDomain>`, or on `domain` if set.
`serverAliases` adds further hostnames.

## Certificates

Two ways, per app or set once at the top level:

- **`useACMEHost = "example.com"`** — reuse the certificate from
  `security.acme.certs."example.com"`. With a subdomain per app this is
  normally the one you want: a single wildcard `*.example.com` over DNS-01,
  shared by every vhost. The cert is yours to define, since the DNS
  credentials are; the module asserts it exists and reminds you about `group`
  rather than letting nginx fail to start on a missing key.
- **`enableACME = true`** (the default when `useACMEHost` is null) — each
  subdomain gets its own certificate over HTTP-01. Then set `acmeEmail`.

The two are mutually exclusive, and the module asserts that too. HTTPS is on
by default because WebGPU and the clipboard need a secure context; over plain
HTTP the apps fall back to WebGL2.

## Packaged apps

Versions and hashes were verified on 2026-10-08 by downloading each asset.

| App | Version | Asset layout |
|---|---|---|
| `photocraft` | 0.1.1-rc.4 | content-hashed |
| `printcraft` | 0.2.1 | content-hashed |
| `designcraft` | 0.1.1 | content-hashed |
| `lightcraft` | 0.1.1 | **un-hashed**, web workers, ships `.gz`/`.br` |
| `filmcraft` | 0.1.1 | **un-hashed**, audio worklet |
| `effectcraft` | 0.1.1 | **un-hashed**, service worker, PWA manifest |

`vectorcraft` has no GitHub release yet, so there is no URL to fetch — use
`pkgs.artcraftWebApps.fromZip` with the zip from `packaging/web/package.sh`,
as above. `cadcraft`, `gridcraft`, `soundcraft`, `wordcraft` and `deckcraft`
had no releases at all when this was written.

To bump one, edit the `known` table in `pkgs/apps.nix`: change the version,
set `hash = lib.fakeHash`, build, and paste in the hash Nix reports.

## Why not just follow the bundled HOSTING.md

Every release ships the same templated `HOSTING.md`, `_headers` and
`.htaccess`, all of which say to serve `.wasm` and `.js` with
`Cache-Control: public, max-age=31536000, immutable` because "the asset names
carry a content hash."

That is true for photocraft, printcraft, designcraft and vectorcraft. It is
**not** true for lightcraft, filmcraft or effectcraft, whose payloads are plain
`<app>_web.js` / `<app>_web_bg.wasm` plus `worker.js`, `audio-worklet.js` and
`sw.js`. Following that advice pins a stale app in every visitor's browser for
a year, with no URL change to break the cache.

So the generated config decides per file rather than per extension:

| Request | `Cache-Control` |
|---|---|
| `index.html`, `sw.js` | `no-cache` |
| `…-<hex>.js`, `…-<hex>_bg.wasm` | `max-age=31536000, immutable` |
| any other `.js` / `.wasm` | `max-age=300, must-revalidate` |
| icons, fonts, `manifest.webmanifest` | `max-age=86400` |

Tune with `immutableMaxAge` and `mutableMaxAge`, globally or per app.

The packages also differ from a plain unzip in two ways:

- **Pruning.** The lightcraft 0.1.1 zip ships its Cargo `target` directory —
  `deps/`, `build/`, `.fingerprint/`, about 80 MB of `.rlib` and `.so` files —
  which has no business in a docroot. The packaging samples
  (`_headers`, `.htaccess`, `HOSTING.md`) are dropped too.
- **Precompression.** `.html`, `.js`, `.wasm`, `.svg`, `.css` and
  `.webmanifest` are gzip- and brotli-compressed at build time and served via
  `gzip_static` / `brotli_static`, so a 16–46 MB wasm costs no CPU per request.
  Releases that already ship `.gz`/`.br` are left as they are.

## Other things the config handles

- `.wasm` as `application/wasm`, without which browsers refuse to
  stream-compile it, and `application/manifest+json` for the PWA manifest.
- **No** COOP/COEP. None of these releases use `SharedArrayBuffer`
  (effectcraft only reports `crossOriginIsolated` as a diagnostic), and
  lightcraft's render workers get the compiled module by `postMessage`. There
  is a `crossOriginIsolation` option for a future build that needs wasm
  threads; it also breaks cross-origin embedding.
- Iframe embedding is left working, which is what upstream documents. Set
  `allowEmbedding = false` for `X-Frame-Options: SAMEORIGIN`.
- `brotli = true` (the default) pulls `pkgs.nginxModules.brotli` into nginx.

Serving several apps on one host under path prefixes is no longer what the
module does, but `lib.mkVhostConfig` still takes a list of apps with
`basePath`es if you want to build such a vhost yourself.

## What was and wasn't tested

The nginx config this module generates was rendered with Nix and run against
real nginx 1.24 serving the actual photocraft, lightcraft, effectcraft and
vectorcraft builds, checking status, MIME type, `Cache-Control`,
`Content-Encoding` and byte integrity for every file class in the table above,
both as one-app-per-subdomain vhosts rooted straight at a package and under
path prefixes. That run caught one real bug: nginx rejects an unquoted regex
containing `{8,}`, so the location patterns are quoted.

The Nix files parse, and `lib/nginx-vhost.nix` evaluates. The module and the
package derivations have **not** been built or instantiated, because nixpkgs
was not reachable from where this was written — `nixos-rebuild build` is worth
running before you deploy, and it is also what will exercise the ACME
assertions and the `useACMEHost` wiring. `brotli_static` specifically was not
exercised either; the test nginx had no `ngx_brotli`.
