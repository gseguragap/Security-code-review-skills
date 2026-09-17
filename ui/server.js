#!/usr/bin/env node
/**
 * Security Code Review - local web UI.
 *
 *   node ui/server.js            then open http://127.0.0.1:7099
 *   node ui/server.js --port 8080 --open
 *
 * Node's standard library only. No express, no npm install, nothing in node_modules -
 * the same zero-dependency promise the skills themselves make.
 *
 * This is a local tool for a security product, so it follows the advice the product gives:
 *
 *   - Binds 127.0.0.1 only, never 0.0.0.0. (The audit this repo shipped filed exactly that
 *     as a High finding; it would be poor form to repeat it here.)
 *   - Spawns the CLI with an argv ARRAY and shell:false. User-supplied paths are arguments,
 *     never shell text, so a path containing ; or && or $() is inert. This is the single
 *     most important line of defence in the whole file.
 *   - Rejects cross-origin requests by Host/Origin check, so a page you happen to be
 *     browsing cannot drive this server behind your back.
 *   - Serves generated reports only from inside the run's own output directory, resolved
 *     and prefix-checked, so a crafted filename cannot walk up the tree.
 *   - Sets a restrictive CSP. No inline script, no CDN, no eval.
 */

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn, spawnSync } = require('child_process');
const crypto = require('crypto');

// --------------------------------------------------------------------------- args

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 && process.argv[i + 1] && !process.argv[i + 1].startsWith('--')
    ? process.argv[i + 1] : fallback;
}
const PORT = parseInt(arg('port', '7099'), 10);
const HOST = '127.0.0.1';                      // deliberate - see header
const OPEN = process.argv.includes('--open');
const CLAUDE_BIN = process.env.CLAUDE_BIN || arg('claude', 'claude');
const PUBLIC = path.join(__dirname, 'public');
const SKILL = 'security-code-review';

// --------------------------------------------------------------------------- runs

/** runId -> { child, log[], clients:Set<res>, status, outDir, projectDir, startedAt } */
const runs = new Map();

const MIME = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml', '.ico': 'image/x-icon'
};

// --------------------------------------------------------------------------- helpers

function json(res, code, body) {
  const s = JSON.stringify(body);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(s),
    'Cache-Control': 'no-store'
  });
  res.end(s);
}

const MAX_BODY = 64 * 1024;

function readBody(req) {
  return new Promise((resolve, reject) => {
    let n = 0, done = false;
    const chunks = [];
    req.on('data', c => {
      if (done) return;
      n += c.length;
      if (n > MAX_BODY) {
        // Stop reading, but do NOT destroy the socket - the caller still has to send a
        // 413, and a destroyed socket turns a clear refusal into a connection reset.
        done = true;
        req.pause();
        const err = new Error(`Request body exceeds ${MAX_BODY} bytes.`);
        err.status = 413;
        reject(err);
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      if (done) return;
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')); }
      catch (e) { e.status = 400; reject(e); }
    });
    req.on('error', reject);
  });
}

/** Reject anything that did not originate from this server's own page. */
function sameOrigin(req) {
  const allowed = [`127.0.0.1:${PORT}`, `localhost:${PORT}`];
  const host = req.headers.host || '';
  if (!allowed.includes(host)) return false;
  const origin = req.headers.origin;
  if (origin && !allowed.some(a => origin === `http://${a}`)) return false;
  return true;
}

/** Is `child` inside `parent`? Both are resolved first. Guards the report route. */
function isInside(parent, child) {
  const rel = path.relative(path.resolve(parent), path.resolve(child));
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel);
}

/**
 * Like isInside, but a directory counts as covered by itself. isInside deliberately says
 * no to that case - it guards the report route, where a path equal to the directory is not
 * a file inside it - so the two cannot share one predicate.
 */
