# NixOS module for asmltr — the three host services (core, connector-manager,
# insights-collector) run under a dedicated `asmltr` system user with a single
# persistent state/HOME dir at /var/lib/asmltr.
#
# FLAKE-AGNOSTIC (the nix/ rule): no `self`, no `inputs`, no flake-only values.
# Imported by flake.nix as `nixosModules.asmltr` AND usable directly via
# `imports = [ ./nix/module.nix ]`. It resolves its own package + node through
# callPackage + versions.nix, the same single-source pattern the package uses.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.asmltr;

  # Node comes from nix/versions.nix — the ONE place the version is written, shared
  # with nix/package.nix. opus/better-sqlite3 are compiled to this node's ABI, so the
  # services MUST run under the same node the workspace was built with.
  nodejs = pkgs.${(import ./versions.nix).nodejs};
  nodeBin = "${nodejs}/bin/node";

  stateDir = "/var/lib/asmltr";
  # The installed workspace tree inside the store derivation.
  appRoot = "${cfg.package}/lib/node_modules/asmltr";

  # Env shared by all three services. Data stores + HOME live under /var/lib/asmltr
  # (StateDirectory), so the Claude Max login ($HOME/.claude) and every sqlite DB
  # persist across nixos-rebuild and stay out of the read-only store.
  commonEnv = {
    HOME = stateDir;
    NODE_ENV = "production";

    # The updater stands down on a managed install (scripts/update.js exits 6; the
    # /v2/update/run endpoint reports managed instead of git-resetting the store).
    ASMLTR_UPDATE_MANAGED = "nixos";
    # Pin runtime.js's state dir (else it falls back to $HOME/.asmltr — same place here,
    # but explicit keeps model/flag files under the StateDirectory unambiguously).
    ASMLTR_STATE_DIR = stateDir;

    ASSISTANT_NAME = cfg.assistantName;
    ASMLTR_MODEL = cfg.model;

    # Every data store under the writable state dir (each module mkdirs its own parent,
    # so files directly under stateDir are created on first boot).
    ASMLTR_CORE_DB = "${stateDir}/core.db";
    ASMLTR_TRUST_DB = "${stateDir}/trust.db";
    ASMLTR_CORE_DATA = stateDir;
    ASMLTR_MOD_LOG_DIR = "${stateDir}/moderation-logs";
    ASMLTR_CONNECTORS_DB = "${stateDir}/connectors.db";
    ASMLTR_INSIGHTS_DB = "${stateDir}/insights.db";
    # Points the manager's announcements queue at the writable state dir. The
    # manager reads this var (connectors/manager/server.js: ANNOUNCE_FILE =
    # process.env.ASMLTR_ANNOUNCE_FILE || <__dirname>/data/announcements.json), so
    # POST /announce writes under /var/lib/asmltr instead of the read-only store.
    # Every data path is env-driven, so all persistent state is writable.
    ASMLTR_ANNOUNCE_FILE = "${stateDir}/announcements.json";

    # Ports (bind 127.0.0.1 — the servers hardcode the loopback host).
    ASMLTR_CORE_PORT = toString cfg.corePort;
    ASMLTR_MANAGER_PORT = toString cfg.managerPort;
    ASMLTR_INSIGHTS_PORT = toString cfg.insightsPort;

    # Inter-service URLs (defaults track the ports above).
    ASMLTR_CORE_URL = "http://127.0.0.1:${toString cfg.corePort}/v2/handle";
    ASMLTR_CORE_BASE = "http://127.0.0.1:${toString cfg.corePort}";
    ASMLTR_MANAGER_URL = "http://127.0.0.1:${toString cfg.managerPort}";
    ASMLTR_COLLECTOR_URL = "http://127.0.0.1:${toString cfg.insightsPort}/ingest";
  };

  # Systemd hardening. ProtectSystem=strict makes the whole FS read-only EXCEPT the
  # paths StateDirectory grants (/var/lib/asmltr) — the credential + DBs stay writable,
  # the store + system stay read-only.
  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
  };

  # The insights-collector's front door (insights/collector/frontdoor.js) is OPT-IN:
  # it turns on ONLY when ASMLTR_DASHBOARD_DIST points at a built dashboard dist/.
  # When dashboard.enable is true we set it to the dashboard derivation's store path
  # (nix/dashboard.nix's $out IS the dist/, containing index.html). ASMLTR_CORE_BASE
  # is already in commonEnv tracking corePort; ASMLTR_MANAGER_BASE is set here so the
  # front door's /manager proxy tracks a non-default managerPort too (the front door's
  # own default is 127.0.0.1:3024, correct only at the default port). The three
  # per-route bearer tokens are SECRETS and come from environmentFile, never the store.
  collectorExtraEnv = lib.optionalAttrs cfg.dashboard.enable {
    ASMLTR_DASHBOARD_DIST = "${cfg.dashboard.package}";
    ASMLTR_MANAGER_BASE = "http://127.0.0.1:${toString cfg.managerPort}";
  };

  mkService = { description, execScript, workingDirectory, extraEnv ? { } }: {
    inherit description;
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    environment = commonEnv // extraEnv;
    # git is looked up best-effort for the /version build-sha; node for any child spawn.
    path = [ nodejs pkgs.git pkgs.coreutils ];
    serviceConfig = {
      Type = "simple";
      User = "asmltr";
      Group = "asmltr";
      WorkingDirectory = workingDirectory;
      ExecStart = "${nodeBin} ${execScript}";
      StateDirectory = "asmltr";
      StateDirectoryMode = "0750";
      Restart = "on-failure";
      RestartSec = 2;
      # Operator-managed secrets (agenix/sops). Optional — services boot without it.
      EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
    } // hardening;
  };
