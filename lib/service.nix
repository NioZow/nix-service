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
# Platform / scope mapping:
#   scope = "user"   -> Linux: systemd.user.services.<name>
#                       macOS: launchd.agents.<name>        (home-manager schema)
#   scope = "system" -> Linux: systemd.services.<name>       (root)
#                       macOS: launchd.daemons.<name>       (nix-darwin schema)
{
  lib,
  isDarwin,
  username,
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
  # Install.WantedBy. When null it is derived from `scope`:
  #   system -> [systemdSystemTarget] (multi-user.target)
  #   user   -> ["default.target"]
  wantedBy ? null,
  extraSystemdServiceConfig ? {},
  extraSystemdUnitConfig ? {},
  # The launchd agent schema differs between nix-darwin system modules and
  # home-manager modules even though both expose `launchd.<class>`:
  #   home-manager -> config        (Label/ProgramArguments/...)
  #   nix-darwin   -> serviceConfig (Label/ProgramArguments/...)
  # Defaults from `scope`: system -> true (nix-darwin), user -> false (HM).
  nixDarwinLaunchd ? (scope == "system"),
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
  systemScope = scope == "system";

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

  systemdUnit = {
    Unit =
      {Description = description;}
      // lib.optionalAttrs (after != []) {After = after;}
      // lib.optionalAttrs (partOf != []) {PartOf = partOf;}
      // extraSystemdUnitConfig;
    Service =
      {
        Type = "simple";
        ExecStart = command;
        Restart = restart;
        RestartSec = restartSec;
        Environment = envList;
      }
      // extraSystemdServiceConfig;
    Install.WantedBy = resolvedWantedBy;
  };
in
  lib.optionalAttrs isLinux (
    if systemScope
    then {systemd.services.${name} = systemdUnit;}
    else {systemd.user.services.${name} = systemdUnit;}
  )
  // lib.optionalAttrs isDarwin {
    launchd.${if systemScope then "daemons" else "agents"}.${name} =
      if nixDarwinLaunchd
      then {serviceConfig = launchdConfig;}
      else {
        enable = true;
        config = launchdConfig;
      };
  }