function isSameOrInside(parent, child) {
  const rel = path.relative(path.resolve(parent), path.resolve(child));
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

/**
 * The path as the filesystem itself spells it: 8.3 short names expanded, symlinks followed.
 * This matters more than it looks on Windows. The CLI's path guard treats a short name such
 * as C:UsersGILBER~1... as a suspicious pattern and refuses to read through it, so a
 * path pasted out of an older tool - which is where 8.3 names still come from - would pass
 * validation here, be granted with --add-dir, and then have every single read denied with
 * nothing in the log to explain it. Canonicalising once, at the edge, keeps the path we show
 * the user, the path we grant, and the path the skill resolves the same string.
 */
function canonicalDir(abs) {
  try { return fs.realpathSync.native(abs); } catch { return abs; }
}

/**
 * The permission rule that makes one directory writable, and only that directory.
 *
 * Three details here are load-bearing, and each was found by watching a run fail:
 *   - **Edit, not Write.** Only Edit rules are consulted by the file permission check. A
 *     rule named after the Write tool matches nothing; the CLI mentions it on stderr and
 *     then denies every write, which is a confusing way to learn this.
 *   - **Forward slashes.** A rule spelled with Windows backslashes never matches.
 *   - **No leading //.** The absolute form this matcher accepts is the bare path.
 *
 * Edit rules cover every file-editing tool, and shell redirection into the directory works
 * too, so this one rule is the whole write grant.
 */
function writeRule(dir) {
  return `Edit(${dir.split('\\').join('/')}/**)`;
}

// --------------------------------------------------------------------------- inspect

const SKIP_DIRS = new Set(['node_modules', 'bin', 'obj', 'dist', 'build', 'out', 'target',
  'vendor', '.git', 'packages', '__pycache__', '.venv', 'venv', '.vs', '.idea']);

/** Walk a tree, counting files by extension. Bounded so a huge tree cannot hang the UI. */
function inspect(dir, limit = 20000) {
  const byExt = Object.create(null);
  let files = 0, skipped = 0, truncated = false;
  const stack = [dir];
  while (stack.length) {
    if (files + skipped > limit) { truncated = true; break; }
    let entries;
    try { entries = fs.readdirSync(stack.pop(), { withFileTypes: true }); }
    catch { continue; }
    for (const e of entries) {
      const full = path.join(e.parentPath || e.path || dir, e.name);
      if (e.isDirectory()) {
        if (SKIP_DIRS.has(e.name)) { skipped++; continue; }
        stack.push(full);
      } else if (e.isFile()) {
        files++;
        const ext = (path.extname(e.name) || '(none)').toLowerCase();
        byExt[ext] = (byExt[ext] || 0) + 1;
      }
    }
  }
  return { files, skipped, truncated, byExt };
}

/** Cheap stack guess, mirroring the rule packs' detect globs. Display only. */
function detectStack(byExt) {
  const has = (...e) => e.some(x => byExt[x]);
  const out = [];
  if (has('.cs', '.razor', '.cshtml', '.csproj')) out.push('.NET / C#');
  if (has('.4gl', '.per', '.frm')) out.push('Informix 4GL');
  if (has('.cbl', '.cob')) out.push('COBOL');
  if (has('.java', '.kt')) out.push('Java / Kotlin');
  if (has('.ts', '.tsx')) out.push('TypeScript');
  else if (has('.js', '.jsx')) out.push('JavaScript');
  if (has('.py')) out.push('Python');
  if (has('.php')) out.push('PHP');
  if (has('.go')) out.push('Go');
  if (has('.rb')) out.push('Ruby');
  if (has('.sql', '.pks', '.pkb')) out.push('SQL');
  if (has('.vbp', '.bas')) out.push('VB6');
  if (has('.dpr', '.pas')) out.push('Delphi');
  return out.length ? out.join(', ') : 'not recognised';
}

function validatePath(p, { required }) {
  if (!p || !p.trim()) {
    return required
      ? { ok: false, level: 'error', message: 'Required.' }
      : { ok: true, level: 'skip', message: 'Not provided - this phase will be skipped.' };
  }
  const abs = canonicalDir(path.resolve(p.trim()));
  let st;
  try { st = fs.statSync(abs); }
  catch { return { ok: false, level: 'error', message: 'Path does not exist.', abs }; }
  if (!st.isDirectory()) return { ok: false, level: 'error', message: 'Not a directory.', abs };
  const info = inspect(abs);
  if (info.files === 0) {
    return { ok: false, level: 'error', message: 'Directory contains no files.', abs };
  }
  return {
    ok: true, level: 'ok', abs, files: info.files, truncated: info.truncated,
    stack: detectStack(info.byExt),
    message: `${info.files.toLocaleString()}${info.truncated ? '+' : ''} files - ${detectStack(info.byExt)}`
  };
}

// --------------------------------------------------------------------------- preflight

/**
 * On Windows a .cmd/.bat shim cannot be spawned with shell:false, and spawning it WITH a
 * shell reopens the argument-escaping hole this server exists to avoid (the BatBadBut
 * class of bugs). So we refuse those outright and say what to point at instead, rather
 * than quietly turning the shell back on. npm-installed CLIs commonly look like this.
 */
function batchShimProblem(bin) {
  if (process.platform !== 'win32') return null;
  if (!/\.(cmd|bat)$/i.test(bin)) return null;
  const exe = bin.replace(/\.(cmd|bat)$/i, '.exe');
  return `"${path.basename(bin)}" is a Windows batch shim. This server will not run it through ` +
         `a shell, because that would reintroduce the argument-escaping risk it is built to avoid. ` +
         `Point CLAUDE_BIN at the real executable instead` +
         (fs.existsSync(exe) ? ` - "${exe}" is right there.` : ' (usually claude.exe).');
}

/**
 * Where the skills are installed. The audit does not only think - it runs the skill's own
 * bin/ collectors and cats its assets/ templates to render the report, and those live in
 * the skills folder, not in the output folder. Outside the workspace they are unreadable,
 * so the audit would analyse fine and then fail at the last step with the findings already
 * paid for. Granted read-only: writes are confined to the output folder regardless.
 */
function skillRoots() {
  const roots = [
    path.join(os.homedir(), '.claude', 'skills'),
    path.join(process.cwd(), '.claude', 'skills')
  ];
  return roots.filter(r => fs.existsSync(path.join(r, SKILL, 'SKILL.md')))
              .map(r => canonicalDir(r));
}

function preflight() {
  const where = [];
  const userSkill = path.join(os.homedir(), '.claude', 'skills', SKILL, 'SKILL.md');
  if (fs.existsSync(userSkill)) where.push(userSkill);
  const projSkill = path.join(process.cwd(), '.claude', 'skills', SKILL, 'SKILL.md');
  if (fs.existsSync(projSkill)) where.push(projSkill);

  let cli = null;
  try {
    const r = spawnSync(CLAUDE_BIN, ['--version'], { encoding: 'utf8', timeout: 15000, shell: false });
    if (r.status === 0) cli = (r.stdout || '').trim().split('\n')[0];
  } catch { /* not found */ }

  return {
    skillInstalled: where.length > 0,
    skillPaths: where,
    cli,
    cliBin: CLAUDE_BIN,
    cliWarning: batchShimProblem(CLAUDE_BIN),
    cwd: process.cwd(),
    node: process.version
  };
}

// --------------------------------------------------------------------------- run

function broadcast(run, event, data) {
  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of run.clients) { try { res.write(payload); } catch { /* gone */ } }
}