in
{
  options.services.asmltr = {
    enable = lib.mkEnableOption "asmltr assistant backend (core + connector-manager + insights-collector)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { inherit nodejs; };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The built asmltr workspace derivation to run.";
    };

    corePort = lib.mkOption {
      type = lib.types.port;
      default = 3023;
      description = "Loopback port for asmltr-core (ASMLTR_CORE_PORT).";
    };
    managerPort = lib.mkOption {
      type = lib.types.port;
      default = 3024;
      description = "Loopback port for asmltr-connector-manager (ASMLTR_MANAGER_PORT).";
    };
    insightsPort = lib.mkOption {
      type = lib.types.port;
      default = 3017;
      description = "Loopback port for asmltr-insights-collector (ASMLTR_INSIGHTS_PORT).";
    };

    assistantName = lib.mkOption {
      type = lib.types.str;
      default = "asmltr";
      description = "ASSISTANT_NAME — the assistant's name in prompts + channel awareness.";
    };
    model = lib.mkOption {
      type = lib.types.str;
      default = "opus";
      description = "ASMLTR_MODEL — model alias/id for channel turns (rides the Claude subscription).";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/asmltr.env";
      description = ''
        Path to an environment file (managed by agenix/sops, NOT in the store) holding
        secrets: DISCORD_BOT_TOKEN, TELEGRAM_BOT_TOKEN, OPENAI_API_KEY, ELEVENLABS_API_KEY,
        and optional overrides for ASSISTANT_NAME / ASMLTR_MODEL. Loaded by all three
        services. Never set ANTHROPIC_API_KEY here — agent execution must stay on the
        Claude subscription (the core strips it regardless).

        When services.asmltr.dashboard.enable is true this file must ALSO carry the
        front door's three per-route bearer tokens (see the dashboard option below):
        ASMLTR_INSIGHTS_TOKEN, ASMLTR_CONTROL_TOKEN, ASMLTR_MANAGER_TOKEN.
      '';
    };

    dashboard = {
      enable = lib.mkEnableOption ''
        the in-app dashboard front door on the insights collector. When on, the
        collector (insightsPort, default 3017) serves the dashboard SPA and reverse
        proxies its API calls through insights/collector/frontdoor.js, gating each
        request via the core's /v2/auth/verify. This replaces the separate nginx
        container from the Docker deploy; no extra service is added.

        Enabling this sets ASMLTR_DASHBOARD_DIST (the only switch the front door
        checks) to the dashboard derivation's dist/ in the store.

        SECRETS — the front door injects a per-route bearer from the environment, and
        these are NOT in the store. Set all three in services.asmltr.environmentFile,
        each to the same value the collector/manager already verify:
          ASMLTR_INSIGHTS_TOKEN  — read routes (/api)
          ASMLTR_CONTROL_TOKEN   — control routes (/api/control); the collector also
                                   accepts its own ASMLTR_INSIGHTS_CONTROL_TOKEN
          ASMLTR_MANAGER_TOKEN   — the connector-manager proxy (/manager)
        Without them the proxied routes reach the upstreams with no/blank bearer and
        the upstream rejects them; the front door still fails closed for lack of a
        session regardless.

        ACCESS CONTROL — the front door only enforces the core's own session gate
        (/v2/auth/verify) plus per-route bearers. The module binds loopback only, so
        real front auth still requires the operator's reverse proxy / Authelia in
        front, exactly as the non-dashboard deploy does. Nothing here opens a port to
        the network and no tokens are invented or hardcoded.

        ASMLTR_CORE_BASE / ASMLTR_MANAGER_BASE default to loopback and are wired to
        the configured corePort/managerPort automatically; they need no manual setting.
      '';

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./dashboard.nix { inherit nodejs; };
        defaultText = lib.literalExpression "pkgs.callPackage ./dashboard.nix { }";
        description = ''
          The built dashboard derivation (nix/dashboard.nix) whose $out is the static
          dist/. Its store path becomes ASMLTR_DASHBOARD_DIST on the collector.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.asmltr = {
      isSystemUser = true;
      group = "asmltr";
      home = stateDir;
      description = "asmltr assistant backend service user";
    };
    users.groups.asmltr = { };

    systemd.services.asmltr-core = mkService {
      description = "asmltr core — pipeline + HTTP server";
      execScript = "${appRoot}/core/src/server.js";
      workingDirectory = "${appRoot}/core";
    };

    systemd.services.asmltr-connector-manager = mkService {
      description = "asmltr connector manager — supervisor + config API";
      execScript = "${appRoot}/connectors/manager/server.js";
      workingDirectory = "${appRoot}/connectors";
    };

    systemd.services.asmltr-insights-collector = mkService {
      description = "asmltr insights collector — telemetry sink + dashboard API";
      execScript = "${appRoot}/insights/collector/server.js";
      workingDirectory = "${appRoot}/insights/collector";
      # Turns the front door on (ASMLTR_DASHBOARD_DIST) when dashboard.enable is set.
      extraEnv = collectorExtraEnv;
    };
  };
}
