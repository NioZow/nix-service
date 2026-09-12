# PLAN: `nix-services` — a cross-platform service-runner flake library

> **Status:** implemented (phases 1–5). Deviations from the original sketch,
> discovered during implementation:
>
> 1. **Linux system units use a different schema.** NixOS'
>    `systemd.services.<name>` takes `description`/`wantedBy`/`after`/`wants`/
>    `unitConfig`/`serviceConfig` — not the raw `Unit`/`Service`/`Install` used
>    by home-manager's `systemd.user.services`. `lib/service.nix` now emits the
>    correct schema per scope, and a first-class `wants` parameter was added.
> 2. **No `_module.args` convenience module.** A module argument used as
>    top-level `config` content is forced at merge time while `_module.args` is
>    part of `config`, so it always recurses. `specialArgs` is the supported
>    mechanism; `modules/example.nix` uses it and documents it. `modules/default.nix`
>    was removed.
> 3. **Unused `home-manager` flake input removed** (it was never referenced and
>    would force every consumer to fetch it).
> 4. **First consumer** (`chutes-litellm-proxy`) binds `mkService` with a
>    constant `isDarwin = false` because its distributed module is NixOS-only and
>    binding it from `pkgs` would recurse.
>
> **Resume instruction for a fresh context:** the work is complete; re-run the
> verification below if resuming.

---

## 1. Goal

Extract the ad-hoc `lib/service.nix` builder that currently lives in the `nixcfg`
repo into a **standalone, publishable GitHub flake** called `nix-services`. The
library must make it trivial for *any* project flake (first consumer:
`~/dev/chutes-litellm-proxy`) to run a long-lived service/daemon on both **macOS**
and **Linux**, at **user** or **root (system)** scope, while still relying on
**home-manager** for user-level units.

The end-user experience should be:

```nix
# consumer flake.nix
inputs.nix-services.url = "github:niozow/nix-services";

# consumer module
config = lib.mkIf cfg.enable (mkService {
  name        = "myapp";
  description = "My app";
  command     = "${pkgs.myapp}/bin/myapp";
  environment = { PORT = toString cfg.port; };
});
```

and it "just works" on Linux (systemd) and macOS (launchd), user or root.

---

## 2. Decisions (locked in — do not re-litigate)

| Decision | Choice |
|---|---|
| Flake shape | **Option A** — expose `lib.mkService` + an importable example module + docs. |
| Root services | **Single `mkService` with a `scope = "user" \| "system"` parameter.** |
| Platform mapping | `scope="user"`: Linux `systemd.user.services`, macOS `launchd.agents`. `scope="system"`: Linux `systemd.services` (root), macOS `launchd.daemons` (root). |
| System-scope Linux default `wantedBy` | `["multi-user.target"]` (the canonical "best" target for root systemd services). User-scope keeps `["default.target"]`. |
| Location (for now) | `./nix-service/` **inside the nixcfg repo**, which will later be pushed as its own GitHub repo. |
| Repo | Must be a **git repo** with its own `flake.nix` **and committed `flake.lock`**. |
| Existing nixcfg `lib/service.nix` | **Leave unchanged / unbroken.** Do not break the ~24 existing nixcfg callers. Sharing code between the two is optional, not required. |

---

## 3. Current state (reference for the implementer)

### 3.1 The builder being extracted — `nixcfg/lib/service.nix`