function pushLine(run, line, stream) {
  const entry = { t: Date.now(), stream, line };
  run.log.push(entry);
  if (run.log.length > 5000) run.log.shift();
  broadcast(run, 'line', entry);

  // Coarse phase tracking, purely for the progress strip. Derived from the skill's own
  // announcements; if the wording drifts the log still shows everything.
  const l = line.toLowerCase();
  const set = (k, v) => { if (run.phases[k] !== 'done') { run.phases[k] = v; broadcast(run, 'phases', run.phases); } };
  if (/phase a|legacy audit/.test(l)) set('legacy', 'running');
  if (/phase b|modernized audit/.test(l)) { run.phases.legacy = run.phases.legacy === 'running' ? 'done' : run.phases.legacy; set('modernized', 'running'); }
  if (/phase c|comparison/.test(l)) { run.phases.modernized = run.phases.modernized === 'running' ? 'done' : run.phases.modernized; set('comparison', 'running'); }
}

function findReports(dir) {
  try {
    return fs.readdirSync(dir)
      .filter(f => f.toLowerCase().endsWith('.html'))
      .map(f => {
        const m = /- (Legacy|Modernized|Comparison) -/i.exec(f);
        return { file: f, kind: m ? m[1] : 'Report', size: fs.statSync(path.join(dir, f)).size };
      })
      .sort((a, b) => ['Legacy', 'Modernized', 'Comparison']
        .indexOf(a.kind) - ['Legacy', 'Modernized', 'Comparison'].indexOf(b.kind));
  } catch { return []; }
}

const oneLine = (v, max = 160) => {
  const t = String(v).replace(/\s+/g, ' ').trim();
  return t.length > max ? t.slice(0, max - 3) + '...' : t;
};

/** The most telling field of a tool call, for a one-line progress entry. */
function toolSummary(input) {
  if (!input || typeof input !== 'object') return '';
  for (const k of ['command', 'pattern', 'file_path', 'path', 'url', 'description', 'prompt']) {
    if (typeof input[k] === 'string' && input[k].trim()) return oneLine(input[k]);
  }
  return '';
}

// --------------------------------------------------------------------------- cost

/**
 * List rates, loaded once, from the same assets/pricing.json the audit itself prices with.
 *
 * Deliberately not a table in this file. The skill's report is the authoritative cost
 * figure; a second table here would drift from it, and two dollar amounts that disagree in
 * front of a user damage the one number that was actually measured.
 */
const PRICING = (() => {
  const candidates = [
    ...skillRoots().map(r => path.join(r, 'security-audit', 'assets', 'pricing.json')),
    path.join(__dirname, '..', 'security-audit', 'assets', 'pricing.json')
  ];
  for (const f of candidates) {
    try {
      const doc = JSON.parse(fs.readFileSync(f, 'utf8'));
      if (doc && doc.models) return { models: doc.models, version: doc.pricingVersion || 'unknown' };
    } catch { /* try the next one */ }
  }
  return { models: {}, version: 'unknown' };
})();

/**
 * Record one assistant message's token usage.
 *
 * Keyed by message id, keeping the MAXIMUM seen per field, because the CLI emits the same
 * message several times as it streams. Summing every event overstates the bill by 2-3x.
 * This mirrors bin/cost.py, which does the same thing to the transcript for the report.
 */
function recordUsage(run, msg) {
  const u = msg && msg.usage;
  if (!u || !msg.id) return;

  const cc = u.cache_creation || {};
  const seen = {
    model: msg.model || 'unknown',
    input: u.input_tokens || 0,
    output: u.output_tokens || 0,
    read: u.cache_read_input_tokens || 0,
    w5: cc.ephemeral_5m_input_tokens || 0,
    w1: cc.ephemeral_1h_input_tokens || 0,
    cc: u.cache_creation_input_tokens || 0
  };
  // No per-TTL breakdown: attribute cache writes to the 5-minute rate, the cheaper of the
  // two. Understating is the honest way to err. Same rule as bin/cost.py.
  if (!seen.w5 && !seen.w1 && seen.cc) seen.w5 = seen.cc;
  if (!(seen.input + seen.output + seen.read + seen.w5 + seen.w1)) return; // synthetic

  const prev = run.usage.get(msg.id);
  if (!prev) return void run.usage.set(msg.id, seen);
  for (const k of ['input', 'output', 'read', 'w5', 'w1', 'cc']) {
    if (seen[k] > prev[k]) prev[k] = seen[k];
  }
}

