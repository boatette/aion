# aion

A dwl-like Wayland compositor with a scrolling layout, written in Zig on wlroots.

Windows sit in columns on an endless horizontal strip, one strip per tag and monitor. A column can hold several windows stacked vertically. Everything else is dwl: tags, a dwm-style bar, monocle and floating layouts, rules, and a config file compiled in.

## Building

```sh
nix build            # result/bin/aion
nix run              # nested inside a running Wayland session
nix develop          # zig, zls and test tools
zig build            # inside the dev shell
```

`aion -s 'cmd'` runs `cmd` once the compositor is up. `aion -d` logs wlroots debug output.

## NixOS

```nix
{
  inputs.aion.url = "github:boatette/aion";

  outputs = { nixpkgs, aion, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        aion.nixosModules.default
        ({ pkgs, ... }: {
          programs.aion.enable = true;
          # Build with your own config:
          # programs.aion.package = aion.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
          #   configFile = ./config.zig;
          # };
        })
      ];
    };
  };
}
```

The module adds an `aion` session for display managers, an `aion-session` command for starting it from a TTY (`exec aion-session` in a login shell), an `aion-session.target` for user services, and the usual Wayland session pieces (portals, polkit, Xwayland). The package also takes `enableXWayland` and `release` (`fast`, `safe` or `small`).

## Configuration

Everything lives in `src/config.zig`: colours, font, tags, rules, monitor rules, input settings, keys, mouse buttons, wheel bindings and gestures. Copy it, change it, and pass it as `configFile`. Nix's `replaceVars` works on it the same way it does on a dwl `config.h`.

The default config uses `foot`, `wpctl`, `brightnessctl`, `grim` and `slurp`, and `loginctl` and `systemctl` for the session keys. The launcher lists the programs on `PATH`.

The bar reads one status line at a time from `status_cmd`'s output, or from stdin if `status_cmd` is `null`.

## Keys

| Keys                           | Action                                                                    |
| ------------------------------ | ------------------------------------------------------------------------- |
| Mod+h/l                        | focus the column to the left/right                                        |
| Mod+j/k                        | focus the window below/above in the column                                |
| Mod+Shift+h/l                  | move the column                                                           |
| Mod+Shift+j/k                  | move the window within its column                                         |
| Mod+[ / ]                      | pull the window into the neighbouring column, or push it out into its own |
| Mod+r, Mod+Shift+r             | cycle column width (1/3, 1/2, 2/3)                                        |
| Mod+-/=                        | column width -/+5%                                                        |
| Mod+Shift+-/=                  | window height in the column -/+10%                                        |
| Mod+f                          | toggle a full-width column                                                |
| Mod+c                          | centre the column                                                         |
| Mod+Home/End, +Shift           | focus or move to the first/last column                                    |
| Mod+a                          | monocle                                                                   |
| Mod+o, Mod+Shift+o, Mod+Ctrl+o | previous layout, floating, scrolling                                      |
| Mod+Shift+f                    | fullscreen                                                                |
| Mod+1..0, +Shift, +Ctrl        | view tag; move the window there and follow; move it there and stay        |
| Mod+g                          | view every tag                                                            |
| Mod+p                          | pin the window to every tag                                               |
| Mod+v                          | toggle floating                                                           |
| Mod+Return                     | terminal                                                                  |
| Mod+d                          | launcher in the bar                                                       |
| Mod+x                          | session keys in the bar                                                   |
| Mod+b                          | toggle the bar                                                            |
| Mod+q, Mod+Alt+q               | close, kill                                                               |

The arrow keys work wherever h/j/k/l do.

Mouse:

- Mod+wheel up/down: previous/next tag. Mod+Shift+wheel: take the window along.
- Mod+wheel left/right: focus columns. Mod+Ctrl+wheel left/right: move columns.
- Mod+middle drag: scroll the strip.
- Mod+left drag: move a window. Mod+right drag: resize it.

## Gestures

- **3 fingers left/right:** the strip follows your fingers. On release, the column nearest the middle takes focus and snaps fully into view.
- **3 fingers up/down:** next/previous tag.
- **4 fingers left/right:** move the column.
- **4 fingers up/down:** move the window to the next/previous tag.
- **Mod + 2-finger scroll sideways:** scroll the strip.

Other gestures, such as pinch, go to the application under the pointer.

## Licence

MIT. The bar's text drawing follows [drwl](https://codeberg.org/sewn/drwl) (MIT).
