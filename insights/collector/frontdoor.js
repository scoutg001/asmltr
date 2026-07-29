'use strict';
/**
 * asmltr-insights — in-app "front door" (OPT-IN, off by default).
 *
 * Ports insights/dashboard/nginx.conf.template into the collector process so the
 * dashboard SPA + its authenticated API proxy can be served WITHOUT the separate
 * nginx container. It is enabled ONLY when ASMLTR_DASHBOARD_DIST is set (points at
 * the built SPA `dist/`). When unset every function here is a no-op and the
 * collector behaves EXACTLY as before — zero regression.
 *
 * The gate mirrors nginx's `auth_request /_asmltr_authz`: for every gated route we
 * first GET ${ASMLTR_CORE_BASE}/v2/auth/verify forwarding the request's Cookie. A
 * non-2xx → 401 and stop. A 2xx → read the `Remote-User` response header and
 * propagate it as `X-Remote-User` (client-supplied X-Remote-User is stripped first,
 * so identity can't be spoofed). See frontdoor-report.md for the route-by-route map.
 *
 * Route classes:
 *   self-routes   /api/, /api/control/  — target THIS process. Gate, then inject the
 *                 matching bearer into req.headers.authorization + set x-remote-user,
 *                 and next() into the collector's own existing /api handlers.
 *   proxied       /manager/ /trust/ /v2/ /oidc/ /v2/auth/ — OTHER services. Reverse
 *                 proxy with Node's http/https (no proxy dependency).
 *   socket.io     the collector's own socket.io — gate the handshake only.
 *   static        ${ASMLTR_DASHBOARD_DIST} with SPA fallback to index.html (mounted LAST).
 */

const http = require('http');
const https = require('https');
const path = require('path');
const { URL } = require('url');

// --- config (read lazily so tests can flip env between calls) ----------------
function dist() { return process.env.ASMLTR_DASHBOARD_DIST || ''; }
function enabled() { return !!dist(); }
function coreBase() { return process.env.ASMLTR_CORE_BASE || 'http://127.0.0.1:3023'; }
function managerBase() { return process.env.ASMLTR_MANAGER_BASE || 'http://127.0.0.1:3024'; }
function insightsToken() { return process.env.ASMLTR_INSIGHTS_TOKEN || ''; }
// Front-door-facing name is ASMLTR_CONTROL_TOKEN (matches nginx.conf.template + compose);
// falls back to the collector's own ASMLTR_INSIGHTS_CONTROL_TOKEN. /api/control is a
// SELF route, so this MUST resolve to the same secret requireControl() checks.
function controlToken() { return process.env.ASMLTR_CONTROL_TOKEN || process.env.ASMLTR_INSIGHTS_CONTROL_TOKEN || ''; }
function managerToken() { return process.env.ASMLTR_MANAGER_TOKEN || ''; }

// --- forward-auth (nginx `location = /_asmltr_authz`) ------------------------
// GET ${coreBase}/v2/auth/verify with the incoming Cookie, body off. Calls back
// (err, { ok, remoteUser }). ok = response was 2xx.
function verify(cookie, cb) {
  let base;
  try { base = new URL(coreBase()); } catch (e) { return cb(e); }
  const client = base.protocol === 'https:' ? https : http;
  const req = client.request(
    {
      protocol: base.protocol,
      hostname: base.hostname,
      port: base.port || (base.protocol === 'https:' ? 443 : 80),
      method: 'GET',
      path: '/v2/auth/verify',
      headers: { Cookie: cookie || '', 'Content-Length': '0' },
    },
    (resp) => {
      const ok = resp.statusCode >= 200 && resp.statusCode < 300;
      const remoteUser = resp.headers['remote-user'] || '';
      resp.resume(); // drain, body off
      cb(null, { ok, remoteUser, status: resp.statusCode });
    }
  );
  req.on('error', (e) => cb(e));
  req.end();
}

// --- reverse proxy (Node http/https, no dependency) --------------------------
// Streams the request through so raw bodies survive (these routes are mounted
// BEFORE express.json, so req is an untouched stream).
function proxyOnce(baseUrl, req, res, opts) {
  opts = opts || {};
  let base;
  try { base = new URL(baseUrl); } catch (e) { if (!res.headersSent) res.status(502).json({ error: 'bad upstream' }); return; }
  const client = base.protocol === 'https:' ? https : http;
  let outPath = req.originalUrl;
  if (opts.stripPrefix && outPath.startsWith(opts.stripPrefix)) {
    outPath = outPath.slice(opts.stripPrefix.length);
    if (!outPath.startsWith('/')) outPath = '/' + outPath; // nginx trailing-slash strip → root
  }
  const headers = Object.assign({}, req.headers);
  headers.host = base.host;
  // Never trust a client-supplied identity header — set it only from forward-auth.
  delete headers['x-remote-user'];
  delete headers['remote-user'];
  if (opts.remoteUser != null) headers['x-remote-user'] = opts.remoteUser;
  if (opts.bearer) headers['authorization'] = 'Bearer ' + opts.bearer;
  if (opts.extraHeaders) Object.assign(headers, opts.extraHeaders);

  const preq = client.request(
    {
      protocol: base.protocol,
      hostname: base.hostname,
      port: base.port || (base.protocol === 'https:' ? 443 : 80),
      method: req.method,
      path: outPath,
      headers,
    },
    (pres) => {
      res.writeHead(pres.statusCode, pres.headers);
      pres.pipe(res);
    }
  );
  preq.on('error', () => { if (!res.headersSent) res.status(502).json({ error: 'upstream unreachable' }); });
  req.pipe(preq);
}