/**
 * Aggregate recorded usage into a running total.
 *
 * A model absent from pricing.json contributes its TOKENS but no dollars, and is named in
 * `unpriced` so the strip can say the figure is partial. Inventing a rate would be worse
 * than showing none - the same policy the pricing file states for the report.
 */
function costSnapshot(run) {
  const byModel = new Map();
  for (const m of run.usage.values()) {
    const a = byModel.get(m.model) || { input: 0, output: 0, read: 0, w5: 0, w1: 0 };
    for (const k of ['input', 'output', 'read', 'w5', 'w1']) a[k] += m[k];
    byModel.set(m.model, a);
  }

  let usd = 0, tokens = 0, priced = true;
  const unpriced = [];
  for (const [model, a] of byModel) {
    tokens += a.input + a.output + a.read + a.w5 + a.w1;
    const r = PRICING.models[model];
    if (!r) { priced = false; unpriced.push(model); continue; }
    usd += (a.input * r.input + a.output * r.output + a.read * r.cacheRead
            + a.w5 * r.cacheWrite5m + a.w1 * r.cacheWrite1h) / 1e6;
  }

  return {
    tokens, messages: run.usage.size,
    usd: run.costUsd != null ? run.costUsd : (byModel.size ? usd : null),
    measured: run.costUsd != null,
    partial: !priced, unpriced,
    pricingVersion: PRICING.version
  };
}

/**
 * Describe what is being generated right now, for the activity line.
 *
 * The point is a number that MOVES. "writing..." alone is indistinguishable from a hang;
 * "writing... 8.1K chars" climbing every second is proof the model is still producing.
 */
function describeGen(g) {
  const size = g.chars >= 1000 ? (g.chars / 1000).toFixed(1) + 'K' : String(g.chars);
  if (g.kind === 'thinking') return `thinking… ${size} chars`;
  if (g.kind === 'text') return `writing… ${size} chars`;
  return `preparing ${g.kind}… ${size} chars`;
}

// A pulse for the client's stall detector, carrying the generation label when there is one.
// Throttled hard: partial messages arrive many times a second and the strip only needs to
// move about once.
function broadcastAlive(run) {
  const now = Date.now();
  if (now - (run.aliveSentAt || 0) < 1000) return;
  run.aliveSentAt = now;
  broadcast(run, 'alive', { label: run.gen ? describeGen(run.gen) : null });
}

// Throttled: usage lands on every assistant message and the strip does not need to move
// more than a couple of times a second.
function broadcastCost(run, force) {
  const now = Date.now();
  if (!force && now - (run.costSentAt || 0) < 2000) return;
  run.costSentAt = now;
  broadcast(run, 'cost', costSnapshot(run));
}

/**
 * Render one stream-json event into log lines.
 *
 * The CLI's default text output prints nothing whatsoever until the run ends. For a
 * three-phase audit that is twenty-odd silent minutes, and from a browser it is
 * indistinguishable from a hung process: the log stays empty and the phase strip sits on
 * "queued" while the audit is in fact working perfectly. stream-json emits an event per
 * step instead, so the log fills as the work happens - which is the whole reason this
 * server streams at all.
 *
 * The price of that choice is that the server has to render those events itself. This is
 * that renderer, and it is deliberately terse: the job is to show progress, not to
 * reproduce a terminal.
 */
function emitEvent(run, line) {
  if (!line.trim()) return;
  let e;
  try { e = JSON.parse(line); } catch { return pushLine(run, line, 'out'); }

  switch (e.type) {
    case 'system':
      if (e.subtype === 'init') pushLine(run, `Session started - model ${e.model || 'default'}`, 'out');
      return;

    // Deltas from --include-partial-messages. Deliberately never logged: this is a token
    // stream, and reproducing a terminal is not the job. They are counted instead, so the
    // activity line can show a size that climbs while one long message is being produced.
    case 'stream_event': {
      const ev = e.event || {};
      if (ev.type === 'content_block_start') {
        const cb = ev.content_block || {};
        run.gen = { kind: cb.type === 'tool_use' ? (cb.name || 'tool') : cb.type, chars: 0 };
      } else if (ev.type === 'content_block_delta') {
        const d = ev.delta || {};
        const text = d.text || d.partial_json || d.thinking || '';
        if (!run.gen) run.gen = { kind: d.type === 'thinking_delta' ? 'thinking' : 'text', chars: 0 };
        run.gen.chars += text.length;
      } else if (ev.type === 'content_block_stop' || ev.type === 'message_stop') {
        run.gen = null;
      }
      broadcastAlive(run);
      return;
    }

    // Quota telemetry, emitted every turn. Worth a line only when it is not "allowed" - at
    // which point it is the most useful line in the log.
    case 'rate_limit_event': {
      const st = e.rate_limit_info && e.rate_limit_info.status;
      if (st && st !== 'allowed') pushLine(run, `Rate limit: ${st}`, 'err');
      return;
    }

    case 'assistant': {
      recordUsage(run, e.message);
      broadcastCost(run, false);
      for (const b of (e.message && e.message.content) || []) {
        if (b.type === 'text' && b.text) {
          for (const l of b.text.split(/\r?\n/)) if (l.trim()) pushLine(run, l, 'out');
        } else if (b.type === 'tool_use') {
          const arg = toolSummary(b.input);
          pushLine(run, `  ${b.name}${arg ? ' - ' + arg : ''}`, 'tool');
        }
      }
      return;
    }

    // Tool results are the bulk of the stream and nearly all of it is file content nobody
    // wants to read. Failures are the exception - those are why a run goes wrong.
    case 'user': {
      for (const b of (e.message && e.message.content) || []) {
        if (b.type === 'tool_result' && b.is_error) {
          const t = Array.isArray(b.content) ? b.content.map(c => c.text || '').join(' ') : (b.content || '');
          pushLine(run, `  failed: ${oneLine(t, 300)}`, 'err');
        }
      }
      return;
    }

    case 'result':
      // The CLI's own figure, which supersedes the running estimate: it covers subagent
      // turns this stream never showed and needs no pricing table of ours.
      if (typeof e.total_cost_usd === 'number') run.costUsd = e.total_cost_usd;
      broadcastCost(run, true);
      pushLine(run, e.subtype === 'success' ? 'Run finished.' : `Run ended: ${e.subtype || 'unknown'}`,
               e.subtype === 'success' ? 'out' : 'err');
      return;

    // An event type this renderer does not know is still proof the CLI is alive. Silently
    // dropping it - the previous behaviour - let a perfectly healthy stream read as dead.
    default:
      broadcastAlive(run);
      return;
  }
}

