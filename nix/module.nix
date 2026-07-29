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
    # NOTE: set forward-compatibly, but the announce feature does NOT work yet. The
    # manager still hardcodes announcements.json under the read-only store
    # (connectors/manager/server.js:221 writes path.join(__dirname, 'data', ...)), so
    # POST /announce returns 500 under ProtectSystem=strict. This var has no effect
    # until the upstream cleanup (announce env var, PR #30) lands and the tree reads it;
    # every other data path is already env-driven, so the rest of the state is writable.
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

  mkService = { description, execScript, workingDirectory }: {
    inherit description;
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    environment = commonEnv;
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
      '';
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
    };
  };
}