```nix
# Returns the cross-platform service config attrset for use inside a module's
# `config = lib.mkIf cfg.enable (mkService { ... });` block.
#
# Linux-only params (silently ignored on Darwin):
#   after               — Unit.After list, e.g. ["network.target"]
#   partOf              — Unit.PartOf list, e.g. ["graphical-session.target"]
#   wantedBy            — Install.WantedBy list (default ["default.target"])
#   extraSystemdServiceConfig — attrset merged into the Service section verbatim
{
  lib,
  isDarwin,
  username,
}: {
  name,
  description,
  command,
  environment ? {},
  label ? "local.${name}",
  restart ? "on-failure",
  restartSec ? 5,
  after ? [],
  partOf ? [],
  wantedBy ? ["default.target"],
  extraSystemdServiceConfig ? {},
  # home-manager -> serviceConfig field is `config`
  # nix-darwin    -> serviceConfig field is `serviceConfig`
  # Set nixDarwinLaunchd = true for nix-darwin *system* modules (e.g. ca.nix).
  nixDarwinLaunchd ? false,
}: let
  isLinux = !isDarwin;
  programArguments = lib.filter (s: s != "") (lib.strings.splitString " " command);
  envList = lib.mapAttrsToList (k: v: "${k}=${v}") environment;
  launchdConfig = {
    Label = label;
    ProgramArguments = programArguments;
    RunAtLoad = true;
    KeepAlive = true;
    EnvironmentVariables =
      {PATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";} // environment;
    StandardOutPath = "/Users/${username}/Library/Logs/${name}.log";
    StandardErrorPath = "/Users/${username}/Library/Logs/${name}-error.log";
  };
in
  lib.optionalAttrs isLinux {
    systemd.user.services.${name} = {
      Unit =
        {Description = description;}
        // lib.optionalAttrs (after != []) {After = after;}
        // lib.optionalAttrs (partOf != []) {PartOf = partOf;};
      Service =
        {Type = "simple"; ExecStart = command; Restart = restart; RestartSec = restartSec; Environment = envList;}
        // extraSystemdServiceConfig;
      Install.WantedBy = wantedBy;
    };
  }
  // lib.optionalAttrs isDarwin {
    launchd.agents.${name} =
      if nixDarwinLaunchd
      then {serviceConfig = launchdConfig;}
      else {enable = true; config = launchdConfig;};
  }
```

### 3.2 How nixcfg currently wires it — `nixcfg/lib/common.nix` (lines 24–41)

```nix
mkSpecialArgs = { username, system, hostname, ... }: let
  ageLib = import ./age.nix { inherit username; };
  mkService = (import ./service.nix) {
    lib = nixpkgs.lib;
    inherit username;
    isDarwin = mkIsDarwin system;
  };
in {
  inherit inputs username system hostname nixVersion mkService;
  ...
};
```

`mkIsDarwin` reads `hostPlatform` from the host package set:
`mkIsDarwin = system: ((import nixpkgs {inherit system;})).stdenv.isDarwin;`

`nixVersion` comes from `nixcfg/lib/version.nix` and is currently `"26.05"`.

### 3.3 Representative callers (patterns to preserve)

- User service, Linux+macOS: `nixcfg/modules/services/user/litellm.nix:226`
  ```nix
  config = lib.mkIf cfg.enable (mkService {
    name = "litellm";
    description = "LiteLLM proxy (chutes-litellm-proxy)";
    command = "${cfg.package}/bin/litellm-proxy";
    environment = { PYTHONUNBUFFERED = "1"; LITELLM_HOST = cfg.host; ... } // apiKeyEnv // e2eeEnv;
  });
  ```
- nix-darwin **system** module: `nixcfg/modules/virtualisation/tartarus/ca.nix`
  (uses `nixDarwinLaunchd = true`).
- Some callers pass `after`, `partOf`, `wantedBy`, `extraSystemdServiceConfig`.

### 3.4 Full caller list (must remain unbroken)

```
packages/tartarus/flake.nix
lib/service.nix
lib/common.nix
modules/programs/user/clipboard-bridge.nix
modules/virtualisation/tartarus/microvm.nix
modules/virtualisation/tartarus/ca.nix
modules/virtualisation/tartarus/default.nix
modules/virtualisation/tartarus/options.nix
modules/services/user/caido.nix
modules/services/user/anki-sync-server.nix
modules/services/user/xpra.nix
modules/services/user/clipboard-bridge-client.nix
modules/services/user/snapclient.nix
modules/services/user/litellm.nix
modules/services/user/sudo-auth-proxy.nix
modules/services/user/opencode.nix
modules/services/user/noty.nix
modules/services/user/ssh-agent-host.nix
modules/services/user/clipboard-bridge-server.nix
modules/services/user/ghostty.nix
modules/services/user/ssh-agent-merge.nix
modules/services/user/ssh-agent-proxy.nix
modules/services/user/ssh-agent.nix
```

