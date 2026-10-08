# NixOS module: serve the WASM builds of the storytold "*craft" apps with
# nginx, one app per subdomain.
#
#   services.artcraft-web = {
#     enable = true;
#     baseDomain = "example.com";
#     useACMEHost = "example.com";          # one wildcard cert for all of them
#     apps.photocraft = { };                # -> photocraft.example.com
#     apps.lightcraft = { };                # -> lightcraft.example.com
#   };
{ config, lib, pkgs, ... }:

let
  cfg = config.services.artcraft-web;

  mkVhostConfig = import ../lib/nginx-vhost.nix { inherit lib; };

  appModule = { name, config, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Serve this app. Set false to keep the entry but stop serving it.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = cfg.packages.${name} or (throw ''
          services.artcraft-web: no packaged web build is known for "${name}".
          Set services.artcraft-web.apps.${name}.package explicitly, e.g. with
          pkgs.artcraftWebApps.fromZip { ... } for an app that has no GitHub
          release yet.
        '');
        defaultText = lib.literalExpression "pkgs.artcraftWebApps.\${name}";
        description = "Docroot for this app: the unpacked <app>-web-<version>.zip.";
      };

      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "photo.example.com";
        description = ''
          Full hostname to serve this app on. Defaults to
          "''${name}.''${services.artcraft-web.baseDomain}".
        '';
      };

      serverAliases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "photoshop.example.com" ];
        description = "Extra hostnames for this vhost.";
      };

      useACMEHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = cfg.useACMEHost;
        defaultText = lib.literalExpression "services.artcraft-web.useACMEHost";
        example = "example.com";
        description = ''
          Serve the certificate from an existing `security.acme.certs.<name>`
          entry instead of requesting one per subdomain. This is the usual
          choice here: define a single wildcard cert for *.''${baseDomain} with
          a DNS-01 provider and point every app at it. Mutually exclusive with
          `enableACME`.
        '';
      };

      enableACME = lib.mkOption {
        type = lib.types.bool;
        default = config.useACMEHost == null && cfg.enableACME;
        defaultText = lib.literalExpression "useACMEHost == null && services.artcraft-web.enableACME";
        description = ''
          Request a certificate for this subdomain on its own, over HTTP-01.
          Mutually exclusive with `useACMEHost`.
        '';
      };

      forceSSL = lib.mkOption {
        type = lib.types.bool;
        default = cfg.forceSSL;
        defaultText = lib.literalExpression "services.artcraft-web.forceSSL";
        description = ''
          Redirect plain HTTP to HTTPS. WebGPU and the clipboard need a secure
          context; over plain HTTP the apps fall back to WebGL2.
        '';
      };

      brotli = lib.mkOption {
        type = lib.types.bool;
        default = cfg.brotli;
        defaultText = lib.literalExpression "services.artcraft-web.brotli";
        description = ''
          Serve the precompressed .br files (brotli_static). Needs nginx built
          with ngx_brotli, which this module adds automatically.
        '';
      };

      allowEmbedding = lib.mkOption {
        type = lib.types.bool;
        default = cfg.allowEmbedding;
        defaultText = lib.literalExpression "services.artcraft-web.allowEmbedding";
        description = ''
          Leave the app embeddable in a cross-origin iframe, which is what
          upstream documents. Set false to send X-Frame-Options: SAMEORIGIN.
        '';
      };

      crossOriginIsolation = lib.mkOption {
        type = lib.types.bool;
        default = cfg.crossOriginIsolation;
        defaultText = lib.literalExpression "services.artcraft-web.crossOriginIsolation";
        description = ''
          Send COOP/COEP/CORP. None of the current releases use
          SharedArrayBuffer, so this is off; turn it on only if a future build
          needs wasm threads. It also breaks cross-origin embedding.
        '';
      };

      immutableMaxAge = lib.mkOption {
        type = lib.types.int;
        default = cfg.immutableMaxAge;
        defaultText = lib.literalExpression "services.artcraft-web.immutableMaxAge";
        description = "max-age for content-hashed .js/.wasm.";
      };

      mutableMaxAge = lib.mkOption {
        type = lib.types.int;
        default = cfg.mutableMaxAge;
        defaultText = lib.literalExpression "services.artcraft-web.mutableMaxAge";
        description = ''
          max-age for .js/.wasm whose filename carries no content hash, as
          shipped by lightcraft, filmcraft and effectcraft. These revalidate,
          so an update is picked up instead of being pinned for a year.
        '';
      };

      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Appended verbatim to this app's virtual host.";
      };
    };
  };

  enabledApps = lib.filterAttrs (_: a: a.enable) cfg.apps;

  domainOf = name: app:
    if app.domain != null then app.domain
    else if cfg.baseDomain != null then "${name}.${cfg.baseDomain}"
    else throw ''
      services.artcraft-web.apps.${name}: set either a domain for this app or
      services.artcraft-web.baseDomain, so it has a hostname to serve on.
    '';

  anyBrotli = lib.any (a: a.brotli) (lib.attrValues enabledApps);
  anyOwnACME = lib.any (a: a.enableACME) (lib.attrValues enabledApps);

  acmeHostsUsed = lib.unique (
    lib.filter (h: h != null) (map (a: a.useACMEHost) (lib.attrValues enabledApps))
  );
