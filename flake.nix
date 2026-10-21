{
  description = "A dwl-like scrolling Wayland compositor";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        aion = pkgs.callPackage ./nix/package.nix { };
        default = aion;
      });

      overlays.default = final: _: {
        aion = final.callPackage ./nix/package.nix { };
      };

      nixosModules = rec {
        aion = import ./nix/nixos.nix self;
        default = aion;
      };

      checks = forAllSystems (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) aion;

        zig-fmt = pkgs.runCommand "aion-zig-fmt" { nativeBuildInputs = [ pkgs.zig_0_17 ]; } ''
          zig fmt --check ${./build.zig} ${./build.zig.zon} ${./src}
          touch $out
        '';

        nix-fmt = pkgs.runCommand "aion-nix-fmt" { } ''
          ${pkgs.lib.getExe pkgs.nixfmt} --check ${./flake.nix} ${./nix}
          touch $out
        '';
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.aion ];
          packages = with pkgs; [
            foot
            gdb
            grim
            nixfmt
            wayland-utils
            wev
            wlr-randr
            wtype
            zls
          ];
          env = {
            AION_LIBC_INCLUDE = "${pkgs.lib.getDev pkgs.glibc}/include";
            AION_LINUX_HEADERS = "${pkgs.linuxHeaders}/include";
          };
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
