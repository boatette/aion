{
  description = "a scrolling Wayland compositor";

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
      version = builtins.head (
        builtins.match ".*\\.version = \"([0-9.]+)\".*" (builtins.readFile ./build.zig.zon)
      );
    in
    {
      packages = forAllSystems (pkgs: rec {
        aion = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "aion";
          inherit version;
          src = self;

          strictDeps = true;

          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.wayland-scanner
            pkgs.zig.hook
          ];

          buildInputs = [
            pkgs.fcft
            pkgs.libinput
            pkgs.libxkbcommon
            pkgs.pixman
            pkgs.udev
            pkgs.wayland
            pkgs.wayland-protocols
            pkgs.wayland-scanner
            pkgs.wlroots_0_20
          ];

          zigDeps = pkgs.zig.fetchDeps {
            inherit (finalAttrs) pname version src;
            hash = "sha256-1TW4SRIcrBvJSU9m+tCa9mwQK3PRzrNxGOlRwoiVrp4=";
          };

          postConfigure = ''
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR/tmp"
            ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
          '';

          env = {
            AION_LIBC_INCLUDE = "${pkgs.glibc.dev}/include";
            AION_LINUX_HEADERS = "${pkgs.linuxHeaders}/include";
          };

          doInstallCheck = true;
          nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
          versionCheckProgramArg = "--version";

          passthru.providedSessions = [ "aion" ];

          meta = {
            description = "A scrolling Wayland compositor";
            homepage = "https://github.com/boatette/aion";
            license = pkgs.lib.licenses.mit;
            mainProgram = "aion";
            platforms = pkgs.lib.platforms.linux;
          };
        });

        default = aion;
      });

      checks = forAllSystems (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) aion;

        zig-fmt = pkgs.runCommand "aion-zig-fmt" { nativeBuildInputs = [ pkgs.zig ]; } ''
          zig fmt --check ${./build.zig} ${./build.zig.zon} ${./src}
          touch $out
        '';

        nix-fmt = pkgs.runCommand "aion-nix-fmt" { } ''
          ${pkgs.lib.getExe pkgs.nixfmt} --check ${./flake.nix}
          touch $out
        '';
      });

      devShells = forAllSystems (
        pkgs:
        let
          libraries = with pkgs; [
            libGL
            libinput
            libxkbcommon
            mesa
            pixman
            udev
            vulkan-loader
            wayland
            wlroots_0_20
          ];
        in
        {
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
              LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath libraries;
              AION_LIBC_INCLUDE = "${pkgs.glibc.dev}/include";
              AION_LINUX_HEADERS = "${pkgs.linuxHeaders}/include";
            };
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
