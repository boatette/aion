{
  lib,
  stdenv,
  writeText,
  zig,
  pkg-config,
  wayland-scanner,
  fcft,
  libinput,
  libxkbcommon,
  pixman,
  udev,
  wayland,
  wayland-protocols,
  wlroots_0_20,
  glibc,
  linuxHeaders,
  versionCheckHook,
  # a config.zig (path or text) replacing src/config.zig, like dwl's configH
  configFile ? null,
  enableXWayland ? true,
  # zig release mode: fast, safe or small
  release ? "fast",
}:

let
  manifest = builtins.readFile ../build.zig.zon;
  config =
    if configFile == null || builtins.isPath configFile || lib.isDerivation configFile then
      configFile
    else
      writeText "config.zig" configFile;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "aion";
  version = builtins.head (builtins.match ".*\\.version = \"([0-9.]+)\".*" manifest);

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../contrib
      ../protocol
      ../src
      ../LICENSE
    ];
  };

  strictDeps = true;

  nativeBuildInputs = [
    pkg-config
    wayland-scanner
    zig.hook
  ];

  buildInputs = [
    fcft
    libinput
    libxkbcommon
    pixman
    udev
    wayland
    wayland-protocols
    wayland-scanner
    wlroots_0_20
  ];

  zigDeps = zig.fetchDeps {
    inherit (finalAttrs) pname version src;
    hash = "sha256-1TW4SRIcrBvJSU9m+tCa9mwQK3PRzrNxGOlRwoiVrp4=";
  };

  postPatch = lib.optionalString (config != null) ''
    cp ${config} src/config.zig
  '';

  postConfigure = ''
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR/tmp"
    ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  # translate-c needs the libc and kernel headers, which have no fixed path on nix
  env = {
    AION_LIBC_INCLUDE = "${lib.getDev glibc}/include";
    AION_LINUX_HEADERS = "${linuxHeaders}/include";
  };

  dontSetZigDefaultFlags = true;
  zigBuildFlags = [
    "-Dcpu=baseline"
    "--release=${release}"
    "-Dstrip"
    "-Dxwayland=${lib.boolToString enableXWayland}"
  ];

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  passthru.providedSessions = [ "aion" ];

  meta = {
    description = "A dwl-like scrolling Wayland compositor";
    homepage = "https://github.com/boatette/aion";
    license = lib.licenses.mit;
    mainProgram = "aion";
    platforms = lib.platforms.linux;
  };
})