in
{
  options.services.artcraft-web = {
    enable = lib.mkEnableOption "the ArtCraft WASM apps, served as static sites by nginx";

    apps = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule appModule);
      default = { };
      description = ''
        Apps to serve, keyed by app name. Each one gets its own virtual host at
        "<name>.<baseDomain>" unless `domain` overrides it.
      '';
      example = lib.literalExpression ''
        {
          photocraft = { };
          lightcraft = { };
          printcraft.domain = "pdf.example.com";
        }
      '';
    };

    baseDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "example.com";
      description = ''
        Parent domain each app's subdomain hangs off: app "photocraft" is
        served on "photocraft.<baseDomain>".
      '';
    };

    packages = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default = pkgs.artcraftWebApps or { };
      defaultText = lib.literalExpression "pkgs.artcraftWebApps";
      description = "Package set the apps' default `package` is looked up in.";
    };

    # Defaults inherited by every app; each can override its own.
    useACMEHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "example.com";
      description = ''
        Default `useACMEHost` for all apps: the name of an existing
        `security.acme.certs` entry whose certificate every vhost should use.
        With one app per subdomain this is normally a single wildcard cert:

        ```nix
        security.acme.certs."example.com" = {
          domain = "*.example.com";
          dnsProvider = "cloudflare";
          credentialsFile = "/run/secrets/acme-cloudflare";
          group = config.services.nginx.group;
        };
        ```

        Leave null to let each subdomain get its own certificate over HTTP-01.
      '';
    };

    enableACME = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Default for each app's `enableACME`; ignored where `useACMEHost` is set.";
    };

    forceSSL = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Default for each app's `forceSSL`.";
    };

    brotli = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Default for each app's `brotli`.";
    };

    allowEmbedding = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Default for each app's `allowEmbedding`.";
    };

    crossOriginIsolation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Default for each app's `crossOriginIsolation`.";
    };

    immutableMaxAge = lib.mkOption {
      type = lib.types.int;
      default = 31536000;
      description = "Default max-age for content-hashed assets (one year).";
    };

    mutableMaxAge = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Default max-age for assets with no content hash in the name.";
    };

    acmeEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Contact address for ACME. Needed only when some app requests its own
        certificate; with `useACMEHost` the cert's own definition carries it.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open ports 80 and 443.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = !anyOwnACME || cfg.acmeEmail != null || config.security.acme.defaults.email != null;
          message = "services.artcraft-web: set services.artcraft-web.acmeEmail (or security.acme.defaults.email), or point the apps at an existing certificate with useACMEHost.";
        }
      ]
      ++ lib.mapAttrsToList
        (name: app: {
          assertion = !(app.enableACME && app.useACMEHost != null);
          message = "services.artcraft-web.apps.${name}: enableACME and useACMEHost are mutually exclusive; useACMEHost already supplies the certificate.";
        })
        enabledApps
      # Catch the common wildcard-cert slip early, with the snippet to fix it,
      # rather than letting nginx fail to start on a missing certificate.
      ++ map
        (host: {
          assertion = config.security.acme.certs ? ${host};
          message = ''
            services.artcraft-web: useACMEHost = "${host}" but there is no
            security.acme.certs."${host}". Define it, e.g.

              security.acme.certs."${host}" = {
                domain = "*.${host}";
                dnsProvider = "<your provider>";
                credentialsFile = "/run/secrets/acme-dns";
                group = config.services.nginx.group;
              };

            The group matters: nginx has to be able to read the key.
          '';
        })
        acmeHostsUsed;

    warnings = lib.optional (enabledApps == { } && cfg.apps != { })
      "services.artcraft-web: every app is disabled, so nothing will be served.";

    services.nginx = {
      enable = true;
      additionalModules = lib.mkIf anyBrotli [ pkgs.nginxModules.brotli ];

      virtualHosts = lib.mapAttrs'
        (name: app: lib.nameValuePair (domainOf name app) {
          root = app.package;
          inherit (app) serverAliases enableACME forceSSL useACMEHost;
          extraConfig = mkVhostConfig {
            apps = [{ inherit name; basePath = "/"; }];
            inherit (app)
              brotli allowEmbedding crossOriginIsolation
              immutableMaxAge mutableMaxAge extraConfig;
          };
        })
        enabledApps;
    };

    security.acme = lib.mkIf anyOwnACME {
      acceptTerms = true;
      defaults.email = lib.mkIf (cfg.acmeEmail != null) cfg.acmeEmail;
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 80 443 ];
  };
}