### 3.5 First consumer — `~/dev/chutes-litellm-proxy`

- Already a flake (`flake.nix`, `nixpkgs` unstable, systems x86_64-linux,
  aarch64-linux, aarch64-darwin).
- Has a **NixOS system module** in `options.nix` that hand-rolls
  `systemd.services.litellm` with heavy hardening (`DynamicUser`, `StateDirectory`,
  `ProtectSystem = "strict"`, etc.).
- `README.md` lines ~169–320 contain **three hand-written, duplicated service
  blocks**: home-manager/systemd--user, nix-darwin/launchd-agent, and
  NixOS/systemd-system. These are exactly what `mkService` should collapse.
- `services/litellm.service` and `services/local.litellm-proxy.plist` are static
  manual templates (leave them; optionally note they are superseded).

---

## 4. Target repository layout

```
nix-service/                      # ./nix-service inside nixcfg for now
├── .git/                         # git init'd (own repo), later its own remote
├── .gitignore                    # result, result-*, .direnv, .envrc? (keep .envrc if wanted)
├── flake.nix                     # inputs nixpkgs, home-manager; outputs lib + modules
├── flake.lock                    # committed
├── lib/
│   ├── service.nix               # the extracted + extended builder
│   └── version.nix               # "26.05" (single source of truth for stateVersion)
├── modules/
│   ├── default.nix               # optional convenience module (auto-wire mkService)
│   └── example.nix               # copyable example service module (Option A)
├── README.md                     # quickstart + full API + platform matrix
└── docs/
    ├── usage.md                  # detailed consumption recipes
    ├── root-services.md          # system-scope deep dive (systemd hardening, launchd daemons)
    └── claude.md                 # short contributor/agent notes (optional)
```

> Keep `lib/service.nix` as the only place the platform logic lives. `flake.nix`
> wires it into `lib.mkService`; `modules/example.nix` demonstrates usage.

---

## 5. Phase 1 — Scaffold the flake

### 5.1 `flake.nix` (target sketch)

```nix
{
  description = "Cross-platform (Linux systemd / macOS launchd) service runner for Nix flakes.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
  }: let
    lib = nixpkgs.lib;
  in {
    # Primary API: curried factory. Consumers do:
    #   mkService = inputs.nix-services.lib.mkService {
    #     inherit lib pkgs username;      # pkgs is optional but recommended
    #     isDarwin = pkgs.stdenv.isDarwin;
    #   };
    lib.mkService = {
      lib,
      isDarwin,
      username,
      pkgs ? null,
    }:
      import ./lib/service.nix {
        inherit lib isDarwin username;
        systemdSystemTarget = "multi-user.target";
      };

    # Optional convenience modules (see Phase 3).
    homeModules.default = import ./modules/default.nix;
    nixosModules.default = import ./modules/default.nix;

    # A copyable example module (Option A).
    homeModules.example = import ./modules/example.nix;

    lib.version = import ./lib/version.nix;
  };
}
```

> The flake must not require the consumer to pass `pkgs` — `isDarwin` is enough to
> pick the branch. Keep `pkgs` out of the core signature unless needed; if a
> default PATH for launchd is desired, hardcode the standard
> `/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin` (as today).

### 5.2 `flake.lock`

Run `nix flake lock` inside `nix-service/` (or `nix flake update`) to generate and
commit `flake.lock`.

### 5.3 `lib/version.nix`

```nix
"26.05"
```

