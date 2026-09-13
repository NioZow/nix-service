# Returns the cross-platform service config attrset for use inside a module's
# `config = lib.mkIf cfg.enable (mkService { ... });` block.
#
# The calling module is responsible for declaring options (including `enable`)
# and wrapping with `lib.mkIf cfg.enable`. Example:
#
#   lib,
#   pkgs,
#   config,
#   mkService,
#   ...
# }: let
#   cfg = config.custom.services.litellm;
# in {
#   options.custom.services.litellm = { ... };
#
#   config = lib.mkIf cfg.enable (mkService {
#     name        = "litellm";
#     description = "LiteLLM proxy";
#     command     = "${pkgs.litellm}/bin/litellm-proxy";
#     environment = { PORT = toString cfg.port; };
#   });
# }
#
# `mkService` is partially applied with { lib, isDarwin, username } (see the
# consuming flake's `lib.mkService`) so callers only pass service-specific
# parameters.
#
# Platform / module-system / scope mapping. The `homeManager` factory flag
# selects the *module system* that will consume the fragment, which is what
# decides the unit schema (NixOS/nix-darwin vs home-manager):
#
#   Linux, scope="system"                         -> systemd.services.<name>            (nixpkgs schema, root)
#   Linux, scope="user", homeManager=false        -> systemd.user.services.<name>       (nixpkgs schema)
#   Linux, scope="user", homeManager=true         -> systemd.user.services.<name>       (raw unit schema)
#   macOS, scope="system"                         -> launchd.daemons.<name>.serviceConfig  (nix-darwin)
#   macOS, scope="user", homeManager=false        -> launchd.agents.<name>.serviceConfig   (nix-darwin)
#   macOS, scope="user", homeManager=true         -> launchd.agents.<name>.{enable,config} (home-manager)
#
# NixOS's `systemd.user.services` and home-manager's `systemd.user.services`
# share a name but *not* a schema; `homeManager` is therefore required when
# targeting user scope. home-manager only supports user scope.
{
  lib,
  isDarwin,
  username,
  # True when the fragment is consumed by a home-manager module. Selects the
  # home-manager schema for `systemd.user.services` / `launchd.agents` and
  # coerces `scope = "system"` to user scope (home-manager has no system-wide
  # units), so shared definitions work unchanged.
  homeManager ? false,
  # Install.WantedBy target used for system-scope Linux units.
  systemdSystemTarget ? "multi-user.target",
}: {
  name,
  description,
  command,
  environment ? {},
  # "user" (default) or "system"; selects the unit/agent class.
  scope ? "user",
  label ? "local.${name}",
  restart ? "on-failure",
  restartSec ? 5,
  # Linux-only params (silently ignored on Darwin):
  after ? [],
  partOf ? [],
  wants ? [],
  # Install.WantedBy. When null it is derived from `scope`:
  #   system -> [systemdSystemTarget] (multi-user.target)
  #   user   -> ["default.target"]
  wantedBy ? null,
  extraSystemdServiceConfig ? {},
  extraSystemdUnitConfig ? {},
  # launchd schema is chosen by `homeManager` (see the factory args):
  #   home-manager -> config        (Label/ProgramArguments/...)
  #   nix-darwin   -> serviceConfig (Label/ProgramArguments/...)
  # launchd log location. Defaults to /var/log for system daemons and
  # ~/Library/Logs for user agents.
  logDir ? null,
  stdoutPath ? null,
  stderrPath ? null,
  # Attrset merged verbatim into the launchd config (like
  # extraSystemdServiceConfig, but for macOS).
  extraLaunchdConfig ? {},
}: let
  # `isDarwin` is derived from `pkgs.stdenv` by the caller (see `mkIsDarwin` in
  # nixcfg/lib/common.nix or `pkgs.stdenv.isDarwin` in a consumer), avoiding a
  # `system` string match here.
  isLinux = !isDarwin;
  # home-manager only manages per-user units, so a requested `scope = "system"`
  # is coerced to user scope when `homeManager = true` instead of erroring. This
  # lets one service definition be shared between system and home-manager
  # modules without special-casing the scope per consumer.
  systemScope = scope == "system" && !homeManager;

  resolvedWantedBy =
    if wantedBy != null
    then wantedBy
    else if systemScope
    then [systemdSystemTarget]
    else ["default.target"];

  programArguments = lib.filter (s: s != "") (lib.strings.splitString " " command);
  envList = lib.mapAttrsToList (k: v: "${k}=${v}") environment;

  resolvedLogDir =
    if logDir != null
    then logDir
    else if systemScope
    then "/var/log"
    else "/Users/${username}/Library/Logs";

  # Never emit null fields: launchd option types reject them.
  launchdConfig =
    lib.filterAttrs (_: v: v != null) {
      Label = label;
      ProgramArguments = programArguments;
      RunAtLoad = true;
      KeepAlive = true;
      EnvironmentVariables =
        {PATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";}
        // environment;
      StandardOutPath =
        if stdoutPath != null
        then stdoutPath
        else "${resolvedLogDir}/${name}.log";
      StandardErrorPath =
        if stderrPath != null
        then stderrPath
        else "${resolvedLogDir}/${name}-error.log";
    }
    // extraLaunchdConfig;

  # Service directives are shared between the two Linux schemas.
  systemdServiceSection =
    {
      Type = "simple";
      ExecStart = command;
      Restart = restart;
      RestartSec = restartSec;
      Environment = envList;
    }
    // extraSystemdServiceConfig;

  systemdUnitSection =
    {Description = description;}
    // lib.optionalAttrs (after != []) {After = after;}
    // lib.optionalAttrs (partOf != []) {PartOf = partOf;}
    // lib.optionalAttrs (wants != []) {Wants = wants;}
    // extraSystemdUnitConfig;

  # home-manager's `systemd.user.services` uses the raw systemd unit-file
  # schema: { Unit; Service; Install.WantedBy; }.
  homeManagerUnit = {
    Unit = systemdUnitSection;
    Service = systemdServiceSection;
    Install.WantedBy = resolvedWantedBy;
  };

  # NixOS's `systemd.services` and `systemd.user.services` use nixpkgs' option
  # schema: { description; wantedBy; after; partOf; unitConfig; serviceConfig; }.
  # There is no `Install`/`Unit`/`Service` here.
  nixosUnit =
    {
      inherit description;
      wantedBy = resolvedWantedBy;
      unitConfig = extraSystemdUnitConfig;
      serviceConfig = systemdServiceSection;
    }
    // lib.optionalAttrs (after != []) {after = after;}
    // lib.optionalAttrs (partOf != []) {partOf = partOf;}
    // lib.optionalAttrs (wants != []) {inherit wants;};
in
  lib.optionalAttrs isLinux (
    if systemScope
    then {systemd.services.${name} = nixosUnit;}
    else if homeManager
    then {systemd.user.services.${name} = homeManagerUnit;}
    else {systemd.user.services.${name} = nixosUnit;}
  )
  // lib.optionalAttrs isDarwin {
    launchd.${
      if systemScope
      then "daemons"
      else "agents"
    }.${
      name
    } =
      if homeManager
      then {
        enable = true;
        config = launchdConfig;
      }
      else {serviceConfig = launchdConfig;};
  }
