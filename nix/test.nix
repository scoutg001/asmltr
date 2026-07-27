# nixosTest for the asmltr module: boots a VM that enables all three services with
# the Nix-built workspace, asserts each reaches active + answers /health on loopback,
# and that the updater reports managed:true (because ASMLTR_UPDATE_MANAGED=nixos).
#
# No real credentials: no Claude turn is exercised here (moderation's OpenAI client is
# lazy — built only on a real inbound, never at boot or on /health), so all three boot
# clean without a secret. The on-box real-turn smoke covers a live turn separately.
#
# Flake-agnostic: takes `pkgs`, resolves node + package the same way the module does.
{ pkgs }:

let
  nodejs = pkgs.${(import ./versions.nix).nodejs};
  package = pkgs.callPackage ./package.nix { inherit nodejs; };
in
pkgs.testers.nixosTest {
  name = "asmltr-module";

  nodes.machine = { ... }: {
    imports = [ ./module.nix ];
    services.asmltr = {
      enable = true;
      inherit package;
      assistantName = "TestBot";
      # no environmentFile: prove the services boot with zero secrets.
    };
    # Three node processes + a VM; give it headroom.
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

  testScript = ''
    start_all()

    # 1) each service reaches active
    machine.wait_for_unit("asmltr-core.service")
    machine.wait_for_unit("asmltr-connector-manager.service")
    machine.wait_for_unit("asmltr-insights-collector.service")

    # 2) each answers /health on its loopback port
    machine.wait_until_succeeds("curl -sf http://127.0.0.1:3023/health", timeout=60)
    machine.wait_until_succeeds("curl -sf http://127.0.0.1:3024/health", timeout=60)
    machine.wait_until_succeeds("curl -sf http://127.0.0.1:3017/health", timeout=60)

    # health bodies name each service (sanity that the right process answered)
    machine.succeed("curl -sf http://127.0.0.1:3023/health | grep -q asmltr-core")
    machine.succeed("curl -sf http://127.0.0.1:3024/health | grep -q asmltr-connector-manager")
    machine.succeed("curl -sf http://127.0.0.1:3017/health | grep -q asmltr-insights-collector")

    # 3) the updater reports managed:true (ASMLTR_UPDATE_MANAGED=nixos). getManaged()
    #    short-circuits before any git, so this is robust in the git-less store.
    machine.succeed(
        "curl -sf -X POST http://127.0.0.1:3023/v2/update/run "
        "-H 'Content-Type: application/json' -d '{}' | grep -q '\"managed\":true'"
    )
    machine.succeed(
        "curl -sf -X POST http://127.0.0.1:3023/v2/update/run "
        "-H 'Content-Type: application/json' -d '{}' | grep -q '\"manager\":\"nixos\"'"
    )

    # 4) bind loopback only (asmltr non-negotiable #3): each port listens on 127.0.0.1
    machine.succeed("ss -ltn | grep -q '127.0.0.1:3023'")
    machine.succeed("ss -ltn | grep -q '127.0.0.1:3024'")
    machine.succeed("ss -ltn | grep -q '127.0.0.1:3017'")

    # 5) state dir exists, owned by the asmltr user, and DBs landed there (not the store)
    machine.succeed("test -d /var/lib/asmltr")
    machine.succeed("stat -c '%U' /var/lib/asmltr | grep -q asmltr")
    machine.succeed("test -f /var/lib/asmltr/insights.db")
  '';
}
