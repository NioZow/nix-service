# Copy-paste example service module.
#
# `mkService` is a *module argument* (a `specialArgs` entry), so this module is
# portable across home-manager, NixOS and nix-darwin. Wire it in your flake:
#
#   # flake.nix (per system)
#   let
#     lib = nixpkgs.lib;
#     pkgs = import nixpkgs { inherit system; };
#     mkService = inputs.nix-services.lib.mkService {
#       inherit lib;
#       isDarwin = pkgs.stdenv.isDarwin;
#       username = "youruser";       # macOS user-scope log paths only
#     };
#   in {
#     nixosConfigurations.host = nixpkgs.lib.nixosSystem {
#       inherit system;
#       specialArgs = { inherit mkService; };
#       modules = [ inputs.nix-services.nixosModules.example ];
#     };
#   }
#
# Why `specialArgs` and not an imported `_module.args` module? `mkService` is
# used as top-level `config` content and is therefore forced during module
# merge. If its value depended on module args such as `pkgs` or `config`, that
# would recurse. Binding it outside the module system (specialArgs) avoids this.
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
