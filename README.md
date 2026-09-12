# nix-services

Cross-platform service runner for Nix flakes: one `mkService` call yields a
working **systemd** unit on Linux or a **launchd** agent/daemon on macOS, at
**user** or **root/system** scope.

- Linux + user → `systemd.user.services.<name>` (home-manager)
- Linux + system → `systemd.services.<name>` (NixOS / nix-darwin)
- macOS + user → `launchd.agents.<name>` (home-manager schema)
- macOS + system → `launchd.daemons.<name>` (nix-darwin `serviceConfig` schema)

The library is pure (no impure builtins) and only needs `lib`, `isDarwin` and
`username` to be bound by the consumer.

## Install

```nix
{
  inputs.nix-services.url = "github:niozow/nix-services";

  # Avoid a second nixpkgs:
  # inputs.nix-services.inputs.nixpkgs.follows = "nixpkgs";
}
```

## Quickstart

Bind `mkService` once at the flake level and pass it to your configurations via
`specialArgs` (NixOS/nix-darwin) or `extraSpecialArgs` (home-manager):

```nix
# flake.nix (per system)
let
  lib = nixpkgs.lib;
  pkgs = import nixpkgs {inherit system;};
  mkService = inputs.nix-services.lib.mkService {
    inherit lib;
    isDarwin = pkgs.stdenv.isDarwin;
    username = "youruser"; # only used for macOS user-scope log paths
  };
in {
  nixosConfigurations.host = nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = {inherit mkService;};
    modules = [
      inputs.nix-services.nixosModules.example # optional copyable example
      ./service.nix
    ];
  };
}
```

```nix
# service.nix
{
  lib,
  pkgs,
  config,
  mkService,
  ...
}: let
  cfg = config.services.myapp;
in {
  options.services.myapp = {
    enable = lib.mkEnableOption "myapp";
    port = lib.mkOption {type = lib.types.port; default = 8080;};
  };

  config = lib.mkIf cfg.enable (mkService {
    name = "myapp";
    description = "My app";
    command = "${pkgs.myapp}/bin/myapp";
    environment = {PORT = toString cfg.port;};
    scope = "system"; # or "user"
  });
}
```

> **Why `specialArgs`?** `mkService` is used as top-level `config` content, which
> the module system forces during *merge*. If its value depended on module
> arguments such as `pkgs` or `config`, evaluation would recurse. Binding it
> outside the module system sidesteps that entirely.

## Platform / scope matrix

| `scope` | Linux (NixOS / home-manager) | macOS (nix-darwin / home-manager) | default `wantedBy` |
| --- | --- | --- | --- |
| `user` | `systemd.user.services.<name>` (raw `Unit`/`Service`/`Install`) | `launchd.agents.<name>` (`config`) | `default.target` |
| `system` | `systemd.services.<name>` (`description`/`wantedBy`/`serviceConfig`) | `launchd.daemons.<name>` (`serviceConfig`) | `multi-user.target` |

The two Linux schemas differ:

- home-manager's `systemd.user.services` uses the raw systemd unit-file schema
  (`Unit`, `Service`, `Install`).
- NixOS' `systemd.services` uses nixpkgs' option schema (`description`,
  `wantedBy`, `after`, `wants`, `serviceConfig`, `unitConfig`, …).

`mkService` emits the correct one automatically. The launchd schemas differ too:
home-manager takes `config`, nix-darwin takes `serviceConfig`; that choice is
derived from `scope` and can be overridden with `nixDarwinLaunchd`.

## API

`mkService = inputs.nix-services.lib.mkService { lib, isDarwin, username, systemdSystemTarget ? "multi-user.target" }`

The returned function:

