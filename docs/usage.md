# Usage recipes

Three ways to consume `nix-services`, from most robust to most self-contained.

## (a) `specialArgs` — recommended

Bind the factory once at the flake level (where `lib`, `pkgs` and `username` are
plain values, not module arguments) and inject it into every configuration.

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-services = {
      url = "github:niozow/nix-services";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {self, nixpkgs, home-manager, nix-services}: let
    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    nixosConfigurations.zeus = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        mkService = nix-services.lib.mkService {
          lib = nixpkgs.lib;
          isDarwin = false;
          username = "noah";
        };
      };
      modules = [./hosts/zeus];
    };

    darwinConfigurations.athena = /* nix-darwin */ {
      specialArgs = {
        mkService = nix-services.lib.mkService {
          lib = nixpkgs.lib;
          isDarwin = true;
          username = "noah";
        };
      };
    };

    homeConfigurations.noah = home-manager.lib.homeManagerConfiguration {
      pkgs = import nixpkgs {system = "aarch64-darwin";};
      extraSpecialArgs = {
        mkService = nix-services.lib.mkService {
          lib = nixpkgs.lib;
          isDarwin = true;
          username = "noah";
        };
      };
      modules = [./home];
    };
  };
}
```

Then every service module just declares `mkService` in its argument set:

```nix
{
  config,
  lib,
  pkgs,
  mkService,
  ...
}: let
  cfg = config.services.myapp;
in {
  config = lib.mkIf cfg.enable (mkService {
    name = "myapp";
    description = "My app";
    command = "${pkgs.myapp}/bin/myapp";
  });
}
```

**Why not `_module.args`?** A module argument used as the top-level `config`
content is forced during module *merge*, before `config` (which contains
`_module.args`) is available. That is an infinite recursion, even if the value
is a thunk. `specialArgs` is outside the fixpoint, so it is safe.

## (b) Single-platform, self-contained module

If a flake distributes a module to downstream users (who can't add your
`specialArgs`), you can still use the library — as long as the platform and
username are constant for that module. Bind the factory from `lib` (safe) and
constants, and pass the result to a module *function* that is partially applied
at the flake level:

```nix
# service-module.nix
mkService: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.myapp;
in {
  options.services.myapp.enable = lib.mkEnableOption "myapp";
  config = lib.mkIf cfg.enable (mkService {
    name = "myapp";
    description = "My app";
    command = "${pkgs.myapp}/bin/myapp";
    scope = "system";
  });
}
```

```nix
# flake.nix
outputs = {self, nixpkgs, nix-services}: {
  nixosModules.default = {lib, pkgs, ...}: {
    imports = [
      ((import ./service-module.nix) (nix-services.lib.mkService {
        inherit lib;
        isDarwin = false;  # this module is NixOS-only
        username = "root"; # unused at system scope
      }))
    ];
  };
};
```

`lib` is provided by nixpkgs and is safe to use at merge time. **Do not** derive
`isDarwin` or `username` from `pkgs`/`config` here: that forces `pkgs` (a module
argument) during merge and recurses. This is the pattern used by
`chutes-litellm-proxy`.

## (c) The copyable example module

`nix-services` ships `modules/example.nix` as a starting point. It takes
`mkService` as a module argument, so import it alongside a `specialArgs`
binding:

```nix
specialArgs = { inherit mkService; };
modules = [inputs.nix-services.nixosModules.example];
```

It declares `custom.services.hello` with `enable` and `port` options; copy it and
rename.

> **Structural args must be literals.** `name` and `scope` determine the *shape*
> of the returned fragment (`systemd.services.<name>` vs
> `launchd.agents.<name>`) and are forced during module merge, so they cannot be
> read from `config`. Values *inside* the fragment (`command`, `environment`,
> `after`, …) may read `config` freely. This is why the example hardcodes
> `scope = "user"`.

## Overriding launchd behaviour

```nix
mkService {
  name = "myapp";
  description = "My app";
  command = "/path/to/bin --flag";
  scope = "system";              # -> launchd.daemons + serviceConfig
  label = "com.example.myapp";   # reverse-DNS is idiomatic for daemons
  logDir = "/var/log/myapp";     # override the default /var/log
  # or be explicit:
  stdoutPath = "/var/log/myapp/out.log";
  stderrPath = "/var/log/myapp/err.log";
  extraLaunchdConfig = {ProcessType = "Background";};
}
```

`environment` is merged after the default launchd `PATH`
(`/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin`), so setting
`environment.PATH` overrides it.

## Testing a local checkout

```nix
inputs.nix-services.url = "path:/Users/you/src/nix-services";
```

After editing `nix-services`, refresh the consumer lock so the `path:` input's
hash is recomputed:

```sh
nix flake update nix-services
```
