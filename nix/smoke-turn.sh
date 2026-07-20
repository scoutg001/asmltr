#!/usr/bin/env bash
# Run the Nix-built core against a scratch data dir + this box's Claude login,
# and drive one real turn through the same runner the service uses.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT="${BUILT:-$ROOT/result/lib/node_modules/asmltr}"
[ -d "$BUILT" ] || { echo "build first: nix build .#asmltr-workspace"; exit 1; }
export BUILT

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export ASMLTR_CORE_DB="$SCRATCH/core.db" ASMLTR_TRUST_DB="$SCRATCH/trust.db" \
       ASMLTR_CORE_DATA="$SCRATCH/data" ASMLTR_MOD_LOG_DIR="$SCRATCH/modlogs"
export ASMLTR_MODEL="${ASMLTR_MODEL:-haiku}"   # cheap model for the smoke turn

node -e '
  const { runTurn } = require(process.env.BUILT + "/core/src/runner.js");
  // runTurn(opts) is exported by runner.js and routes to the default (claude) engine,
  // whose runTurn accepts { prompt, systemPrompt, cwd, ... } and returns { text, ... }.
  (async () => {
    const r = await runTurn({ prompt: "Reply with exactly: NIXOK", systemPrompt: "", cwd: process.env.HOME });
    const text = (r && (r.text || r.output || JSON.stringify(r))) || "";
    console.log("TURN_RESULT:", text.slice(0, 200));
    process.exit(/NIXOK/.test(text) ? 0 : 2);
  })().catch(e => { console.error("TURN_ERR:", e.message); process.exit(3); });
'
