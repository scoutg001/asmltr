# Installing asmltr — instructions for an AI coding agent

**You are an AI coding agent (e.g. Claude Code) running on the machine where asmltr will live.**
Follow these steps in order to install, configure, and start asmltr. Wherever you see **⛏ ASK USER**,
stop and ask the human for that value before continuing — never invent secrets or identifiers.
Run commands from the repo root unless told otherwise. If a step fails, stop and report the exact error.

asmltr = one AI-assistant backend behind Discord / Telegram / MCP / GitHub, plus a monitoring
collector. Execution uses the **local Claude Agent SDK on the user's Claude subscription** — there is
**no `ANTHROPIC_API_KEY`**. Read `README.md` for architecture if you need context.

---

## 0. Preflight — verify the environment

Run these and confirm each; if any fails, tell the user what to install and stop:

```bash
node --version          # must be >= 18
claude --version        # Claude Code CLI must be installed AND logged in (this is the brain)
pm2 --version           # process manager; if missing: npm i -g pm2
git --version
ffmpeg -version | head -1   # ONLY needed if the user wants Discord voice mode
```

**⛏ ASK USER** (decide scope up front — it shapes the rest):
1. What should the assistant be called? (→ `ASSISTANT_NAME`)
2. Which channels do they want now? (any of: **discord, telegram, mcp, github**)
3. How should secrets be provided? (recommended: **put them directly in `.env`**; advanced: a vault command)

---

## 1. Clone + install dependencies

```bash
git clone <REPO_URL> asmltr && cd asmltr
for d in core connectors insights/collector cli; do (cd "$d" && npm install) || exit 1; done
```

(Only `npm install` the `insights/dashboard` too if the user wants the web dashboard.)

---

## 2. Configure `.env`

```bash
cp .env.example .env
```

Edit `.env` and set:
- `ASSISTANT_NAME` — from step 0.
- The secret keys for the chosen channels/features. **⛏ ASK USER** for each needed value:
  - `OPENAI_API_KEY` — required (moderation; Discord voice STT).
  - `ELEVENLABS_API_KEY` — only if Discord voice mode is wanted.
  - `DISCORD_BOT_TOKEN` / `TELEGRAM_BOT_TOKEN` — for those channels.
  - For GitHub: a PAT env var, e.g. `MY_GITHUB_PAT` (you'll reference its lowercase name as the connector's `pat_bws_key`).
- `ASMLTR_ADMIN_ALERT_CMD` — optional; a command run on blocked/errored requests (`{msg}` = text). Leave unset to disable.

If the user chose a vault instead of inline secrets, set `ASMLTR_SECRET_CMD` (a shell template where
`{key}` is replaced with the secret key name) and leave the key values out of `.env`. See the header of
`shared/secrets.js` for the resolution order.

---

## 3. Seed the trust store (DEFAULT-DENY — nobody has access until you do this)

```bash
cp core/src/trust/seed.example.json core/src/trust/seed.json
```

Edit `seed.json`. **⛏ ASK USER** for their own identifiers on each channel they'll use, and make them
the `owner` principal with `bypass_moderation: true`:
- discord → their numeric Discord user ID
- telegram → their Telegram username
- mcp → the `identity.username` you'll assign their OAuth client in step 4
- github → their GitHub login

Then seed:
```bash
node core/src/trust/seed.js
```
Add teammates as additional principals (optionally with a limited `role_id`) — but only people the user names.

---

## 4. Per-channel setup

**MCP only** — pre-register OAuth clients:
```bash
cp connectors/types/mcp/clients.example.json connectors/types/mcp/clients.json
```
**⛏ ASK USER** for each client (e.g. their Claude web app, a teammate's Claude Code CLI). For each, set a
`client_id`, a strong random `client_secret`, the correct `redirect_uris`, and an `identity.username` that
matches a principal you seeded in step 3. Also set `BASE_URL` in `.env` to the public URL where the MCP
server will be reached.

**GitHub only** — the connector acts as the PAT's own account. Make sure the PAT env var from step 2 is
set; you'll pass its key name as `pat_bws_key` when you create the instance in step 6.

---

## 5. Start the host services

```bash
pm2 start core/ecosystem.config.js
pm2 start insights/collector/ecosystem.config.js
pm2 start connectors/manager/ecosystem.config.js
pm2 save        # persist across reboots (optional; also run `pm2 startup` and follow its instructions)
```

Verify:
```bash
curl -s 127.0.0.1:3023/health          # → {"status":"ok",...}
curl -s 127.0.0.1:3024/types | head    # manager lists available connector types
```

---

## 6. Add each channel instance

The connector **manager** (`127.0.0.1:3024`) owns instances. `GET /types` returns each type's full
config schema — consult it for all options. Create one instance per channel the user wants. Examples:

```bash
# Discord
curl -s -X POST 127.0.0.1:3024/instances -H 'Content-Type: application/json' -d '{
  "type":"discord","name":"main","enabled":true,
  "config":{"bot_token_bws_key":"discord_bot_token","dm_allowed_user_id":"<owner discord id>"}
}'

# Telegram
curl -s -X POST 127.0.0.1:3024/instances -H 'Content-Type: application/json' -d '{
  "type":"telegram","name":"main","enabled":true,
  "config":{"bot_token_bws_key":"telegram_bot_token"}
}'

# GitHub (start dry_run:true to observe before it posts)
curl -s -X POST 127.0.0.1:3024/instances -H 'Content-Type: application/json' -d '{
  "type":"github","name":"main","enabled":true,
  "config":{"pat_bws_key":"my_github_pat","repos":[{"full":"owner/repo","pat_bws_key":"my_github_pat"}],"dry_run":true}
}'

# MCP
curl -s -X POST 127.0.0.1:3024/instances -H 'Content-Type: application/json' -d '{
  "type":"mcp","name":"main","enabled":true,
  "config":{"port":3019,"base_url":"https://mcp.example.com"}
}'
```

Note on secret key names: a `*_bws_key` / `pat_bws_key` value is the **name of a secret** the provider
resolves (e.g. `discord_bot_token` → env `DISCORD_BOT_TOKEN`), never the token itself.

---

## 7. Verify it's live

```bash
# each instance should report started/online in its logs:
for id in $(curl -s 127.0.0.1:3024/instances | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>JSON.parse(s).instances.forEach(i=>console.log(i.id)))"); do
  echo "== $id =="; curl -s 127.0.0.1:3024/instances/$id/logs | tail -c 400; echo
done
```

Then have the user send a real message on one channel (from their owner identity) and confirm a reply.
Optionally run the CLI: `node cli/asmltr.js ls` (or link it onto PATH) to watch live sessions.

---

## 8. Troubleshooting

- **Connector logs "no bot token" / secret is null** → the secret key name in the instance config
  doesn't resolve. Check the matching `*_KEY`/token is in `.env` (UPPER_SNAKE of the key), or that
  `ASMLTR_SECRET_CMD` resolves it. Restart the instance: `curl -X POST 127.0.0.1:3024/instances/<id>/restart`.
- **Assistant replies but declines everything / "no access"** → the sender isn't a seeded principal, or
  their identifier for that surface is wrong. Fix `seed.json` and re-run `node core/src/trust/seed.js --force`.
- **Core exits immediately** → almost always the `claude` CLI isn't installed or not logged in. Run
  `claude` once interactively to confirm auth, then `pm2 restart asmltr-core`.
- **Update an instance's config** → `PATCH /instances/<id>` with the **full merged** `config` object
  (it's validated against the schema; partial configs are rejected).

Report back to the user: which channels are live, the owner principal you seeded, and anything you had to skip.