function startRun(cfg) {
  const runId = crypto.randomBytes(8).toString('hex');
  // The output folder is this run's working directory, and Node reports a missing cwd as
  // ENOENT *naming the executable* - so a folder that does not exist yet surfaces as
  // `Failed to start "...claude.exe": ENOENT`, an error that accuses the one component
  // that is working. Create it before spawning; the run is about to write reports here
  // anyway, and the write grant already names it.
  //
  // Order matters: canonicalDir resolves through realpath, which only works on a path that
  // already exists. Canonicalising first would silently hand back the raw string - and if
  // that string is an 8.3 short name (C:\Users\GILBER~1\...), the CLI's path guard rejects
  // it and denies every read, which looks exactly like an empty folder.
  const outDirRaw = path.resolve(cfg.outDir);
  fs.mkdirSync(outDirRaw, { recursive: true });
  const outDir = canonicalDir(outDirRaw);
  const projectDir = path.join(outDir, cfg.projectName.replace(/[\\/:*?"<>|]/g, '').trim());

  // Resolved once, here, and used for all three things that have to agree: the grant
  // below, the prompt text the skill resolves, and the line the user reads in the log.
  const legacyDir = cfg.legacyPath && cfg.legacyPath.trim()
    ? canonicalDir(path.resolve(cfg.legacyPath.trim())) : null;
  const modernizedDir = canonicalDir(path.resolve(cfg.modernizedPath.trim()));

  // The CLI's working directory is outDir, so both source trees sit outside the workspace
  // and the skill cannot read a single file in either of them by default - every Read and
  // Glob comes back denied, and an audit of nothing scores suspiciously well. Whatever the
  // user put in the Legacy and Modernized fields is granted here, and nothing else is: the
  // trusted set is derived from the form on every run, never a list of folders pinned in
  // this file. The skill's own folder joins them because the audit does not only think: it
  // runs bin/ collectors and cats assets/ templates from there to render the report, and
  // unreadable templates fail at the very last step, with the analysis already paid for.
  // outDir is granted separately below, so anything already inside it is dropped here.
  const trustedDirs = [];
  for (const d of [legacyDir, modernizedDir, ...skillRoots()]) {
    if (!d) continue;
    if (isSameOrInside(outDir, d)) continue;
    if (trustedDirs.some(t => isSameOrInside(t, d))) continue;
    trustedDirs.push(d);
  }

  // Quote a value for the prompt text. NOT shell quoting - the prompt is read by the
  // skill, never by a shell. JSON.stringify is wrong here because it escapes backslashes,
  // turning C:\src into C:\\src in the text the skill has to resolve. Windows forbids " in
  // a path, so wrapping in double quotes and escaping any embedded " is sufficient.
  const q = s => `"${String(s).replace(/"/g, '\\"')}"`;

  // Built in final order. An earlier version spliced --legacy in at index 2 and split
  // --name from its value, producing `--name --legacy "path" "Project"`; build the array
  // in order instead, so there is no index arithmetic to get wrong.
  const promptParts = [`/${SKILL}`, '--name', q(cfg.projectName)];
  if (legacyDir) {
    promptParts.push('--legacy', q(legacyDir));
  }
  promptParts.push(
    '--modernized', q(modernizedDir),
    '--out', q(outDir),
    '--depth', cfg.depth,
    '--yes'
  );

  const prompt = promptParts.join(' ');

  // The argv ARRAY. Nothing here is ever handed to a shell, so a path such as
  // C:\x & calc.exe is just an odd directory name, not a command. --add-dir is
  // variadic - it swallows bare words until the next flag - so each directory carries its
  // own --add-dir and no path can be absorbed into its neighbour's list; -p goes last,
  // closing the run of flags. A directory name cannot pose as a flag either: these have
  // been through path.resolve, so they begin with a drive letter or a slash, never a dash.
  const args = [];
  for (const d of trustedDirs) args.push('--add-dir', d);

  // --add-dir grants reading. Writing is a separate decision, and the default is no: a
  // spawned run reads the whole codebase, scores it, and then cannot save one byte of it.
  // That is the failure this grant exists to prevent, so the output folder gets it every
  // time, without being asked for - there is nobody on the other end to ask.
  //
  // The rule names the output folder outright rather than relying on it being the working
  // directory, so the same string works from any cwd - which is what lets the Copy CLI
  // command button hand you a command that behaves exactly like the run you just watched.
  // What it confines is the file tools - Write, Edit and friends - which cannot touch the
  // source trees or the skill's own folder. It does NOT confine the shell: see the Bash
  // grant below for where that boundary actually ends.
  args.push('--add-dir', outDir);

  // Bash and PowerShell are here because the audit is not only a model reading files: it
  // runs this skill's own bin/ cost collectors and concatenates its assets/ templates into
  // the finished HTML. Denied, the run analyses the whole codebase and then renders
  // nothing - which is exactly what happened the first time, invisibly, because the UI was
  // not streaming yet.
  //
  // Be clear-eyed about the cost of that. A shell can write wherever the OS allows, so
  // granting Bash ends the enforced write boundary: Edit(<out>/**) still confines the file
  // tools, but `echo x >> src/thing.4gl` is not a file tool. Tested, and it goes through.
  //
  // So the source trees are protected by the skill's own read-only contract rather than by
  // the sandbox - the audit describes remediation, never applies it - and that is a weaker
  // guarantee, worth knowing when pointing this at a tree you cannot restore. The narrower
  // alternative, an allowlist of specific commands, was tried and rejected: the skill
  // composes multi-command shell lines, prefix rules miss them, and each miss is a run that
  // dies twenty minutes in. Runs that fail silently were the bug being fixed here.
  args.push('--allowedTools', writeRule(outDir), 'Bash', 'PowerShell');

  // Nothing here can answer a permission prompt - there is no terminal and no host on the
  // other end. Saying so turns a question that would otherwise stall the run into an
  // immediate, logged denial, which is a failure you can read rather than one you wait out.
  args.push('--permission-prompts', 'none');

  // Without this the CLI buffers the entire run and prints one block at the end - see
  // emitEvent for why that is worse than it sounds. --verbose is what makes print mode
  // emit the per-step events rather than only the final result.
  args.push('--output-format', 'stream-json', '--verbose');

  // An `assistant` event is only emitted when its message is COMPLETE. The audit's longest
  // steps are single enormous messages - "writing the legacy findings document" was
  // measured at 178 seconds - and for that whole stretch the stream says nothing at all.
  // The log stops, the spinner has no events to run on, and a run that is working perfectly
  // is indistinguishable from a hung one.
  //
  // Partial messages fix that at the source: the CLI emits content_block deltas as the
  // message is generated, so there is a pulse every few hundred milliseconds even mid-
  // document. They are never logged - see the stream_event case in emitEvent, which counts
  // them and reports "writing... 8.1K chars" rather than printing a token stream.
  args.push('--include-partial-messages');

  args.push('-p', prompt);

  const child = spawn(CLAUDE_BIN, args, {
    cwd: outDir,
    shell: false,                    // never a shell - see header
    windowsHide: true,
    // stdin closed, not inherited: the CLI waits ~3s for piped input otherwise and logs
    // "no stdin data received in 3s". There is nothing to send it - the prompt is in argv.
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env }
  });

  const run = {
    child, log: [], clients: new Set(), status: 'running',
    outDir, projectDir, reports: [], exitCode: null,
    startedAt: Date.now(), finishedAt: null,
    usage: new Map(), costUsd: null, costSentAt: 0,
    gen: null, aliveSentAt: 0,
    phases: { legacy: legacyDir ? 'queued' : 'skipped', modernized: 'queued', comparison: 'queued' },
    trustedDirs,
    cmdPreview: `${CLAUDE_BIN} ${args.map(a => (/\s/.test(a) ? `'${a}'` : a)).join(' ')}`
  };
  runs.set(runId, run);

  // Say what was granted, in the log the user is already watching. Access is not something
  // to hand out silently, and when a path is wrong this is the fastest way to see it. Read
  // and write are stated separately because they are different promises: exactly one
  // directory on this list can be written to.
  for (const d of trustedDirs) pushLine(run, `Granted read access to ${d}`, 'out');
  pushLine(run, `Granted write access to ${outDir} (reports and .security-audit/ only)`, 'out');

  // stdout is one JSON event per line and goes through the renderer; stderr is plain text
  // from the CLI itself and is passed straight through.
  const wire = (stream, handle) => {
    let buf = '';
    stream.setEncoding('utf8');
    stream.on('data', chunk => {
      buf += chunk;
      const lines = buf.split(/\r?\n/);
      buf = lines.pop();
      for (const l of lines) handle(l);
    });
    stream.on('end', () => { if (buf) handle(buf); });
  };
  wire(child.stdout, l => emitEvent(run, l));
  wire(child.stderr, l => { if (l.trim()) pushLine(run, l, 'err'); });

  child.on('error', err => {
    // ENOENT here has two quite different causes and Node words both of them as though the
    // executable were missing: the binary really is absent, or the spawn cwd does not
    // exist. Say which, and check the cheap one rather than guessing.
    pushLine(run, `Failed to start "${CLAUDE_BIN}": ${err.message}`, 'err');
    if (err.code === 'ENOENT') {
      if (!fs.existsSync(CLAUDE_BIN)) {
        pushLine(run, `The CLI was not found at that path. Set CLAUDE_BIN to the real claude executable.`, 'err');
      } else if (!fs.existsSync(outDir)) {
        pushLine(run, `The CLI exists - it is the working directory ${outDir} that does not. ` +
                      `ENOENT from spawn names the executable even when the cwd is the missing part.`, 'err');
      } else {
        pushLine(run, `Both the CLI and ${outDir} exist; the executable may be blocked by policy or antivirus.`, 'err');
      }
    }
    run.status = 'failed';
    run.finishedAt = Date.now();
    broadcast(run, 'done', { status: run.status, exitCode: null, reports: [] });
  });

  child.on('close', code => {
    run.exitCode = code;
    run.status = code === 0 ? 'done' : 'failed';
    run.finishedAt = Date.now();
    run.reports = findReports(run.projectDir);

    // Settle the phase strip against the ARTIFACTS, not against the exit code. An earlier
    // version marked every queued phase "done" whenever the process exited 0, which once
    // showed three green phases for a run that produced nothing at all. A phase is done
    // only if its report is on disk.
    const produced = new Set(run.reports.map(r => r.kind));
    const kindOf = { legacy: 'Legacy', modernized: 'Modernized', comparison: 'Comparison' };
    for (const k of Object.keys(run.phases)) {
      if (run.phases[k] === 'skipped') continue;
      if (produced.has(kindOf[k])) run.phases[k] = 'done';
      else if (run.phases[k] === 'running') run.phases[k] = 'failed';
      else run.phases[k] = code === 0 ? 'not run' : 'failed';
    }
    broadcast(run, 'phases', run.phases);
    broadcastCost(run, true);
    broadcast(run, 'done', {
      status: run.status, exitCode: code,
      reports: run.reports, projectDir: run.projectDir,
      cost: costSnapshot(run),
      seconds: Math.round((run.finishedAt - run.startedAt) / 1000)
    });
  });

  return { runId, run };
}

// --------------------------------------------------------------------------- static

function serveStatic(req, res, urlPath) {
  const rel = urlPath === '/' ? 'index.html' : decodeURIComponent(urlPath).replace(/^\/+/, '');
  const file = path.join(PUBLIC, rel);
  if (!isInside(PUBLIC, file) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    return res.end('Not found');
  }
  const body = fs.readFileSync(file);
  res.writeHead(200, {
    'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy':
      "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; " +
      "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
  });
  res.end(body);
}

// --------------------------------------------------------------------------- server

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || HOST}`);
  const p = url.pathname;

  if (!sameOrigin(req)) { res.writeHead(403); return res.end('Forbidden'); }

  try {
    // ---- API
    if (p === '/api/preflight' && req.method === 'GET') {
      return json(res, 200, preflight());
    }

    if (p === '/api/validate' && req.method === 'POST') {
      const b = await readBody(req);
      const legacy = validatePath(b.legacyPath, { required: false });
      const modern = validatePath(b.modernizedPath, { required: true });
      const name = (b.projectName || '').trim();
      const cleaned = name.replace(/[\\/:*?"<>|]/g, '').trim();
      const outDir = (b.outDir || '').trim() || process.cwd();

      let same = false;
      if (legacy.abs && modern.abs) same = path.resolve(legacy.abs) === path.resolve(modern.abs);

      let outState = { ok: true, level: 'ok', abs: path.resolve(outDir) };
      try {
        const absOut = path.resolve(outDir);
        // The folder itself need not exist - the run creates it. Its PARENT not existing is
        // almost always a typo, and saying so here is the difference between a corrected
        // field and a run that dies at spawn with an error blaming the CLI.
        if (!fs.existsSync(absOut)) {
          const parent = path.dirname(absOut);
          outState = fs.existsSync(parent)
            ? { ok: true, level: 'warn', abs: absOut, message: 'Does not exist yet - it will be created.' }
            : { ok: false, level: 'error', abs: absOut,
                message: `Neither this folder nor its parent (${parent}) exists - check the path.` };
        }
        const target = path.join(path.resolve(outDir), cleaned || '_');
        if (outState.ok && fs.existsSync(target)) {
          outState = {
            ok: true, level: 'warn', abs: path.resolve(outDir),
            message: `${path.basename(target)}\\ already exists - a previous run's reports may be overwritten.`
          };
        }
      } catch { /* ignore */ }

      return json(res, 200, {
        projectName: {
          ok: cleaned.length > 0,
          level: cleaned.length === 0 ? 'error' : (cleaned !== name ? 'warn' : 'ok'),
          cleaned,
          message: cleaned.length === 0 ? 'Required.'
            : cleaned !== name ? `Illegal filename characters removed - folder will be "${cleaned}".` : ''
        },
        legacy, modernized: modern, outDir: outState, samePath: same,
        skillDirs: skillRoots(),
        writeRule: writeRule(path.resolve(outDir)),
        canRun: cleaned.length > 0 && modern.ok && legacy.ok && outState.ok && !same
      });
    }

    if (p === '/api/run' && req.method === 'POST') {
      const b = await readBody(req);
      const modern = validatePath(b.modernizedPath, { required: true });
      const legacy = validatePath(b.legacyPath, { required: false });
      const cleaned = (b.projectName || '').replace(/[\\/:*?"<>|]/g, '').trim();
      if (!cleaned || !modern.ok || !legacy.ok) {
        return json(res, 400, { error: 'Inputs did not validate. Re-check the form.' });
      }
      const pre = preflight();
      if (pre.cliWarning) return json(res, 400, { error: pre.cliWarning });
      if (!pre.cli) {
        return json(res, 400, {
          error: `The Claude Code CLI was not found (tried "${CLAUDE_BIN}"). ` +
                 `Put it on PATH, or start this server with CLAUDE_BIN=<full path> node ui/server.js.`
        });
      }
      let started;
      try {
        started = startRun({
          projectName: cleaned,
          legacyPath: (b.legacyPath || '').trim(),
          modernizedPath: (b.modernizedPath || '').trim(),
          outDir: (b.outDir || '').trim() || process.cwd(),
          depth: ['quick', 'standard', 'deep'].includes(b.depth) ? b.depth : 'standard'
        });
      } catch (e) {
        // Almost always the output folder: unwritable, or a path Windows will not accept.
        // Reported here, before a run exists, rather than as a dead run in the log.
        return json(res, 400, {
          error: `Could not prepare the output folder "${(b.outDir || '').trim() || process.cwd()}": ${e.message}`
        });
      }
      const { runId, run } = started;
      return json(res, 200, {
        runId, cmdPreview: run.cmdPreview, projectDir: run.projectDir,
        trustedDirs: run.trustedDirs
      });
    }

    if (p === '/api/events' && req.method === 'GET') {
      const run = runs.get(url.searchParams.get('run'));
      if (!run) { res.writeHead(404); return res.end('no such run'); }
      res.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-store',
        Connection: 'keep-alive',
        'X-Accel-Buffering': 'no'
      });
      res.write('retry: 2000\n\n');
      for (const e of run.log) res.write(`event: line\ndata: ${JSON.stringify(e)}\n\n`);
      res.write(`event: phases\ndata: ${JSON.stringify(run.phases)}\n\n`);
      res.write(`event: cost\ndata: ${JSON.stringify(costSnapshot(run))}\n\n`);
      if (run.status !== 'running') {
        res.write(`event: done\ndata: ${JSON.stringify({
          status: run.status, exitCode: run.exitCode, reports: run.reports,
          projectDir: run.projectDir, cost: costSnapshot(run),
          seconds: Math.round(((run.finishedAt || Date.now()) - run.startedAt) / 1000)
        })}\n\n`);
      }
      run.clients.add(res);
      const ka = setInterval(() => { try { res.write(': ping\n\n'); } catch { /* gone */ } }, 15000);
      req.on('close', () => { clearInterval(ka); run.clients.delete(res); });
      return;
    }

    if (p === '/api/cancel' && req.method === 'POST') {
      const b = await readBody(req);
      const run = runs.get(b.runId);
      if (!run) return json(res, 404, { error: 'no such run' });
      if (run.status === 'running') {
        run.child.kill('SIGTERM');
        pushLine(run, '-- cancelled by user --', 'err');
      }
      return json(res, 200, { ok: true });
    }

    // ---- generated report, confined to this run's project folder
    if (p === '/report' && req.method === 'GET') {
      const run = runs.get(url.searchParams.get('run'));
      const file = url.searchParams.get('f') || '';
      if (!run) { res.writeHead(404); return res.end('no such run'); }
      const target = path.join(run.projectDir, path.basename(file));   // basename defeats traversal
      if (!isInside(run.projectDir, target) || !fs.existsSync(target)) {
        res.writeHead(404); return res.end('no such report');
      }
      const body = fs.readFileSync(target);
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Length': body.length,
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff'
      });
      return res.end(body);
    }

    // ---- static
    if (req.method === 'GET') return serveStatic(req, res, p);

    res.writeHead(405); res.end('Method not allowed');
  } catch (err) {
    if (!res.headersSent) json(res, err.status || 400, { error: err.message });
    req.resume();                       // drain whatever the client is still sending
  }
});

server.listen(PORT, HOST, () => {
  const url = `http://${HOST}:${PORT}`;
  const pre = preflight();
  console.log('');
  console.log('  Security Code Review - local UI');
  console.log(`  ${url}`);
  console.log('');
  console.log(`  node        ${pre.node}`);
  console.log(`  claude CLI  ${pre.cli || `NOT FOUND (tried "${pre.cliBin}")`}`);
  console.log(`  skill       ${pre.skillInstalled ? pre.skillPaths[0] : `NOT INSTALLED - run install.ps1 / install.sh`}`);
  console.log(`  cwd         ${pre.cwd}`);
  console.log('');
  console.log('  Bound to loopback only. Ctrl+C to stop.');
  console.log('');
  if (OPEN) {
    const cmd = process.platform === 'win32' ? 'explorer'
      : process.platform === 'darwin' ? 'open' : 'xdg-open';
    try { spawn(cmd, [url], { detached: true, stdio: 'ignore', shell: false }).unref(); } catch { /* ignore */ }
  }
});

process.on('SIGINT', () => {
  for (const [, run] of runs) { if (run.status === 'running') { try { run.child.kill('SIGTERM'); } catch { } } }
  console.log('\n  stopped.');
  process.exit(0);
});