| Arg | Type | Default | Applies to | Notes |
| --- | --- | --- | --- | --- |
| `name` | str | — | both | unit/agent name |
| `description` | str | — | both | |
| `command` | str | — | both | split on spaces for launchd `ProgramArguments` |
| `environment` | attrs | `{}` | both | `KEY=VALUE` list on systemd; env dict on launchd |
| `scope` | `"user"` \| `"system"` | `"user"` | both | selects unit class |
| `label` | str | `local.<name>` | launchd | `Label` |
| `restart` | str | `"on-failure"` | systemd | `Restart` |
| `restartSec` | int | `5` | systemd | `RestartSec` |
| `after` | [str] | `[]` | systemd | `After` / top-level `after` |
| `partOf` | [str] | `[]` | systemd | `PartOf` / top-level `partOf` |
| `wants` | [str] | `[]` | systemd | `Unit.Wants` / top-level `wants` |
| `wantedBy` | [str] | scope-dependent | systemd | `multi-user.target` for system, `default.target` for user |
| `extraSystemdServiceConfig` | attrs | `{}` | systemd | merged into `Service` / `serviceConfig` |
| `extraSystemdUnitConfig` | attrs | `{}` | systemd | merged into `Unit` / `unitConfig` (use capitalized directives) |
| `nixDarwinLaunchd` | bool | `scope == "system"` | launchd | `true` → `serviceConfig` (nix-darwin), `false` → `config` (home-manager) |
| `logDir` | str \| null | scope-derived | launchd | `/var/log` for system, `~/Library/Logs` for user |
| `stdoutPath` | str \| null | derived | launchd | overrides `StandardOutPath` |
| `stderrPath` | str \| null | derived | launchd | overrides `StandardErrorPath` |
| `extraLaunchdConfig` | attrs | `{}` | launchd | merged into the launchd config |
| `systemdSystemTarget` | str | `"multi-user.target"` | systemd (factory arg) | default install target for system scope |

`lib.version` exposes the release string (`"26.05"`) used to keep state versions
in sync.

## Root vs user services

Use `scope = "system"` when the service must start at boot without a login,
manage system state, or bind privileged ports. On NixOS this is a normal
`systemd.services` unit; you can harden it through
`extraSystemdServiceConfig`:

```nix
mkService {
  name = "myapp";
  description = "My app";
  command = "${pkgs.myapp}/bin/myapp";
  scope = "system";
  after = ["network-online.target"];
  wants = ["network-online.target"];
  environment = {PORT = "8080";};
  extraSystemdServiceConfig = {
    DynamicUser = true;
    StateDirectory = "myapp";
    StateDirectoryMode = "0700";
    AmbientCapabilities = [];
    CapabilityBoundingSet = [];
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = ["/var/lib/myapp"];
  };
}
```

On macOS a system service becomes a root `launchd.daemons` entry using the
nix-darwin `serviceConfig` schema, and logs default to `/var/log`. See
[`docs/root-services.md`](docs/root-services.md).

Use `scope = "user"` (default) for per-user daemons: a `systemd --user` service
via home-manager, or a `launchd.agents` entry. These start with the user session
and never require root.

## Consumption recipes

See [`docs/usage.md`](docs/usage.md) for:

- (a) the `specialArgs` path (recommended),
- (b) a single-platform self-contained module (constant `isDarwin`),
- (c) importing the copyable `homeModules.example`.

## Examples

Minimal service in all four combinations:

```nix
# Linux, user (home-manager)
{
  systemd.user.services.demo = { Unit.Description = "Demo"; /* ... */ };
}

# Linux, system (NixOS)
{
  systemd.services.demo = {description = "Demo"; wantedBy = ["multi-user.target"]; /* ... */};
}

# macOS, user (home-manager)
{
  launchd.agents.demo = {enable = true; config = {/* ... */};};
}

# macOS, system (nix-darwin)
{
  launchd.daemons.demo = {serviceConfig = {/* ... */};};
}
```

All four are produced by:

```nix
mkService {
  name = "demo";
  description = "Demo";
  command = "/bin/true";
  scope = "user"; # or "system"
}
```

with `isDarwin` set appropriately.

## How to test / develop

```sh
nix flake check          # builds the pure-eval matrix check
nix eval --json .#checks.aarch64-darwin.eval.evalResult | jq
```

`tests/eval.nix` evaluates `mkService` for Linux/Darwin × user/system and
asserts the expected attribute paths and defaults.

To hack on it from a consumer without publishing, point the input at a local
checkout:

```nix
inputs.nix-services.url = "path:/path/to/nix-services";
inputs.nix-services.inputs.nixpkgs.follows = "nixpkgs";
```

## Publishing

Once pushed, consumers use:

```nix
inputs.nix-services.url = "github:niozow/nix-services";
```

Pinning to a tag/rev is recommended for reproducibility.

## Why no importable `_module.args` module?

It is tempting to ship a module that does `_module.args.mkService = ...` so
consumers can `imports = [inputs.nix-services.nixosModules.default]` and use
`mkService` with no `specialArgs`. That does not work: a module argument used as
top-level `config` content is forced during module *merge*, while the argument
itself (`_module.args`) is part of `config` — a genuine cycle that produces
`infinite recursion encountered`, regardless of how lazy the value is. The
module system's supported mechanism for helpers like this is `specialArgs`, so
that is the documented path. See `modules/example.nix`.

## License

MIT (adjust as needed before publishing).
