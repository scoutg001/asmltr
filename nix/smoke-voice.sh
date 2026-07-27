#!/usr/bin/env bash
# Prove the two voice native modules LOAD from the Nix-built tree: that
# autoPatchelfHook fixed the porcupine prebuilt and that opus compiled from
# source. This does NOT run wake-word detection or open an audio device; it only
# confirms each native binding dlopens and its symbols resolve. No Picovoice
# access key, no microphone, no network needed.
#
# It MUST run under the same node the derivation built against (the Node pinned
# in nix/versions.nix). node-pre-gyp resolves opus's binary by the running
# node's ABI + glibc version, so the host node (a different ABI/glibc) would look
# for a differently-named prebuild dir and miss. We recover that exact node from a
# shebang patchShebangs rewrote inside the built tree, so the smoke reproduces the
# service's runtime without hardcoding a store path.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT="${BUILT:-$ROOT/result/lib/node_modules/asmltr}"
[ -d "$BUILT" ] || { echo "build first: nix build .#asmltr-workspace"; exit 1; }
export BUILT

# The node the build used = the interpreter patchShebangs stamped onto the
# in-tree node-pre-gyp launcher (a known-patched bin). Fall back to a tree-wide
# scan, then to PATH node (which likely mismatches ABI and will surface it).
NODE="${NODE:-}"
if [ -z "$NODE" ]; then
  cand="$BUILT/connectors/node_modules/@discordjs/node-pre-gyp/bin/node-pre-gyp"
  if [ -f "$cand" ] && head -1 "$cand" | grep -q '^#!/nix/store/.*node'; then
    NODE="$(head -1 "$cand" | sed 's/^#!//' | awk '{print $1}')"
  fi
fi
if [ -z "$NODE" ]; then
  shim="$(grep -rIlm1 -- '^#!/nix/store/.*/bin/node$' "$BUILT" 2>/dev/null | head -1 || true)"
  [ -n "$shim" ] && NODE="$(head -1 "$shim" | sed 's/^#!//' | awk '{print $1}')"
fi
NODE="${NODE:-node}"
[ -x "$NODE" ] || NODE="$(command -v node)"
echo "using node: $NODE"

# Resolve requires from the connectors workspace, where the lockfile installs the
# voice deps (connectors/node_modules/@discordjs/opus, .../@picovoice/porcupine-node).
"$NODE" -e '
  const path = require("path");
  const Module = require("module");
  const connectors = path.join(process.env.BUILT, "connectors");
  const req = Module.createRequire(path.join(connectors, "index.js"));

  // --- @discordjs/opus: source-built .node. Constructing an OpusEncoder dlopens
  // the addon and calls into libopus; a link/ABI failure throws here. Encoding one
  // frame of silence proves the compiled binding loads and runs. ---
  const { OpusEncoder } = req("@discordjs/opus");
  const enc = new OpusEncoder(48000, 2);
  const packet = enc.encode(Buffer.alloc(48000 * 2 * 2 / 100)); // one 10ms stereo frame
  if (!packet || packet.length === 0) throw new Error("opus encode returned empty");
  console.log("OPUS_OK encoded_bytes=" + packet.length);

  // --- @picovoice/porcupine-node: prebuilt pv_porcupine.node fixed by
  // autoPatchelfHook. porcupine.js does `require(libraryPath)` only inside the
  // ctor, so constructing with a built-in keyword forces the native load, then
  // calls init() with a dummy key. The native lib is fully loaded and its init
  // symbol invoked BEFORE the key is rejected; a key/activation error is proof of
  // load. A loader/ELF error is the failure we guard against and is rethrown. ---
  const { Porcupine, BuiltinKeyword } = req("@picovoice/porcupine-node");
  let loaded = false;
  try {
    new Porcupine("dummy-access-key-not-valid", [BuiltinKeyword.PORCUPINE], [0.5]);
    loaded = true;
  } catch (e) {
    const msg = String(e && (e.stack || e.message || e));
    if (/cannot open shared object|no such file|invalid ELF|wrong ELF class|undefined symbol|MODULE_NOT_FOUND|not found at .libraryPath|Exec format error|failed to map segment/i.test(msg)) {
      throw new Error("porcupine native FAILED to load: " + msg);
    }
    loaded = true; // bad key / init error => the .node loaded and init() ran
  }
  if (!loaded) throw new Error("porcupine did not load");
  console.log("PORCUPINE_OK native binding loaded (autopatchelf ok)");

  console.log("VOICEOK");
  process.exit(0);
' || { echo "VOICE SMOKE FAILED"; exit 1; }