(Mirrors `nixcfg/lib/version.nix`; used by the convenience module's
`home.stateVersion` if it sets one — see Phase 3. Keep in sync when bumping.)

### 5.4 `.gitignore`

```
result
result-*
.direnv/
```

### 5.5 Git init

```sh
git -C nix-service init
git -C nix-service add -A
git -C nix-service commit -m "feat: initial nix-services flake"
```

Do **not** add a remote yet (user will publish later). Ensure the parent
`nixcfg` repo ignores or intentionally tracks this embedded repo — see Gotchas §9.

**Verify phase 1:** `nix flake check ./nix-service` evaluates (may build nothing).

---

## 6. Phase 2 — Extend `lib/service.nix`

Copy the current builder (see §3.1) and make the following changes.

### 6.1 New signature

```nix
{
  lib,
  isDarwin,
  username,
  systemdSystemTarget ? "multi-user.target",
}: {
  name,
  description,
  command,
  environment ? {},
  scope ? "user",                 # NEW: "user" | "system"
  label ? "local.${name}",
  restart ? "on-failure",
  restartSec ? 5,
  after ? [],
  partOf ? [],
  wantedBy ? null,                # NEW: default depends on scope (see below)
  extraSystemdServiceConfig ? {},
  # launchd: explicit override still supported. If null it is derived:
  #   scope == "system" -> true  (nix-darwin system modules use `serviceConfig`)
  #   scope == "user"   -> false (home-manager uses `config`)
  nixDarwinLaunchd ? (scope == "system"),
}: let
  isLinux = !isDarwin;
  systemScope = scope == "system";

  # Default install target per platform/scope.
  resolvedWantedBy =
    if wantedBy != null
    then wantedBy
    else if systemScope
    then [systemdSystemTarget]   # multi-user.target
    else ["default.target"];

  programArguments = lib.filter (s: s != "") (lib.strings.splitString " " command);
  envList = lib.mapAttrsToList (k: v: "${k}=${v}") environment;

  logDir = if isDarwin then "/Users/${username}/Library/Logs" else "%h/.local/state/${name}";
  launchdConfig = {
    Label = label;
    ProgramArguments = programArguments;
    RunAtLoad = true;
    KeepAlive = true;
    EnvironmentVariables =
      {PATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";}
      // environment;
    StandardOutPath = if isDarwin then "${logDir}/${name}.log" else null;
    StandardErrorPath = if isDarwin then "${logDir}/${name}-error.log" else null;
    # strip nulls
  };
in
  # ---- Linux ----
  lib.optionalAttrs isLinux (
    if systemScope
    then {
      systemd.services.${name} = {
        Unit = {Description = description;}
          // lib.optionalAttrs (after != []) {After = after;}
          // lib.optionalAttrs (partOf != []) {PartOf = partOf;};
        Service = {Type = "simple"; ExecStart = command; Restart = restart; RestartSec = restartSec; Environment = envList;}
          // extraSystemdServiceConfig;
        Install.WantedBy = resolvedWantedBy;
      };
    }
    else {
      systemd.user.services.${name} = {
        Unit = {Description = description;}
          // lib.optionalAttrs (after != []) {After = after;}
          // lib.optionalAttrs (partOf != []) {PartOf = partOf;};
        Service = {Type = "simple"; ExecStart = command; Restart = restart; RestartSec = restartSec; Environment = envList;}
          // extraSystemdServiceConfig;
        Install.WantedBy = resolvedWantedBy;
      };
    }
  )
  # ---- Darwin ----
  // lib.optionalAttrs isDarwin {
    launchd.${if systemScope then "daemons" else "agents"}.${name} =
      if nixDarwinLaunchd
      then {serviceConfig = launchdConfig;}
      else {enable = true; config = launchdConfig;};
  }
```

### 6.2 Implementation notes / gotchas

