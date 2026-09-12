{lib, mkServiceFor}: let
  # Build a service for the given platform (isDarwin) and scope.
  mk = isDarwin: scope:
    (mkServiceFor isDarwin) {
      name = "demo";
      description = "Demo service";
      command = "/bin/true";
      inherit scope;
    };

  linux = isDarwin: mk isDarwin;
  darwin = mk true;

  linuxUser = linux false "user";
  linuxSystem = linux false "system";
  darwinUser = darwin "user";
  darwinSystem = darwin "system";

  # Explicit schema override must win over the scope-derived default.
  darwinUserForcedSystem = (mkServiceFor true) {
    name = "demo";
    description = "Demo service";
    command = "/bin/true";
    scope = "user";
    nixDarwinLaunchd = true;
  };

  # Explicit wantedBy override must win.
  linuxUserForcedTarget = (mkServiceFor false) {
    name = "demo";
    description = "Demo service";
    command = "/bin/true";
    scope = "user";
    wantedBy = ["graphical-session.target"];
  };

  checks = {
    linux-user-path = linuxUser ? systemd.user.services.demo;
    linux-user-not-system = !(linuxUser ? systemd.services);
    linux-user-default-target = linuxUser.systemd.user.services.demo.Install.WantedBy == ["default.target"];

    linux-system-path = linuxSystem ? systemd.services.demo;
    linux-system-not-user = !(linuxSystem ? systemd.user);
    linux-system-default-target = linuxSystem.systemd.services.demo.Install.WantedBy == ["multi-user.target"];

    linux-wantedby-override = linuxUserForcedTarget.systemd.user.services.demo.Install.WantedBy == ["graphical-session.target"];

    darwin-user-path = darwinUser ? launchd.agents.demo;
    darwin-user-not-daemons = !(darwinUser ? launchd.daemons);
    darwin-user-home-manager-schema = darwinUser.launchd.agents.demo ? config;
    darwin-user-launchd-no-nulls = lib.all (v: v != null) (lib.attrValues darwinUser.launchd.agents.demo.config);

    darwin-system-path = darwinSystem ? launchd.daemons.demo;
    darwin-system-not-agents = !(darwinSystem ? launchd.agents);
    darwin-system-nix-darwin-schema = darwinSystem.launchd.daemons.demo ? serviceConfig;
    darwin-system-launchd-no-nulls = lib.all (v: v != null) (lib.attrValues darwinSystem.launchd.daemons.demo.serviceConfig);

    darwin-schema-override = darwinUserForcedSystem.launchd.agents.demo ? serviceConfig;

    launchd-path-merged = darwinUser.launchd.agents.demo.config.EnvironmentVariables.PATH
      == "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
  if failed == []
  then checks
  else throw "nix-services eval checks failed: ${lib.concatStringsSep ", " failed}"
