'use strict';
/**
 * Focused test for the opt-in front door (no test framework — runnable node script).
 *
 *   node frontdoor.test.js
 *
 * Stubs a core /v2/auth/verify (cookie sid=good → 200 + Remote-User: alice) and a
 * manager backend, then drives frontdoor.mountProxies/mountStatic on a bare express
 * app plus a fake collector /api handler (mimics requireToken). Asserts:
 *   (a) gated route, no session          → 401
 *   (b) gated route, valid session       → reaches backend w/ injected Bearer + X-Remote-User
 *   (c) ungated route (/v2/auth/login)   → reachable without a session
 *   (d) static index.html                → served
 *   (e) ASMLTR_DASHBOARD_DIST unset       → front door not mounted; default /api bearer behavior intact
 *   (f) proxied /manager                 → prefix stripped + manager bearer + X-Remote-User injected
 */

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const express = require('express');

let failures = 0;
function check(name, cond, extra) {
  if (cond) { console.log(`  ok   - ${name}`); }
  else { failures++; console.log(`  FAIL - ${name}${extra ? '  (' + extra + ')' : ''}`); }
}

function req(port, method, urlPath, headers) {
  return new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port, method, path: urlPath, headers: headers || {} }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, body, headers: res.headers }));
    });
    r.on('error', reject);
    r.end();
  });
}
function listen(server, port) { return new Promise((res) => server.listen(port, '127.0.0.1', res)); }
function addr(server) { return server.address().port; }