- **Do not** set `StandardOutPath`/`StandardErrorPath` for systemd — those fields
  are launchd-only. The sketch guards them with `isDarwin`; make sure nulls are
  filtered from `launchdConfig` (use `lib.filterAttrs (_: v: v != null)`) so the
  attrset never contains `null` values, which launchd option types reject.
- For **system-scope launchd** (`launchd.daemons`), root daemons run as root and
  log to `/Users/.../Library/Logs` only if that dir exists. Consider making the
  log paths overridable via optional `logDir` / `stdoutPath` params (nice-to-have).
- The `nixDarwinLaunchd` auto-derivation means the **existing nixcfg callers are
  unaffected** (they call the old file). Within the new repo it means callers
  only need `scope = "system"` and the right launchd schema is chosen.
- Keep `label` defaulting to `local.${name}`. For system daemons Apple convention
  is often a reverse-DNS label; allow override (already possible).
- Preserve exact `restart`/`restartSec` semantics.
- `environment` stays an attrset; `envList` is the systemd rendering.
- Consider also exposing a raw `extraLaunchdConfig ? {}` for completeness
  (merged into `launchdConfig`), mirroring `extraSystemdServiceConfig`.

**Verify phase 2:** write a throwaway `nix eval` or a small `tests/eval.nix` that
calls `mkService` with each of the 4 combinations (linux/darwin × user/system)
and asserts the expected attribute path exists (`systemd.user.services`,
`systemd.services`, `launchd.agents`, `launchd.daemons`).

---

## 7. Phase 3 — Convenience module (auto-wire)

Option A still benefits from an optional module so consumers who don't want to
touch `specialArgs` can just import it. Provide `modules/default.nix`:

- Declares an option (e.g. `services.nix-services` or `custom.nixService`) that
  carries `mkService`, or
- Simpler: a module that uses `config.lib` is NixOS-specific and awkward on
  home-manager. **Recommended approach:** ship a *function* module, not options:

```nix
# modules/default.nix
{ lib, pkgs, config, ... }: {
  # Nothing to declare; the library exposes mkService through flake `lib`.
  # This module exists as a no-op import target so consumers can do:
  #   imports = [ inputs.nix-services.homeModules.default ];
  # and then reference `inputs.nix-services.lib.mkService`.
  _module.args.mkService = (import ../lib/service.nix) {
    inherit lib;
    isDarwin = pkgs.stdenv.isDarwin;
    username = config.home.username or config.users.users.<default> or "root";
  };
}
```

> **Caveat:** `username` is host-specific and `config.users.users` doesn't exist
> in home-manager. The cleanest, least-magical design is to make the *documented
> primary path* the `specialArgs` one (consumer passes their own `username`), and
> keep the module as a thin optional convenience that can read
> `config.home.username` (home-manager) or accept a module arg. Decide while
> implementing; the `specialArgs` path must work regardless.

