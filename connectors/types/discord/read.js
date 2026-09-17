'use strict';
/**
 * Discord read ops: what servers am I in, what channels can I see, what was said.
 *
 * Why here and not in index.js: the connector already answers `GET /channels` and `GET /servers` on
 * its own loopback port, but those are the enable/disable control plane for the TUI and dashboard.
 * Nothing outside the connector can ask, because `meta.readable` was absent and the manager refuses
 * `POST /read` for a type that does not declare it. Declaring the ops here puts Discord on the same
 * contract the mailbox already uses (manager `/read` → connector `/read`), so the CLI and the agent
 * get it without a second transport (see issue #164).
 *
 * These functions are mechanical: resolve, fetch, filter, shape. No trust math, deliberately. Who
 * may read what is core's decision (#132's gate, and #160's "no Discord trust math in the
 * connector"), so what ships here is three defaults that avoid widening #132 rather than a policy
 * engine of its own:
 *
 *   - DMs are excluded unless the caller asks for them by name. A DM is the most private surface the
 *     bot touches, and #132 names "other DMs" as the thing not to reach into casually.
 *   - Operator-disabled channels are excluded unless the caller asks. channelEnabled() already means
 *     "fully ignore" for ingest and reply (index.js), so reading one anyway would contradict a
 *     setting the operator already made.
 *   - Every op emits an audit event, so a cross-channel crossing is visible after the fact while the
 *     real gate is still a design.
 *
 * Injected deps rather than imports, so the ops are testable against a fake client instead of a live
 * gateway: { client, channelEnabled, resolveChannel, emit, log }.
 */

const OPS = ['guilds', 'channels', 'history', 'search'];

// discord.js ChannelType numbers. Named here because the numbers appear raw in the existing
// endpoint (`[0, 5]`) and a reader should not have to guess which is which.
const TYPES = {
  0: 'text', 1: 'dm', 2: 'voice', 3: 'group-dm', 4: 'category', 5: 'announcement',
  10: 'announcement-thread', 11: 'thread', 12: 'private-thread', 13: 'stage',
  14: 'directory', 15: 'forum', 16: 'media',
};
const PRIVATE_TYPES = new Set([1, 3]);          // dm, group-dm
const CONTAINER_TYPES = new Set([4, 14]);       // category, directory: hold no messages of their own
const THREAD_TYPES = new Set([10, 11, 12]);

/** Discord caps one messages.fetch at 100; anything larger has to paginate. */
const FETCH_MAX = 100;
const HISTORY_DEFAULT = 50;
const HISTORY_CAP = 500;                        // a bound, so "limit: 1e9" cannot walk a whole channel
const SCAN_DEFAULT = 200;                       // per channel, for search
const SCAN_CAP = 1000;

const typeName = (t) => TYPES[t] || `type-${t}`;
const lower = (s) => String(s == null ? '' : s).toLowerCase();
const clamp = (n, dflt, cap) => {
  const v = Number(n);
  if (!Number.isFinite(v) || v <= 0) return dflt;
  return Math.min(Math.floor(v), cap);
};

/** Guilds the bot is a member of, newest cache state, optionally filtered by name. */
function listGuilds(deps, args = {}) {
  const q = lower(args.q);
  const guilds = [...deps.client.guilds.cache.values()]
    .map((g) => ({ id: g.id, name: g.name, member_count: g.memberCount ?? null }))
    .filter((g) => !q || lower(g.name).includes(q))
    .sort((a, b) => a.name.localeCompare(b.name));
  return { guilds, count: guilds.length };
}

/**
 * Every channel the bot can see, as rows rather than a tree. Supersedes `GET /channels` for lookup:
 * that one is GuildText + Announcement only, with no filter, which makes "which channel is the
 * shop one" a client-side problem.
 *
 * `include_containers` exists because a category is occasionally what you are actually looking for
 * (to find its children), but it is off by default since a category holds no messages.
 */
