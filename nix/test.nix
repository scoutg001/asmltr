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

  # FAKE secrets for the dashboard node only — never a real credential. ASMLTR_AUTH=on
  # flips core's /v2/auth/verify from break-glass 200 to a real gate: with no account
  # created and no session cookie it returns 401, which is exactly what proves the
  # front door fails closed. The three bearer tokens are dummy strings; no upstream
  # auth call actually succeeds at boot, and no VM step exercises a real authed session.
  # ASMLTR_AUTH_INSECURE_COOKIE=1 drops the Secure flag on the session cookie so the
  # positive-path assertion (below) can replay it over plain http://127.0.0.1 with curl;
  # over https in production the cookie stays Secure. Test-only.
  dashboardEnvFile = pkgs.writeText "asmltr-dashboard-test.env" ''
    ASMLTR_AUTH=on
    ASMLTR_AUTH_INSECURE_COOKIE=1
    ASMLTR_INSIGHTS_TOKEN=test-read-token
    ASMLTR_CONTROL_TOKEN=test-control-token
    ASMLTR_MANAGER_TOKEN=test-manager-token
  '';
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

  # Second node: the front door ON (services.asmltr.dashboard.enable). Same three
  # services, plus the collector serves the SPA + gated API proxy on :3017.
  nodes.dashboard = { ... }: {
    imports = [ ./module.nix ];
    services.asmltr = {
      enable = true;
      inherit package;
      assistantName = "TestBot";
      dashboard.enable = true;      # sets ASMLTR_DASHBOARD_DIST → front door on
      environmentFile = dashboardEnvFile; # fake tokens + ASMLTR_AUTH=on (see above)
    };
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

    # --- dashboard node: the front door is ON (services.asmltr.dashboard.enable) ---
    dashboard.wait_for_unit("asmltr-core.service")
    dashboard.wait_for_unit("asmltr-connector-manager.service")
    dashboard.wait_for_unit("asmltr-insights-collector.service")
    # core + collector answer /health (front door is a no-op for /health)
    dashboard.wait_until_succeeds("curl -sf http://127.0.0.1:3023/health", timeout=60)
    dashboard.wait_until_succeeds("curl -sf http://127.0.0.1:3017/health", timeout=60)

    # a) GET / serves the SPA: 200 with the Vue mount point from index.html.
    dashboard.wait_until_succeeds(
        "curl -sf http://127.0.0.1:3017/ | grep -q 'id=\"app\"'", timeout=60
    )

    # b) fails closed: /api/sessions with NO session cookie → 401. The /api gate calls
    #    core /v2/auth/verify, which (ASMLTR_AUTH=on, no account) returns non-2xx, so the
    #    front door stops at 401 and never reaches the collector's own /api handler.
    code = dashboard.succeed(
        "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3017/api/sessions"
    ).strip()
    assert code == "401", f"expected 401 from gated /api/sessions, got {code}"

    # c) the ungated login path is reachable through the front door — NOT a 401 gate.
    #    /v2/auth is mounted ungated (login/setup/status must work without a session).
    status = dashboard.succeed(
        "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3017/v2/auth/status"
    ).strip()
    assert status == "200", f"expected 200 from ungated /v2/auth/status, got {status}"

    # d) POSITIVE path — a WORKING gate must also ADMIT a valid session, else a dead
    #    auth endpoint that 401s everything (including the allow path) would pass (b)
    #    and masquerade as a working gate. Create the first-run account, log in through
    #    the front door to get a session cookie, then hit a gated route WITH the cookie
    #    and assert 2xx. All three hops go through the collector front door on :3017.
    dashboard.succeed(
        "curl -sf -X POST http://127.0.0.1:3017/v2/auth/setup "
        "-H 'Content-Type: application/json' "
        "-d '{\"username\":\"admin\",\"password\":\"correct-horse-battery-staple\"}'"
    )
    dashboard.succeed(
        "curl -sf -c /tmp/asmltr-cookies -X POST http://127.0.0.1:3017/v2/auth/login "
        "-H 'Content-Type: application/json' "
        "-d '{\"username\":\"admin\",\"password\":\"correct-horse-battery-staple\"}'"
    )
    authed = dashboard.succeed(
        "curl -s -b /tmp/asmltr-cookies -o /dev/null -w '%{http_code}' "
        "http://127.0.0.1:3017/api/sessions"
    ).strip()
    assert authed.startswith("2"), (
        f"expected 2xx from gated /api/sessions WITH a valid session cookie, got {authed}"
    )
  '';
}
