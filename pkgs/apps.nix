# Packages for the prebuilt web/WASM releases of the storytold "*craft" apps.
#
# Each GitHub release attaches a <app>-web-<version>.zip holding a static site.
# This turns one of those into a store path that is ready to be an nginx
# docroot: packaging samples and (for some releases) leaked Cargo build
# artifacts are dropped, and the big payloads are precompressed once at build
# time instead of on every request.
{ lib
, stdenvNoCC
, fetchurl
, unzip
, gzip
, brotli
}:

let
  mkArtcraftWebApp =
    { pname
    , version
    , src
    , repo ? pname
    , description ? "${pname} (WebAssembly build)"
    , precompress ? true
      # Brotli at 11 on a 16-46 MB .wasm is slow; 10 is close and much cheaper.
    , brotliQuality ? 10
    , extraRemove ? [ ]
    }:
    stdenvNoCC.mkDerivation {
      pname = "${pname}-web";
      inherit version src;

      nativeBuildInputs = [ unzip ] ++ lib.optionals precompress [ gzip brotli ];

      # The zip contains a single <app>-web-<version>/ directory.
      sourceRoot = ".";
      dontBuild = true;
      dontFixup = true;

      unpackPhase = ''
        runHook preUnpack
        unzip -q $src -d unpacked
        # Exactly one top-level directory is expected; fail loudly otherwise so
        # a packaging change doesn't silently produce an empty docroot.
        shopt -s nullglob
        dirs=(unpacked/*/)
        if [ ''${#dirs[@]} -ne 1 ]; then
          echo "expected one top-level directory in $src, got ''${#dirs[@]}" >&2
          exit 1
        fi
        mv "''${dirs[0]}" site
        runHook postUnpack
      '';

      installPhase = ''
        runHook preInstall

        cd site

        # Some releases (lightcraft 0.1.1, for one) ship the Cargo target
        # directory alongside the site - ~80 MB of .rlib/.so/fingerprint files
        # that must not end up in a docroot.
        rm -rf deps build .fingerprint incremental examples \
               .cargo-lock .cargo-build-lock .cargo-artifact-lock

        # Host-specific samples. .htaccess and _headers do nothing under nginx,
        # and HOSTING.md's caching advice assumes content-hashed filenames,
        # which several of these releases do not actually have.
        rm -f .htaccess _headers HOSTING.md
        ${lib.concatMapStringsSep "\n" (f: "rm -rf ${lib.escapeShellArg f}") extraRemove}

        if [ ! -f index.html ]; then
          echo "no index.html after pruning - packaging layout changed?" >&2
          exit 1
        fi

        mkdir -p $out
        cp -r . $out/

        runHook postInstall
      '';

      postInstall = lib.optionalString precompress ''
        # Precompress the payloads nginx will serve via gzip_static/brotli_static.
        # -n keeps gzip output reproducible; existing .gz/.br are left alone.
        find $out -type f \
          \( -name '*.html' -o -name '*.js' -o -name '*.wasm' \
             -o -name '*.webmanifest' -o -name '*.svg' -o -name '*.css' \
             -o -name '*.json' \) -print0 |
        while IFS= read -r -d "" f; do
          [ -e "$f.gz" ] || gzip -9 -n -c "$f" > "$f.gz"
          [ -e "$f.br" ] || brotli --quality=${toString brotliQuality} -c "$f" > "$f.br"
        done
      '';

      passthru.appName = pname;

      meta = with lib; {
        inherit description;
        homepage = "https://github.com/storytold/${repo}";
        # The desktop releases are dual MIT/Apache-2.0; bundled fonts in some
        # apps are OFL-1.1.
        license = [ licenses.mit licenses.asl20 ];
        platforms = platforms.all;
        sourceProvenance = [ sourceTypes.binaryBytecode ];
      };
    };

  fetchWebRelease =
    { repo, version, tag ? "v${version}", hash }:
    fetchurl {
      url = "https://github.com/storytold/${repo}/releases/download/${tag}/${repo}-web-${version}.zip";
      inherit hash;
    };

  # Versions and hashes verified on 2026-10-08 by downloading each asset.
  # Bump: change version/tag, set hash to lib.fakeHash, build, paste the real one.
  known = {
    photocraft = {
      version = "0.1.1-rc.4";
      hash = "sha256-oQWd8dHBDJ658/TBiNuhHCqS7dMX7zeoQ+IHxBWJ+Og=";
      description = "PhotoCraft - open-source Photoshop alternative (WebAssembly build)";
    };
    lightcraft = {
      version = "0.1.1";
      hash = "sha256-AZuiN97wqs0UlzD+2J4xQZJl1AtKltvewe6tHTjdynw=";
      description = "LightCraft - open-source Lightroom alternative (WebAssembly build)";
    };
    filmcraft = {
      version = "0.1.1";
      hash = "sha256-lLGsnLJ7prP4r+s20cRDXepvuJOFlrQXo7cTuHUUmoU=";
      description = "FilmCraft - open-source Premiere Pro alternative (WebAssembly build)";
    };
    printcraft = {
      version = "0.2.1";
      hash = "sha256-R82iB17nnb6HKbYw87xVnm3RuzeDS6XFkrzOUDCaCn8=";
      description = "PrintCraft - open-source Acrobat alternative (WebAssembly build)";
    };
    designcraft = {
      version = "0.1.1";
      hash = "sha256-08UHngpxljP/BRjd6SX+ZH7EoyUd9uNzP6NTjQPYHnQ=";
      description = "DesignCraft (WebAssembly build)";
    };
    effectcraft = {
      version = "0.1.1";
      hash = "sha256-YJiG3fiFPS/QXGG35C+s7qriqx8g/V0ZSnwDSanlNx0=";
      description = "EffectCraft (WebAssembly build)";
    };
  };

  fromKnown = name: args:
    mkArtcraftWebApp {
      pname = name;
      inherit (args) version description;
      src = fetchWebRelease {
        repo = name;
        inherit (args) version hash;
      };
    };

in
(lib.mapAttrs fromKnown known) // {
  inherit mkArtcraftWebApp fetchWebRelease;

  # VectorCraft has no GitHub release yet, so there is no URL to fetch. Point
  # this at the zip from packaging/web/package.sh:
  #
  #   services.artcraft-web.apps.vectorcraft.package =
  #     pkgs.artcraftWebApps.fromZip {
  #       pname = "vectorcraft";
  #       version = "0.4.0";
  #       zip = ./vectorcraft-web-0.4.0.zip;
  #     };
  fromZip = { pname, version, zip, ... }@args:
    mkArtcraftWebApp (
      (builtins.removeAttrs args [ "zip" ]) // { src = zip; }
    );
}
