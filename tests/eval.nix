{
  lib,
  mkServiceFor,
}: let
  # Build a service for a given module system (`isDarwin` / `homeManager`) and
  # scope, forwarding any extra `mkService` arguments from `args`.
  mk = args @ {
    isDarwin,
    homeManager ? false,
    ...
  }:
    (mkServiceFor {inherit isDarwin homeManager;}) (
      {
        name = "demo";
        description = "Demo service";
        command = "/bin/true";
      }
      // lib.removeAttrs args ["isDarwin" "homeManager"]
    );

  # Linux, NixOS (system module system).
  nixosUser = mk {
    isDarwin = false;
    scope = "user";
  };
  nixosSystem = mk {
    isDarwin = false;
    scope = "system";
  };
  nixosUserWants = mk {
    isDarwin = false;
    scope = "user";
    wants = ["network-online.target"];
  };
  nixosUserForcedTarget = mk {
    isDarwin = false;
    scope = "user";
    wantedBy = ["graphical-session.target"];
  };
  nixosSystemWants = mk {
    isDarwin = false;
    scope = "system";
    wants = ["network-online.target"];
  };

  # Linux, home-manager.
  hmLinuxUser = mk {
    isDarwin = false;
    homeManager = true;
    scope = "user";
  };

  # macOS, nix-darwin.
  darwinUser = mk {
    isDarwin = true;
    scope = "user";
  };
  darwinSystem = mk {
    isDarwin = true;
    scope = "system";
  };

  # macOS, home-manager.
  hmDarwinUser = mk {
    isDarwin = true;
    homeManager = true;
    scope = "user";
  };

  checks = {
    # ---- Linux / NixOS user: nixpkgs option schema -----------------------
    nixos-user-path = nixosUser ? systemd.user.services.demo;
    nixos-user-not-system = !(nixosUser ? systemd.services);
    nixos-user-nixos-schema =
      nixosUser.systemd.user.services.demo ? serviceConfig
      && nixosUser.systemd.user.services.demo.serviceConfig.ExecStart == "/bin/true"
      && nixosUser.systemd.user.services.demo.description == "Demo service";
    nixos-user-no-raw-schema = !(nixosUser.systemd.user.services.demo ? Unit);
    nixos-user-default-target = nixosUser.systemd.user.services.demo.wantedBy == ["default.target"];
    nixos-user-wants = nixosUserWants.systemd.user.services.demo.wants == ["network-online.target"];
    nixos-user-wantedby-override =
      nixosUserForcedTarget.systemd.user.services.demo.wantedBy == ["graphical-session.target"];

    # ---- Linux / NixOS system: nixpkgs option schema ---------------------
    nixos-system-path = nixosSystem ? systemd.services.demo;
    nixos-system-not-user = !(nixosSystem ? systemd.user);
    nixos-system-default-target = nixosSystem.systemd.services.demo.wantedBy == ["multi-user.target"];
    nixos-system-nixos-schema =
      nixosSystem.systemd.services.demo.serviceConfig.ExecStart
      == "/bin/true"
      && nixosSystem.systemd.services.demo.description == "Demo service";
    nixos-system-wants = nixosSystemWants.systemd.services.demo.wants == ["network-online.target"];

    # ---- Linux / home-manager user: raw systemd unit schema --------------
    hm-linux-user-path = hmLinuxUser ? systemd.user.services.demo;
    hm-linux-user-raw-schema =
      hmLinuxUser.systemd.user.services.demo ? Unit
      && hmLinuxUser.systemd.user.services.demo.Service.ExecStart == "/bin/true"
      && hmLinuxUser.systemd.user.services.demo.Unit.Description == "Demo service"
      && hmLinuxUser.systemd.user.services.demo.Install.WantedBy == ["default.target"];
    hm-linux-user-no-nixos-schema = !(hmLinuxUser.systemd.user.services.demo ? serviceConfig);

    # ---- macOS / nix-darwin: `serviceConfig` ----------------------------
    darwin-user-path = darwinUser ? launchd.agents.demo;
    darwin-user-not-daemons = !(darwinUser ? launchd.daemons);
    darwin-user-nix-darwin-schema = darwinUser.launchd.agents.demo ? serviceConfig;
    darwin-user-launchd-no-nulls = lib.all (v: v != null) (lib.attrValues darwinUser.launchd.agents.demo.serviceConfig);
    darwin-system-path = darwinSystem ? launchd.daemons.demo;
    darwin-system-not-agents = !(darwinSystem ? launchd.agents);
    darwin-system-nix-darwin-schema = darwinSystem.launchd.daemons.demo ? serviceConfig;
    darwin-system-launchd-no-nulls = lib.all (v: v != null) (lib.attrValues darwinSystem.launchd.daemons.demo.serviceConfig);

    # ---- macOS / home-manager: `{ enable; config; }` ---------------------
    hm-darwin-user-path = hmDarwinUser ? launchd.agents.demo;
    hm-darwin-user-hm-schema = hmDarwinUser.launchd.agents.demo ? config;
    hm-darwin-user-enabled = hmDarwinUser.launchd.agents.demo.enable == true;
    hm-darwin-user-launchd-no-nulls = lib.all (v: v != null) (lib.attrValues hmDarwinUser.launchd.agents.demo.config);

    launchd-path-merged =
      hmDarwinUser.launchd.agents.demo.config.EnvironmentVariables.PATH
      == "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";

    # ---- home-manager + system scope is coerced to user scope -----------
    hm-linux-system-coerced = let
      r = mk {
        isDarwin = false;
        homeManager = true;
        scope = "system";
      };
    in
      r ? systemd.user.services.demo
      && !(r ? systemd.services)
      && r.systemd.user.services.demo ? Unit
      && r.systemd.user.services.demo.Install.WantedBy == ["default.target"];
    hm-darwin-system-coerced = let
      r = mk {
        isDarwin = true;
        homeManager = true;
        scope = "system";
      };
    in
      r ? launchd.agents.demo
      && !(r ? launchd.daemons)
      && r.launchd.agents.demo ? config;
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
  if failed == []
  then checks
  else throw "nix-services eval checks failed: ${lib.concatStringsSep ", " failed}"
