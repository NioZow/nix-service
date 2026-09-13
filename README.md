# nix-services

Cross-platform service runner for Nix flakes: one `mkService` call yields a
working **systemd** unit on Linux or a **launchd** agent/daemon on macOS, at
**user** or **root/system** scope.

- Linux + system → `systemd.services.<name>` (NixOS, root)
- Linux + user, home-manager → `systemd.user.services.<name>` (raw `Unit`/`Service`/`Install`)
- Linux + user, NixOS → `systemd.user.services.<name>` (nixpkgs `serviceConfig` schema)
- macOS + system → `launchd.daemons.<name>` (nix-darwin `serviceConfig`)
- macOS + user, nix-darwin → `launchd.agents.<name>` (`serviceConfig`)
- macOS + user, home-manager → `launchd.agents.<name>.{enable,config}`

NixOS' and home-manager's `systemd.user.services` share a name but **not** a
schema (and the same is true of `launchd.agents`), so user-scope consumers must
also set `homeManager = true|false` on the factory. The library is pure (no
impure builtins) and only needs `lib`, `isDarwin`, `username` (and `homeManager`
for user scope) to be bound by the consumer.

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
    homeManager = true; # set for user-scope home-manager modules (see matrix)
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

## Platform / module-system / scope matrix

| `scope` | module system | Linux | macOS |
| --- | --- | --- | --- |
| `system` | NixOS / nix-darwin | `systemd.services.<name>` (`description`/`wantedBy`/`serviceConfig`) | `launchd.daemons.<name>.serviceConfig` |
| `user` | NixOS (or nix-darwin) | `systemd.user.services.<name>` (`description`/`wantedBy`/`serviceConfig`) | `launchd.agents.<name>.serviceConfig` |
| `user` | home-manager | `systemd.user.services.<name>` (raw `Unit`/`Service`/`Install`) | `launchd.agents.<name>.{enable,config}` |

`user` scope defaults `wantedBy` to `default.target`; `system` scope to
`multi-user.target`.

The two user schemas differ:

- home-manager's `systemd.user.services` uses the raw systemd unit-file schema
  (`Unit`, `Service`, `Install`).
- NixOS' `systemd.user.services` (and `systemd.services`) uses nixpkgs' option
  schema (`description`, `wantedBy`, `after`, `wants`, `serviceConfig`,
  `unitConfig`, …).

`mkService` picks the right one from the factory's `homeManager` flag (and
nix-darwin vs home-manager for `launchd`). home-manager only manages per-user
units, so with `homeManager = true` a requested `scope = "system"` is **coerced
to user scope** rather than erroring — a shared service definition works
unchanged in both system and home-manager modules.

## API

`mkService = inputs.nix-services.lib.mkService { lib, isDarwin, username, homeManager ? false, systemdSystemTarget ? "multi-user.target" }`

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

Use `scope = "user"` (default) for per-user daemons. There are two flavours:

- **home-manager** (`homeManager = true`) — the consumer declares the unit in
  their own home-manager config and enables it with `home-manager switch`, no
  root required.
- **NixOS** (`homeManager = false`) — declared system-wide in
  `systemd.user.services`; activating it needs a `nixos-rebuild` (root), and the
  unit is visible to *every* user's user manager. Use it when the host is
  managed declaratively but the service should still run unprivileged.

Both start with the user session and never run as root.

## Consumption recipes

See [`docs/usage.md`](docs/usage.md) for:

- (a) the `specialArgs` path (recommended),
- (b) a single-platform self-contained module (constant `isDarwin`),
- (c) importing the copyable `homeModules.example`.

## Examples

The same `mkService { … }` call, consumed by each module system:

```nix
# Linux, system (NixOS, root)
{
  systemd.services.demo = {description = "Demo"; wantedBy = ["multi-user.target"]; /* ... */};
}

# Linux, user (NixOS -> systemd --user, nixpkgs schema)
{
  systemd.user.services.demo = {description = "Demo"; wantedBy = ["default.target"]; /* ... */};
}

# Linux, user (home-manager -> raw unit schema)
{
  systemd.user.services.demo = {Unit.Description = "Demo"; /* ... */};
}

# macOS, user (nix-darwin)
{
  launchd.agents.demo = {serviceConfig = {/* ... */};};
}

# macOS, user (home-manager)
{
  launchd.agents.demo = {enable = true; config = {/* ... */};};
}
```

all produced by:

```nix
mkService {
  name = "demo";
  description = "Demo";
  command = "/bin/true";
  scope = "user"; # or "system"
}
```

with `isDarwin` / `homeManager` set appropriately. With `homeManager = true`,
`scope = "system"` is coerced to user scope.

## How to test / develop

```sh
nix flake check          # builds the pure-eval matrix check
nix eval --json .#checks.aarch64-darwin.eval.evalResult | jq
```

`tests/eval.nix` evaluates `mkService` across Linux/macOS × NixOS/nix-darwin ×
home-manager × user/system and asserts the expected attribute paths, schemas and
defaults.

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
