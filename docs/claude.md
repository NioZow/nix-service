# Contributor / agent notes

## Layout

- `lib/service.nix` — the only place platform logic lives. Signature:
  `{ lib, isDarwin, username, systemdSystemTarget ? "multi-user.target" } -> { …service args… } -> attrs`.
- `flake.nix` — wires `lib/service.nix` into `lib.mkService`, `lib.version`, the
  copyable `modules/example.nix`, and `checks`.
- `modules/example.nix` — copyable example; takes `mkService` as a module arg
  (requires `specialArgs`).
- `tests/eval.nix` — pure-eval assertions for the 4 platform × scope combos.

## Critical invariants

1. **Never emit `null` into launchd configs.** `launchdConfig` runs through
   `lib.filterAttrs (_: v: v != null)`.
2. **Linux schemas differ by scope.** home-manager user units use
   `Unit`/`Service`/`Install`; NixOS system units use
   `description`/`wantedBy`/`unitConfig`/`serviceConfig`. Do not unify them.
3. **`wantedBy` defaults depend on scope**: `multi-user.target` (system) vs
   `default.target` (user).
4. **`nixDarwinLaunchd` defaults from scope**: `true` for system (nix-darwin
   `serviceConfig`), `false` for user (home-manager `config`). An explicit
   caller value always wins.
5. **No impure builtins.** `isDarwin` is supplied by the consumer
   (`pkgs.stdenv.isDarwin`), never `builtins.currentSystem`.

## Why there is no `_module.args` convenience module

A module argument used as top-level `config` content is forced during module
merge, while `_module.args` lives inside `config` — a cycle that always throws
`infinite recursion encountered`. `specialArgs` is the only correct mechanism.
Do not reintroduce `modules/default.nix` that sets
`_module.args.mkService = …`.

## Testing

```sh
nix flake check
nix eval --json .#checks.aarch64-darwin.eval.evalResult | jq
```

`checks.<system>.eval` forces `builtins.toJSON (import ./tests/eval.nix …)`,
which evaluates every assertion at build time. Add new combinations there.

Remember to `git add` before `nix flake check` — the `git+file`/git flake
fetcher only sees tracked files.

## Committing / publishing

- This directory is its own git repo (`git init` inside `nix-service/`).
- Commit `flake.lock`.
- When publishing, push to `github:niozow/nix-services` and update consumers.
