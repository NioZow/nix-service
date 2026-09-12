# Copy-paste example service module. Import alongside one of the convenience
# modules (which provides the `mkService` module argument):
#
#   imports = [
#     inputs.nix-services.nixosModules.default
#     inputs.nix-services.homeModules.example
#   ];
#
# The same module works in a home-manager, NixOS or nix-darwin configuration.
{
  lib,
  pkgs,
  config,
  mkService,
  ...
}: let
  cfg = config.custom.services.hello;
in {
  options.custom.services.hello = {
    enable = lib.mkEnableOption "hello service";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the example service listens on.";
    };

    scope = lib.mkOption {
      type = lib.types.enum ["user" "system"];
      default = "user";
      description = "Run as a user agent/service or as a root daemon/service.";
    };
  };

  config = lib.mkIf cfg.enable (mkService {
    name = "hello";
    description = "Hello service";
    command = "${pkgs.hello}/bin/hello";
    environment = {PORT = toString cfg.port;};
    inherit (cfg) scope;
  });
}