function gatedProxy(baseUrl, opts) {
  return function (req, res) {
    verify(req.headers.cookie || '', (err, r) => {
      if (err) return res.status(502).json({ error: 'auth backend unreachable' });
      if (!r.ok) return res.status(401).json({ error: 'unauthorized' });
      proxyOnce(baseUrl, req, res, Object.assign({}, opts, { remoteUser: r.remoteUser }));
    });
  };
}

function ungatedProxy(baseUrl, opts) {
  return function (req, res) { proxyOnce(baseUrl, req, res, opts || {}); };
}

// --- mount: proxied services + self-route gates (BEFORE express.json) --------
// Order matters (mirrors nginx most-specific-wins): /v2/auth before /v2, and the
// single /api gate picks the control-vs-read token by path so /api/control wins.
function mountProxies(app) {
  if (!enabled()) return;

  // Auth endpoints — reachable WITHOUT a session (login / setup / status / verify).
  app.use('/v2/auth', ungatedProxy(coreBase()));

  // OIDC provider — public; forward the external proto/host so issued URLs are https.
  app.use('/oidc', ungatedProxy(coreBase(), {
    extraHeaders: { 'x-forwarded-proto': 'https' },
  }));

  // Self-routes: /api/ (read bearer) and /api/control/ (control bearer). One
  // middleware, so a request is gated exactly once (express runs every matching
  // app.use prefix; nginx picks one location — this reproduces that).
  app.use('/api', function (req, res, next) {
    const isControl = req.path === '/control' || req.path.startsWith('/control/');
    verify(req.headers.cookie || '', (err, r) => {
      if (err) return res.status(502).json({ error: 'auth backend unreachable' });
      if (!r.ok) return res.status(401).json({ error: 'unauthorized' });
      // strip any client-supplied identity, then set the forward-auth one
      delete req.headers['x-remote-user'];
      delete req.headers['remote-user'];
      if (r.remoteUser) req.headers['x-remote-user'] = r.remoteUser;
      req.headers['authorization'] = 'Bearer ' + (isControl ? controlToken() : insightsToken());
      next(); // → express.json → the collector's own /api handler
    });
  });

  // Connector manager (control plane). Trailing-slash strip: /manager/x → /x.
  app.use('/manager', gatedProxy(managerBase(), { stripPrefix: '/manager', bearer: managerToken() }));

  // Trust framework on the core — keep the /trust prefix, propagate X-Remote-User, no bearer.
  app.use('/trust', gatedProxy(coreBase(), {}));

  // Core control plane — keep the /v2 prefix, propagate X-Remote-User, no bearer.
  // (/v2/auth is carved out above and wins by registration order.)
  app.use('/v2', gatedProxy(coreBase(), {}));
}

// --- socket.io handshake gate ------------------------------------------------
// The collector's OWN socket.io — gate the handshake, don't double-proxy. nginx
// also injects a bearer here, but the collector's io has no bearer check, so the
// meaningful reproduction is the auth_request gate. (Flagged in the report.)
function guardSocket(io) {
  if (!enabled()) return;
  io.use((socket, next) => {
    verify(socket.handshake.headers.cookie || '', (err, r) => {
      if (err) return next(new Error('auth backend unreachable'));
      if (!r.ok) return next(new Error('unauthorized'));
      next();
    });
  });
}

// --- static SPA + history fallback (mounted LAST) ----------------------------
function mountStatic(app) {
  if (!enabled()) return;
  const express = require('express');
  const root = dist();
  const indexFile = path.join(root, 'index.html');

  // never cache the service worker; correct manifest MIME (mirrors nginx blocks)
  app.get('/sw.js', (req, res) => { res.set('Cache-Control', 'no-cache'); res.sendFile(path.join(root, 'sw.js')); });
  app.get('/manifest.webmanifest', (req, res) => { res.type('application/manifest+json'); res.sendFile(path.join(root, 'manifest.webmanifest')); });

  app.use(express.static(root, { index: 'index.html' }));

  // SPA history fallback. Only for GETs that are NOT an API/proxy/socket prefix,
  // so a 404 under those prefixes returns a real 404 instead of index.html.
  const RESERVED = ['/api', '/v2', '/manager', '/trust', '/oidc', '/socket.io', '/ingest', '/health', '/version'];
  app.use((req, res, next) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') return next();
    if (RESERVED.some((p) => req.path === p || req.path.startsWith(p + '/'))) return next();
    res.sendFile(indexFile);
  });
}

module.exports = { enabled, mountProxies, guardSocket, mountStatic, verify };
