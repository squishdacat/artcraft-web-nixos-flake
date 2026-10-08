{
  description = "NixOS modules and packages for the WASM builds of the storytold ArtCraft apps";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      # pkgs.artcraftWebApps.<app>, plus mkArtcraftWebApp / fromZip helpers.
      overlays.default = final: _prev: {
        artcraftWebApps = final.callPackage ./pkgs/apps.nix { };
      };

      packages = forAllSystems (pkgs:
        let apps = pkgs.callPackage ./pkgs/apps.nix { };
        in
        nixpkgs.lib.filterAttrs (_: v: nixpkgs.lib.isDerivation v) apps);

      nixosModules.artcraft-web = { ... }: {
        imports = [ ./modules/artcraft-web.nix ];
        nixpkgs.overlays = [ self.overlays.default ];
      };
      nixosModules.default = self.nixosModules.artcraft-web;

      # The nginx generator on its own, in case you want it without the module.
      lib.mkVhostConfig = import ./lib/nginx-vhost.nix { inherit (nixpkgs) lib; };

      devShells = forAllSystems (pkgs: pkgs.mkShell {
        packages = [ pkgs.nixpkgs-fmt pkgs.unzip pkgs.brotli ];
      });
    };
}
