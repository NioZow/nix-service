{
  description = "Cross-platform (Linux systemd / macOS launchd) service runner for Nix flakes.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    forAllSystems = lib.genAttrs systems;
  in {
    # -----------------------------------------------------------------------
    # Primary API: curried factory. Consumers do:
    #
    #   mkService = inputs.nix-services.lib.mkService {
    #     inherit lib username;
    #     isDarwin = pkgs.stdenv.isDarwin;
    #   };
    #   ...
    #   config = lib.mkIf cfg.enable (mkService { name = "app"; ... });
    # -----------------------------------------------------------------------
    lib.mkService = {
      lib,
      isDarwin,
      username,
      systemdSystemTarget ? "multi-user.target",
    }:
      import ./lib/service.nix {
        inherit lib isDarwin username systemdSystemTarget;
      };

    lib.version = import ./lib/version.nix;

    # Optional convenience modules: importing this wires `mkService` into the
    # module system as a module argument. It never declares options.
    homeModules.default = import ./modules/default.nix;
    nixosModules.default = import ./modules/default.nix;
    darwinModules.default = import ./modules/default.nix;

    # Copyable example service module (Option A).
    homeModules.example = import ./modules/example.nix;

    # Pure-eval test of the 4 platform x scope combinations. Forcing the
    # `builtins.toJSON` of the result evaluates every assertion at build time.
    checks = forAllSystems (system: let
      pkgs = import nixpkgs {inherit system;};
      assertions = import ./tests/eval.nix {
        inherit lib;
        mkServiceFor = isDarwin:
          self.lib.mkService {
            inherit lib isDarwin;
            username = "tester";
          };
      };
    in {
      eval = pkgs.runCommand "nix-services-eval" {
        evalResult = builtins.toJSON assertions;
      } ''
        test -n "$evalResult"
        touch $out
      '';
    });
  };
}
