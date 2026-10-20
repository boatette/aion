self:
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  cfg = config.programs.aion;

  # Environment first, then aion, which hands the session over to systemd
  # and D-Bus once WAYLAND_DISPLAY exists.
  session = pkgs.writeShellScript "aion-session" ''
    export XDG_CURRENT_DESKTOP=aion
    export XDG_SESSION_DESKTOP=aion
    export XDG_SESSION_TYPE=wayland
    ${cfg.extraSessionCommands}
    exec ${lib.getExe cfg.package} -s "${pkgs.dbus}/bin/dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE; ${pkgs.systemd}/bin/systemctl --user start aion-session.target"
  '';

  desktopEntry = pkgs.writeTextFile {
    name = "aion-desktop-entry";
    destination = "/share/wayland-sessions/aion.desktop";
    text = ''
      [Desktop Entry]
      Name=aion
      Comment=A dwl-like scrolling Wayland compositor
      Exec=${session}
      Type=Application
      DesktopNames=aion
    '';
  };
in
{
  options.programs.aion = {
    enable = lib.mkEnableOption "aion, a dwl-like scrolling Wayland compositor";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "aion.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      example = lib.literalExpression ''
        aion.packages.''${pkgs.stdenv.hostPlatform.system}.default.override {
          configFile = ./config.zig;
        }
      '';
      description = "The aion package to use. Override `configFile` to build it with your own config.zig.";
    };

    extraSessionCommands = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = "export MOZ_ENABLE_WAYLAND=1";
      description = "Shell commands run just before aion starts.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ cfg.package ];

        systemd.user.targets.aion-session = {
          description = "aion compositor session";
          documentation = [ "man:systemd.special(7)" ];
          bindsTo = [ "graphical-session.target" ];
          wants = [ "graphical-session-pre.target" ];
          after = [ "graphical-session-pre.target" ];
        };

        services.displayManager.sessionPackages = [
          (pkgs.symlinkJoin {
            name = "aion-session";
            paths = [ desktopEntry ];
            passthru.providedSessions = [ "aion" ];
          })
        ];

        xdg.portal.config.aion.default = lib.mkDefault [
          "wlr"
          "gtk"
        ];
      }
      (import "${modulesPath}/programs/wayland/wayland-session.nix" { inherit lib pkgs; })
    ]
  );
}