function listChannels(deps, args = {}) {
  const q = lower(args.q);
  const guildQ = lower(args.guild);
  const wantTypes = args.type
    ? new Set(String(args.type).split(',').map((s) => s.trim().toLowerCase()).filter(Boolean))
    : null;
  const includeDms = !!args.include_dms;
  const includeDisabled = !!args.include_disabled;
  const includeContainers = !!args.include_containers;

  const rows = [];
  const skipped = { disabled: 0, dm: 0, unviewable: 0 };

  const consider = (ch, guild) => {
    const t = ch.type;
    if (PRIVATE_TYPES.has(t)) { if (!includeDms) { skipped.dm++; return; } }
    if (CONTAINER_TYPES.has(t) && !includeContainers) return;
    const name = typeName(t);
    if (wantTypes && !wantTypes.has(name)) return;
    // `viewable` is false when the bot lacks View Channel. Listing it would promise a read that
    // history would then refuse, so leave it out and say how many were hidden.
    if (ch.viewable === false) { skipped.unviewable++; return; }
    const label = ch.name || (ch.recipient && ch.recipient.username) || ch.id;
    if (q && !lower(label).includes(q)) return;
    const enabled = deps.channelEnabled ? !!deps.channelEnabled(ch.id) : true;
    if (!enabled && !includeDisabled) { skipped.disabled++; return; }
    rows.push({
      channel_id: ch.id,
      name: label,
      type: name,
      guild_id: guild ? guild.id : null,
      guild: guild ? guild.name : null,
      parent_id: ch.parentId || null,
      topic: ch.topic || null,
      enabled,
      thread: THREAD_TYPES.has(t),
      archived: ch.archived == null ? null : !!ch.archived,
    });
  };

  for (const g of deps.client.guilds.cache.values()) {
    if (guildQ && !lower(g.name).includes(guildQ) && g.id !== args.guild) continue;
    for (const ch of g.channels.cache.values()) consider(ch, g);
    // Threads hang off their parent and are not always in channels.cache on their own.
    if (g.channels && g.channels.cache) {
      for (const ch of g.channels.cache.values()) {
        const tc = ch.threads && ch.threads.cache;
        if (tc) for (const th of tc.values()) consider(th, g);
      }
    }
  }
  // Walk the DMs even when they are excluded, so `skipped.dm` can say how many are being held back.
  // consider() does the excluding; counting here would double-count when include_dms is set.
  if (deps.client.channels && deps.client.channels.cache) {
    for (const ch of deps.client.channels.cache.values()) if (PRIVATE_TYPES.has(ch.type)) consider(ch, null);
  }

  rows.sort((a, b) => `${a.guild || ''}#${a.name}`.localeCompare(`${b.guild || ''}#${b.name}`));
  return { channels: rows, count: rows.length, skipped };
}

/**
 * Turn whatever the caller typed into one channel object: an alias from channel-aliases.json, a raw
 * snowflake, or a channel name. A name that matches more than one channel is an error listing the
 * candidates rather than a silent pick, because guessing here reads the wrong room.
 */
