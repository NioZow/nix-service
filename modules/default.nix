# Optional convenience module. Import it to get `mkService` injected as a
# module argument, so service modules don't need `specialArgs` wiring:
#
#   imports = [ inputs.nix-services.nixosModules.default ];
#   # (or homeModules.default / darwinModules.default)
#
# `username` is only used for launchd log paths. It is resolved in this order:
#   1. an explicit `username` module arg (e.g. from specialArgs),
#   2. home-manager's `config.home.username`,
#   3. the first user in `config.users.users` (NixOS / nix-darwin systems),
#   4. "root".
#
# The documented primary path remains passing `username` via the consumer's
# own specialArgs; this module is a thin convenience for simple setups.
{
  config,
  lib,
  pkgs,
  ...
} @ args: let
  username =
    if args ? username && args.username != null
    then args.username
    else if config ? home && config.home ? username
    then config.home.username
    else if config ? users && config.users ? users && config.users.users != {}
    then builtins.head (builtins.attrNames config.users.users)
    else "root";
in {
  _module.args.mkService = (import ../lib/service.nix) {
    inherit lib username;
    isDarwin = pkgs.stdenv.isDarwin;
  };
}