async function main() {
  // --- stub core ---
  const core = http.createServer((rq, rs) => {
    if (rq.url === '/v2/auth/verify') {
      const cookie = rq.headers.cookie || '';
      if (cookie.includes('sid=good')) { rs.setHeader('Remote-User', 'alice'); rs.statusCode = 200; return rs.end(); }
      rs.statusCode = 401; return rs.end('no');
    }
    if (rq.url.startsWith('/v2/auth/login')) { rs.statusCode = 200; return rs.end('login-page'); }
    rs.statusCode = 200; rs.end('core:' + rq.url);
  });
  // --- stub manager backend (records what it received) ---
  const manager = http.createServer((rq, rs) => {
    rs.setHeader('Content-Type', 'application/json');
    rs.end(JSON.stringify({ gotPath: rq.url, auth: rq.headers.authorization || null, ru: rq.headers['x-remote-user'] || null }));
  });
  await listen(core, 0);
  await listen(manager, 0);
  const CORE = `http://127.0.0.1:${addr(core)}`;
  const MANAGER = `http://127.0.0.1:${addr(manager)}`;

  // --- static dist with an index.html ---
  const distDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fd-dist-'));
  fs.writeFileSync(path.join(distDir, 'index.html'), '<!doctype html><title>asmltr SPA</title>SPA-ROOT');

  // Shared env for the ENABLED app.
  process.env.ASMLTR_CORE_BASE = CORE;
  process.env.ASMLTR_MANAGER_BASE = MANAGER;
  process.env.ASMLTR_INSIGHTS_TOKEN = 'ins-tok';
  process.env.ASMLTR_CONTROL_TOKEN = 'ctl-tok';
  process.env.ASMLTR_MANAGER_TOKEN = 'mgr-tok';

  // ---------- ENABLED app ----------
  process.env.ASMLTR_DASHBOARD_DIST = distDir;
  delete require.cache[require.resolve('./frontdoor')];
  const frontdoor = require('./frontdoor');
  check('front door reports enabled when ASMLTR_DASHBOARD_DIST set', frontdoor.enabled() === true);

  const app = express();
  frontdoor.mountProxies(app);
  app.use(express.json({ limit: '5mb' }));
  // Fake collector self-route handler: the REAL requireToken check (Bearer ins-tok),
  // then echo the injected identity — proves the gate injected a bearer that passes.
  app.get('/api/sessions', (rq, rs) => {
    if (rq.headers.authorization !== 'Bearer ins-tok') return rs.status(401).json({ error: 'unauthorized' });
    rs.json({ ok: true, ru: rq.headers['x-remote-user'] || null, auth: rq.headers.authorization });
  });
  frontdoor.mountStatic(app);
  const srv = http.createServer(app);
  await listen(srv, 0);
  const P = addr(srv);

  console.log('\n(a) gated route, no session:');
  let r = await req(P, 'GET', '/api/sessions');
  check('returns 401', r.status === 401, 'got ' + r.status);

  console.log('(b) gated route, valid session:');
  r = await req(P, 'GET', '/api/sessions', { Cookie: 'sid=good' });
  let j = JSON.parse(r.body || '{}');
  check('returns 200', r.status === 200, 'got ' + r.status);
  check('injected Authorization = Bearer ins-tok', j.auth === 'Bearer ins-tok', j.auth);
  check('propagated X-Remote-User = alice', j.ru === 'alice', j.ru);

  console.log('(b2) identity spoof is stripped (client sends X-Remote-User: mallory):');
  r = await req(P, 'GET', '/api/sessions', { Cookie: 'sid=good', 'X-Remote-User': 'mallory' });
  j = JSON.parse(r.body || '{}');
  check('X-Remote-User forced to alice, not mallory', j.ru === 'alice', j.ru);

  console.log('(c) ungated /v2/auth/login, no session:');
  r = await req(P, 'GET', '/v2/auth/login');
  check('reachable (200) without a session', r.status === 200, 'got ' + r.status);
  check('body is the core login page', r.body === 'login-page', r.body);

  console.log('(d) static index.html:');
  r = await req(P, 'GET', '/');
  check('serves SPA index (200)', r.status === 200, 'got ' + r.status);
  check('body contains SPA-ROOT', /SPA-ROOT/.test(r.body));
  console.log('(d2) SPA history fallback for an app route:');
  r = await req(P, 'GET', '/some/deep/spa/route');
  check('unknown GET falls back to index.html', r.status === 200 && /SPA-ROOT/.test(r.body), 'got ' + r.status);

  console.log('(f) proxied /manager (prefix strip + bearer + X-Remote-User):');
  r = await req(P, 'GET', '/manager/instances', { Cookie: 'sid=good' });
  j = JSON.parse(r.body || '{}');
  check('reaches manager with /manager stripped', j.gotPath === '/instances', j.gotPath);
  check('manager bearer injected', j.auth === 'Bearer mgr-tok', j.auth);
  check('X-Remote-User propagated', j.ru === 'alice', j.ru);
  r = await req(P, 'GET', '/manager/instances'); // no session
  check('gated: 401 without a session', r.status === 401, 'got ' + r.status);

  srv.close();

  // ---------- (g) upstream drops the connection MID-BODY ----------
  // A gated route passes auth, the upstream sends headers, then its socket dies
  // mid-body (core restart / TCP reset). Before the pipeline fix, `pres` emitted an
  // unhandled 'error' (no listener, .pipe doesn't forward source errors) that took
  // down the whole collector process. Assert the process survives AND the client gets
  // a clean response/error instead of hanging.
  console.log('\n(g) upstream disconnects mid-body (must NOT crash the process):');
  const broken = http.createServer((rq, rs) => {
    // promise a 1000-byte body, send ~22, then kill the socket → premature close
    rs.writeHead(200, { 'Content-Type': 'text/plain', 'Content-Length': '1000' });
    rs.write('partial-body-then-boom');
    setImmediate(() => { try { rs.socket.destroy(); } catch (_) {} });
  });
  await listen(broken, 0);

  process.env.ASMLTR_MANAGER_BASE = `http://127.0.0.1:${addr(broken)}`;
  delete require.cache[require.resolve('./frontdoor')];
  const fd3 = require('./frontdoor');
  const app3 = express();
  fd3.mountProxies(app3);
  app3.use(express.json());
  const srv3 = http.createServer(app3);
  await listen(srv3, 0);
  const P3 = addr(srv3);

  // Catch any throw the front door would leak. With a listener present an uncaught
  // exception no longer terminates node, so we can observe the pre-fix crash instead
  // of dying on it; with the fix it never fires.
  let crashed = false;
  const onCrash = (e) => { crashed = true; console.error('  would-crash:', e && e.message); };
  process.on('uncaughtException', onCrash);
  process.on('unhandledRejection', onCrash);

  // A mid-body reset surfaces to the http client as an 'aborted'/'close' on the
  // response (status+partial body already delivered), not as an 'end' — so use a
  // client that settles on any terminal event, and race a timeout to catch a hang.
  const reqAny = (port, urlPath, headers) => new Promise((resolve) => {
    const r = http.request({ host: '127.0.0.1', port, method: 'GET', path: urlPath, headers: headers || {} }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      const settle = (kind) => resolve({ kind, status: res.statusCode, body });
      res.on('end', () => settle('end'));
      res.on('aborted', () => settle('aborted'));
      res.on('close', () => settle('close'));
      res.on('error', () => settle('res-error'));
    });
    r.on('error', () => resolve({ kind: 'req-error' }));
    r.end();
  });
  const outcome = await Promise.race([
    reqAny(P3, '/manager/anything', { Cookie: 'sid=good' }),
    new Promise((r) => setTimeout(() => r({ kind: 'timeout' }), 2000)),
  ]);
  check('request did not hang (got a clean response/close, not a timeout)', outcome.kind !== 'timeout', outcome.kind);

  // let any stray async error surface before judging liveness
  await new Promise((r) => setTimeout(r, 50));
  check('collector process stayed up on mid-body reset (no uncaught throw)', crashed === false);

  process.removeListener('uncaughtException', onCrash);
  process.removeListener('unhandledRejection', onCrash);
  srv3.close();
  broken.close();

  // ---------- DISABLED app (zero-regression) ----------
  console.log('\n(e) ASMLTR_DASHBOARD_DIST UNSET — front door not mounted:');
  delete process.env.ASMLTR_DASHBOARD_DIST;
  delete require.cache[require.resolve('./frontdoor')];
  const fd2 = require('./frontdoor');
  check('front door reports disabled', fd2.enabled() === false);

  const app2 = express();
  fd2.mountProxies(app2); // must be a no-op
  app2.use(express.json());
  app2.get('/api/sessions', (rq, rs) => {
    // the collector's default requireToken behavior, verbatim in spirit
    if (rq.headers.authorization !== 'Bearer ins-tok') return rs.status(401).json({ error: 'unauthorized' });
    rs.json({ ok: true });
  });
  fd2.mountStatic(app2); // no-op
  const srv2 = http.createServer(app2);
  await listen(srv2, 0);
  const P2 = addr(srv2);

  r = await req(P2, 'GET', '/api/sessions', { Cookie: 'sid=good' }); // cookie must NOT grant access now
  check('no gate: cookie alone does NOT authorize (401)', r.status === 401, 'got ' + r.status);
  r = await req(P2, 'GET', '/api/sessions', { Authorization: 'Bearer ins-tok' });
  check('default bearer still works (200)', r.status === 200, 'got ' + r.status);
  r = await req(P2, 'GET', '/api/sessions');
  check('no bearer → 401 (unchanged)', r.status === 401, 'got ' + r.status);

  srv2.close();
  core.close();
  manager.close();

  console.log(`\n${failures === 0 ? 'PASS' : 'FAIL'} — ${failures} failure(s)`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
