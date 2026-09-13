# Root / system services

`scope = "system"` produces a service that starts at boot without a login.
What that means depends on the platform.

## Linux (NixOS)

`mkService` emits `systemd.services.<name>` using nixpkgs' option schema:

```nix
systemd.services.<name> = {
  description = "…";
  wantedBy = ["multi-user.target"];   # default for system scope
  after = ["network-online.target"];  # if provided
  wants = ["network-online.target"];  # if provided
  partOf = […];                       # if provided
  unitConfig = {…};                   # extraSystemdUnitConfig, capitalized directives
  serviceConfig = {
    Type = "simple";
    ExecStart = command;
    Restart = "on-failure";
    RestartSec = 5;
    Environment = ["KEY=VALUE" …];
  } // extraSystemdServiceConfig;
};
```

Note this is **not** the raw `Unit`/`Service`/`Install` schema used by
home-manager's `systemd.user.services`; `mkService` picks the right schema from
the factory's `homeManager` flag and the `scope`.

### Hardening

`extraSystemdServiceConfig` is merged verbatim into `serviceConfig`, so all of
systemd's hardening directives are available:

```nix
extraSystemdServiceConfig = {
  DynamicUser = true;
  StateDirectory = "myapp";
  StateDirectoryMode = "0700";
  AmbientCapabilities = [];
  CapabilityBoundingSet = [];
  NoNewPrivileges = true;
  PrivateTmp = true;
  PrivateDevices = true;
  ProtectSystem = "strict";
  ProtectHome = true;
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectControlGroups = true;
  RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
  RestrictNamespaces = true;
  LockPersonality = true;
  MemoryDenyWriteExecute = true;
  RestrictRealtime = true;
  SystemCallFilter = ["@system-service"];
  ReadWritePaths = ["/var/lib/myapp"];
};
```

`DynamicUser = true` + `StateDirectory` gives an ephemeral user and a writable
`/var/lib/<name>` with no manual user management. If the service must read
secret files (e.g. `*_PATH` API keys), make sure they are readable by the
dynamic user or use `LoadCredential` instead.

Logs go to the journal: `journalctl -u <name>`.

## macOS (nix-darwin)

System scope emits `launchd.daemons.<name>` with the nix-darwin `serviceConfig`
schema:

```nix
launchd.daemons.<name> = {
  serviceConfig = {
    Label = label;                  # default local.<name>
    ProgramArguments = […command split on spaces…];
    RunAtLoad = true;
    KeepAlive = true;
    EnvironmentVariables = {PATH = "…";} // environment;
    StandardOutPath = "/var/log/<name>.log";
    StandardErrorPath = "/var/log/<name>-error.log";
  };
};
```

Root daemons run as root, so:

- Logs default to `/var/log` (override with `logDir`, `stdoutPath`,
  `stderrPath`).
- `username` is not consulted (it only affects user-scope log paths).
- Use a reverse-DNS `label` (e.g. `com.example.myapp`) — Apple's convention for
  system daemons. `local.<name>` is the default for convenience/parity with
  home-manager agents.

`serviceConfig` values must not contain `null`; `mkService` filters nulls out of
the generated config so this is handled for you.

## When to use which

| Situation | Scope |
| --- | --- |
| Background sync for one user | `user` |
| Service that binds a privileged port | `system` |
| Must run before/without login | `system` |
| Needs a writable state directory | `system` (`StateDirectory`) |
| Per-user toolbar/menu agent on macOS | `user` |
| System daemon on macOS | `system` |