function resolveChannelRef(deps, ref, opts = {}) {
  if (!ref) { const e = new Error('target required (channel id, alias, or name)'); e.code = 'BAD_REQUEST'; throw e; }
  const wanted = deps.resolveChannel ? deps.resolveChannel(String(ref)) : String(ref);

  const byId = deps.client.channels && deps.client.channels.cache && deps.client.channels.cache.get(String(wanted));
  if (byId) return byId;
  for (const g of deps.client.guilds.cache.values()) {
    const hit = g.channels.cache.get(String(wanted));
    if (hit) return hit;
  }

  const needle = lower(wanted).replace(/^#/, '');
  const matches = [];
  for (const g of deps.client.guilds.cache.values()) {
    for (const ch of g.channels.cache.values()) {
      if (CONTAINER_TYPES.has(ch.type)) continue;
      if (lower(ch.name) === needle || `${lower(g.name)}#${lower(ch.name)}` === needle) matches.push({ ch, g });
    }
  }
  if (!matches.length) {
    const e = new Error(`no channel matching '${ref}' (try: asmltr discord channels -q ${String(ref).slice(0, 24)})`);
    e.code = 'NOT_FOUND';
    throw e;
  }
  if (matches.length > 1 && !opts.allowAmbiguous) {
    const list = matches.map((m) => `${m.g.name}#${m.ch.name} (${m.ch.id})`).join(', ');
    const e = new Error(`'${ref}' matches ${matches.length} channels: ${list}. Pass the channel id.`);
    e.code = 'AMBIGUOUS';
    throw e;
  }
  return matches[0].ch;
}

/** The read gate, kept in one place so history and search cannot drift apart. */
function assertReadable(deps, ch, args = {}) {
  if (PRIVATE_TYPES.has(ch.type) && !args.include_dms) {
    const e = new Error('that channel is a DM; pass include_dms to read it deliberately');
    e.code = 'FORBIDDEN';
    throw e;
  }
  const enabled = deps.channelEnabled ? !!deps.channelEnabled(ch.id) : true;
  if (!enabled && !args.include_disabled) {
    const e = new Error(`channel ${ch.id} is disabled for this instance; pass include_disabled to read it anyway`);
    e.code = 'FORBIDDEN';
    throw e;
  }
  return enabled;
}

function shapeMessage(m, ch) {
  const att = [];
  if (m.attachments && typeof m.attachments.values === 'function') {
    for (const a of m.attachments.values()) att.push({ name: a.name || null, url: a.url || null, bytes: a.size ?? null, mime: a.contentType || null });
  }
  return {
    id: m.id,
    ts: m.createdTimestamp ? new Date(m.createdTimestamp).toISOString() : null,
    edited_ts: m.editedTimestamp ? new Date(m.editedTimestamp).toISOString() : null,
    channel_id: (ch && ch.id) || (m.channel && m.channel.id) || null,
    channel: (ch && ch.name) || null,
    author: (m.author && (m.author.username || m.author.tag)) || null,
    author_id: (m.author && m.author.id) || null,
    bot: !!(m.author && m.author.bot),
    content: m.content || '',
    attachments: att,
    reply_to: (m.reference && m.reference.messageId) || null,
    pinned: !!m.pinned,
  };
}

/**
 * Messages from one channel, newest first. Paginates because Discord caps a fetch at 100, and stops
 * at HISTORY_CAP so a bad limit cannot walk a channel's whole life.
 */
async function fetchHistory(deps, args = {}) {
  const ch = resolveChannelRef(deps, args.target);
  assertReadable(deps, ch, args);
  if (!ch.messages || typeof ch.messages.fetch !== 'function') {
    const e = new Error(`channel ${ch.id} (${typeName(ch.type)}) holds no messages`);
    e.code = 'BAD_REQUEST';
    throw e;
  }
  const limit = clamp(args.limit, HISTORY_DEFAULT, HISTORY_CAP);
  const out = [];
  let before = args.before || null;

  while (out.length < limit) {
    const page = { limit: Math.min(FETCH_MAX, limit - out.length) };
    if (before) page.before = before;
    else if (args.after) page.after = args.after;
    else if (args.around) page.around = args.around;

    let batch;
    try { batch = await ch.messages.fetch(page); }
    catch (err) {
      // A permission failure on the first page is the whole answer; mid-pagination it just ends the walk.
      if (!out.length) { const e = new Error(`cannot read ${ch.id}: ${err.message}`); e.code = 'FORBIDDEN'; throw e; }
      break;
    }
    const list = typeof batch.values === 'function' ? [...batch.values()] : [...batch];
    if (!list.length) break;
    for (const m of list) out.push(shapeMessage(m, ch));
    if (list.length < page.limit) break;
    before = out[out.length - 1].id;
    if (args.after || args.around) break;   // those two anchor one window; do not walk past it
  }

  return {
    channel: { id: ch.id, name: ch.name || null, type: typeName(ch.type), guild: ch.guild ? ch.guild.name : null },
    messages: out,
    count: out.length,
    capped: out.length >= HISTORY_CAP,
  };
}

/**
 * Text match over recent history.
 *
 * Discord's message search endpoint is user-only and closed to bot tokens, so this is a bounded scan
 * and not a server side index. `scanned` and `truncated` ride in the response for that reason: a
 * caller has to be able to tell "no matches" from "no matches in the last 200 messages".
 */
async function searchMessages(deps, args = {}) {
  const needle = String(args.q || '').trim();
  if (!needle) { const e = new Error('search needs q'); e.code = 'BAD_REQUEST'; throw e; }
  const rx = /^\/(.+)\/([gimsu]*)$/.exec(needle);
  const test = rx ? (s) => new RegExp(rx[1], rx[2].replace('g', '')).test(s) : (s) => lower(s).includes(lower(needle));

  const perChannel = clamp(args.scan, SCAN_DEFAULT, SCAN_CAP);
  const limit = clamp(args.limit, 50, 500);

  let targets;
  if (args.target) targets = [resolveChannelRef(deps, args.target)];
  else {
    // Only the channel-SELECTION arguments. Spreading `args` here would hand `q`, the text being
    // searched for, to the channel-name filter, so a search for "note" would only ever scan channels
    // with "note" in their name (usually none, silently returning zero matches).
    const pick = {
      guild: args.guild,
      include_dms: args.include_dms,
      include_disabled: args.include_disabled,
      type: args.type || 'text,announcement,thread,announcement-thread,private-thread',
    };
    const listed = listChannels(deps, pick);
    targets = [];
    for (const row of listed.channels) {
      const ch = resolveChannelRef(deps, row.channel_id, { allowAmbiguous: true });
      if (ch) targets.push(ch);
    }
  }

  const matches = [];
  const scanned = [];
  for (const ch of targets) {
    if (matches.length >= limit) break;
    try { assertReadable(deps, ch, args); } catch (_) { continue; }
    if (!ch.messages || typeof ch.messages.fetch !== 'function') continue;
    let seen = 0, before = null, denied = null;
    while (seen < perChannel && matches.length < limit) {
      const page = { limit: Math.min(FETCH_MAX, perChannel - seen) };
      if (before) page.before = before;
      let batch;
      try { batch = await ch.messages.fetch(page); }
      catch (err) { denied = err.message; break; }
      const list = typeof batch.values === 'function' ? [...batch.values()] : [...batch];
      if (!list.length) break;
      for (const m of list) {
        seen++;
        if (test(m.content || '')) { matches.push(shapeMessage(m, ch)); if (matches.length >= limit) break; }
      }
      if (list.length < page.limit) break;
      before = list[list.length - 1].id;
    }
    scanned.push({ channel_id: ch.id, channel: ch.name || null, messages_scanned: seen, denied });
  }

  return {
    query: needle,
    regex: !!rx,
    matches,
    count: matches.length,
    scanned,
    truncated: matches.length >= limit,
    note: 'bot tokens cannot use Discord message search; this is a bounded scan of recent history',
  };
}

/**
 * The op dispatcher the connector's `POST /read` hands off to. Emits one audit event per call
 * (event_type 'control', matching how the core records a privileged action), because a turn on one
 * channel reading another one's history is exactly the crossing #132 is about.
 */
async function handleRead(deps, body = {}) {
  const op = String(body.op || '');
  if (!OPS.includes(op)) { const e = new Error(`unknown read op '${op}' (expected ${OPS.join(' | ')})`); e.code = 'BAD_REQUEST'; throw e; }

  const started = Date.now();
  let result;
  if (op === 'guilds') result = listGuilds(deps, body);
  else if (op === 'channels') result = listChannels(deps, body);
  else if (op === 'history') result = await fetchHistory(deps, body);
  else result = await searchMessages(deps, body);

  if (deps.emit) {
    try {
      deps.emit({
        event_type: 'control',
        payload: {
          action: 'discord-read',
          op,
          // The arguments, not the content: an audit trail should say what was asked for without
          // copying the messages themselves into the telemetry store.
          target: body.target || null,
          guild: body.guild || null,
          q: body.q || null,
          include_dms: !!body.include_dms,
          include_disabled: !!body.include_disabled,
          returned: result.count ?? null,
          ms: Date.now() - started,
        },
      });
    } catch (e) { if (deps.log) deps.log('read audit emit failed: ' + e.message); }
  }
  return result;
}

module.exports = {
  OPS, TYPES, PRIVATE_TYPES, CONTAINER_TYPES,
  HISTORY_DEFAULT, HISTORY_CAP, SCAN_DEFAULT, SCAN_CAP, FETCH_MAX,
  typeName, listGuilds, listChannels, resolveChannelRef, assertReadable, shapeMessage,
  fetchHistory, searchMessages, handleRead,
};