`modules/example.nix` is the copy-paste example (Option A's "example module"):

```nix
{ lib, pkgs, config, mkService, ... }: let
  cfg = config.custom.services.hello;
in {
  options.custom.services.hello = {
    enable = lib.mkEnableOption "hello service";
    port = lib.mkOption { type = lib.types.port; default = 8080; };
  };

  config = lib.mkIf cfg.enable (mkService {
    name = "hello";
    description = "Hello service";
    command = "${pkgs.hello}/bin/hello";
    environment = { PORT = toString cfg.port; };
    scope = "user";        # or "system"
  });
}
```

**Verify phase 3:** the example module evaluates under both a home-manager and a
nix-darwin/NixOS eval (can be tested from a tiny throwaway flake importing the
lib).

---

## 8. Phase 4 — Dogfood with `chutes-litellm-proxy`

This proves the library works for the stated first use case.

1. **Add input** to `~/dev/chutes-litellm-proxy/flake.nix`:
   ```nix
   inputs.nix-services.url = "path:/Users/noah/.config/nixcfg/nix-service";
   # (later: github:niozow/nix-services)
   ```
   Ensure `nix-services.inputs.nixpkgs.follows = "nixpkgs";` to avoid duplicate
   nixpkgs.

2. **Provide `mkService`** either via `specialArgs` (if the project builds its
   own HM/NixOS configs) or by importing `homeModules.default`. The project is a
   package flake + a `nixosModules.default`; the NixOS module at `options.nix`
   currently hand-rolls `systemd.services.litellm`.

3. **Refactor `options.nix`** to build a shared `env` attrset and call:
   ```nix
   config = lib.mkIf cfg.enable (mkService {
     name = "litellm";
     description = "LiteLLM proxy (Chutes E2EE)";
     command = "${cfg.package}/bin/litellm-proxy";
     scope = "system";                      # root NixOS service today
     after = ["network-online.target"];
     wantedBy = ["multi-user.target"];      # default now, but explicit is fine
     environment = { PYTHONUNBUFFERED = "1"; ... } // apiKeyEnv;
     extraSystemdServiceConfig = {
       DynamicUser = true;
       StateDirectory = "litellm";
       StateDirectoryMode = "0700";
       AmbientCapabilities = [];
       CapabilityBoundingSet = [];
       NoNewPrivileges = true;
       PrivateTmp = true;
       ProtectSystem = "strict";
       ProtectHome = true;
       ReadWritePaths = ["/var/lib/litellm"];
     };
   });
   ```

4. **Refactor the README** (~lines 169–320): replace the three duplicated blocks
   with (a) the user-scope `mkService` example and (b) the system-scope one,
   noting macOS is handled automatically via `scope`/`isDarwin`.

5. **Document the `*_PATH` secret handling** stays as-is (the proxy reads files).

**Verify phase 4:**
- `nix flake check` in the consumer (or `nix eval .#nixosModules.default`-style
  eval) succeeds.
- `nix build .#` still builds the package.
- On macOS, evaluate the darwin path (`scope="user"` → `launchd.agents`).

---

## 9. Phase 5 — Documentation

Write `README.md` with (minimum contents):

1. **One-line what/why.**
2. **Install:** add input (pin later), `nixpkgs.follows`, exact snippet.
3. **Quickstart** (copy-pasteable) for the primary `specialArgs` path.
4. **Full API table:**

   | Arg | Type | Default | Applies to | Notes |
   |---|---|---|---|---|
   | `name` | str | — | both | unit/agent name |
   | `description` | str | — | both | |
   | `command` | str | — | both | split on spaces for launchd |
   | `environment` | attrs | `{}` | both | `KEY=VALUE` on systemd; env dict on launchd |
   | `scope` | `"user"`\|`"system"` | `"user"` | both | selects unit class |
   | `label` | str | `local.<name>` | launchd | |
   | `restart` | str | `on-failure` | systemd | |
   | `restartSec` | int | `5` | systemd | |
   | `after` | [str] | `[]` | systemd | ignored on Darwin |
   | `partOf` | [str] | `[]` | systemd | ignored on Darwin |
   | `wantedBy` | [str] | scope-dependent | systemd | `multi-user.target` for system |
   | `extraSystemdServiceConfig` | attrs | `{}` | systemd | verbatim merge |
   | `nixDarwinLaunchd` | bool | scope-derived | launchd | schema selector |

5. **Platform/scope matrix:**

   | scope | Linux (NixOS/HM) | macOS (nix-darwin/HM) | default `wantedBy` |
   |---|---|---|---|
   | `user` | `systemd.user.services.<name>` | `launchd.agents.<name>` (`config`) | `default.target` |
   | `system` | `systemd.services.<name>` | `launchd.daemons.<name>` (`serviceConfig`) | `multi-user.target` |

6. **Root vs user section** — when to use `scope="system"`, hardening example
   (`DynamicUser`, `StateDirectory`, `ProtectSystem`), launchd daemon caveats.
7. **Consumption recipes** — (a) `specialArgs`, (b) `homeModules.default`,
   (c) NixOS import.
8. **Examples** — minimal service in all four combos; the litellm real-world one.
9. **How to test / develop** — `nix flake check`, a local `path:` override.
10. **Publishing note** — how to point to `github:niozow/nix-services` once pushed.

Also write `docs/root-services.md` (deep dive) and `docs/usage.md` (recipes).

---

## 10. Acceptance criteria

- [ ] `nix-service/` is a **git repo** with `flake.nix` + committed `flake.lock`.
- [ ] `nix flake check ./nix-service` passes.
- [ ] `lib.mkService` produces the correct 4 attribute paths
      (`systemd.user.services`, `systemd.services`, `launchd.agents`,
      `launchd.daemons`) for the 4 platform×scope combinations.
- [ ] System-scope Linux defaults `wantedBy` to `multi-user.target`; user-scope
      defaults to `default.target`.
- [ ] `chutes-litellm-proxy` is refactored to use the library and still evaluates
      / builds (package `nix build .#` unaffected).
- [ ] README documents install, full API, platform matrix, root services, and
      examples; docs/ has the deep dives.
- [ ] nixcfg's existing `lib/service.nix` and all ~24 callers remain **unchanged
      and working** (no regressions).

---

## 11. Gotchas / risks to handle during implementation

1. **Nested git repo.** `nixcfg` has `nix-service/` as a separate git repo. Decide
   whether `nixcfg` tracks it (e.g. as a gitlink/submodule) or ignores it. For now
   the plan is: it's a plain embedded git repo; the parent repo will show it as an
   untracked/ignored dir. Either add `nix-service/` to nixcfg `.gitignore`, or
   (later) convert to a proper submodule. **Do not accidentally commit the
   embedded repo's contents into nixcfg.**
2. **`--impure`.** nixcfg requires `--impure` for `builtins.currentSystem` /
   `getEnv "USER"`; the new library must **not** depend on impure builtins. Derive
   `isDarwin` from `pkgs.stdenv.isDarwin` in the consumer.
3. **launchd nulls.** Never emit `null` fields into launchd config attrsets;
   filter them.
4. **`nixDarwinLaunchd` compatibility.** Old nixcfg callers pass this explicitly
   to the *old* file. The new file auto-derives it from `scope`; ensure an
   explicit override still wins (signature default is only used when arg absent).
5. **Home-manager vs nix-darwin launchd schemas differ** (`config` vs
   `serviceConfig`). Keep the existing discrimination and document it.
6. **Root launchd log paths.** A system daemon runs as root; `StandardOutPath`
   under `/Users/<user>/Library/Logs` requires that dir to exist and be writable.
   Consider defaulting system-scope launchd logs to `/var/log/<name>.log`.
7. **`environment` `PATH`.** Today a hardcoded PATH is merged for launchd. Keep
   it, but let `environment.PATH` override (attrset merge order: hardcoded first,
   then `environment`).
8. **nixpkgs `systemd.services` `Install.WantedBy`** on a systemd *system* unit
   is valid; on user units it's also valid via `systemd.user`. Confirmed pattern.
9. **flake.lock churn.** Commit it; use `nixpkgs.follows` at every consumer to
   avoid multiple nixpkgs.

---

## 12. Suggested implementation order (execution checklist)

1. `git init nix-service`, add `.gitignore`, `flake.nix`, `lib/version.nix`.
2. Port + extend `lib/service.nix` (Phase 2).
3. Add `modules/example.nix` and `modules/default.nix` (Phase 3).
4. `nix flake lock`; `nix flake check`.
5. Add `tests/eval.nix` (or shell eval) covering the 4 combos; run it.
6. Commit initial flake.
7. Wire `chutes-litellm-proxy` (Phase 4); refactor `options.nix` + README.
8. Verify consumer eval/build.
9. Write README + docs (Phase 5).
10. Final `nix flake check`; update PLAN status; commit.
