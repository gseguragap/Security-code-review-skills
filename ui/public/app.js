/* ============================================================================
   Security Code Review - local UI client.
   No framework, no build step. Talks to the Node server over fetch + SSE.
   ========================================================================= */
'use strict';

const $ = sel => document.querySelector(sel);
const fields = {
  projectName: $('#projectName'),
  legacyPath: $('#legacyPath'),
  modernizedPath: $('#modernizedPath'),
  outDir: $('#outDir'),
  depth: $('#depth')
};

let validation = null;
let runId = null;
let evtSource = null;
let timer = null;
let startedAt = 0;
let lastEventAt = 0;
let activityLabel = '';

// Silence longer than this stops the spinner and says how long it has been quiet. A long
// Read or a big Grep can genuinely take a minute, so this is set well past that: the point
// is to catch a dead run, not to cry wolf at a slow one.
const STALL_MS = 90000;

/* ------------------------------------------------------------- preflight */

async function preflight() {
  const box = $('#preflight');
  try {
    const pre = await (await fetch('/api/preflight')).json();
    const pill = (ok, label, value) =>
      `<span class="pf ${ok ? 'ok' : 'bad'}"><span class="dot"></span>${label} <b>${esc(value)}</b></span>`;
    box.innerHTML =
      pill(true, 'node', pre.node) +
      pill(!!pre.cli, 'claude', pre.cli || `not found (${pre.cliBin})`) +
      pill(pre.skillInstalled, 'skill', pre.skillInstalled ? 'installed' : 'not installed');

    if (!fields.outDir.placeholder || fields.outDir.placeholder.startsWith('(')) {
      fields.outDir.placeholder = pre.cwd;
    }
    if (!pre.cli) {
      msg('The Claude Code CLI was not found. Start the server with CLAUDE_BIN=<full path> node ui/server.js, or put it on PATH.');
    } else if (!pre.skillInstalled) {
      msg('The security-code-review skill is not installed. Run install.ps1 or install.sh, then reload.');
    }
  } catch {
    box.innerHTML = '<span class="pf bad"><span class="dot"></span>server unreachable</span>';
  }
}

/* ------------------------------------------------------------ validation */

const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };

async function validate() {
  const body = {
    projectName: fields.projectName.value,
    legacyPath: fields.legacyPath.value,
    modernizedPath: fields.modernizedPath.value,
    outDir: fields.outDir.value
  };
  let v;
  try {
    v = await (await fetch('/api/validate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    })).json();
  } catch { return; }
  validation = v;

  paint('projectName', v.projectName);
  paint('legacyPath', v.legacy);
  paint('modernizedPath', v.modernized);
  paint('outDir', v.outDir);

  if (v.samePath) {
    setState('modernizedPath', 'error',
      'Same directory as the legacy path. Comparing a tree with itself gives an all-inherited report and a zero delta.');
  }

  $('#runBtn').disabled = !v.canRun;
  $('#copyBtn').hidden = !v.canRun;
  renderPlan(v);
  if (v.canRun) msg('');
}

function paint(id, r) {
  if (!r) return;
  setState(id, r.level, r.message || '');
}

function setState(id, level, text) {
  const el = document.querySelector(`.state[data-for="${id}"]`);
  if (!el) return;
  el.className = `state ${level || ''}`;
  el.textContent = text || '';
}

function renderPlan(v) {
  const box = $('#planBox');
  if (!v.canRun) { box.hidden = true; return; }
  const rows = [
    ['Project', esc(v.projectName.cleaned)],
    ['Legacy', v.legacy.abs
      ? `${esc(v.legacy.abs)}<br><em>${v.legacy.files.toLocaleString()} files &middot; ${esc(v.legacy.stack)} &middot; audit, no remediation</em>`
      : '<em>not provided &mdash; no Legacy report, no Comparison report</em>'],
    ['Modernized', `${esc(v.modernized.abs)}<br><em>${v.modernized.files.toLocaleString()} files &middot; ${esc(v.modernized.stack)} &middot; audit + remediation</em>`],
    ['Depth', `${esc(fields.depth.value)} <em>(both sides)</em>`],
    ['Output', `${esc(v.outDir.abs)}<br><em>${v.legacy.abs ? '3 reports: Legacy, Modernized, Comparison' : '1 report: Modernized'}</em>`],
    ['Access', [
      `<span class="grant">read</span> ${v.legacy.abs ? 'both source trees' : 'the modernized tree'}, and the skill&rsquo;s own templates`,
      `<span class="grant write">write</span> ${esc(v.outDir.abs)}`,
      '<em>Granted to the CLI for this run only, on its command line. Reports are written only ' +
      'to the output folder. The audit also runs the skill&rsquo;s own shell scripts to collect ' +
      'cost and assemble the HTML, so it can execute commands; it does not modify your source, ' +
      'but that is the skill&rsquo;s contract rather than a sandbox.</em>'
    ].join('<br>')]
  ];
  $('#planList').innerHTML = rows.map(([k, val]) => `<dt>${k}</dt><dd>${val}</dd>`).join('');
  box.hidden = false;
}

/* ------------------------------------------------------------------- run */

async function start() {
  $('#runBtn').disabled = true;
  msg('');
  let r;
  try {
    r = await (await fetch('/api/run', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        projectName: fields.projectName.value,
        legacyPath: fields.legacyPath.value,
        modernizedPath: fields.modernizedPath.value,
        outDir: fields.outDir.value,
        depth: fields.depth.value
      })
    })).json();
  } catch (e) {
    msg('Could not reach the server: ' + e.message);
    $('#runBtn').disabled = false;
    return;
  }
  if (r.error) { msg(r.error); $('#runBtn').disabled = false; return; }

  runId = r.runId;
  $('#formCard').hidden = true;
  $('#runCard').hidden = false;
  $('#log').textContent = '';
  $('#results').hidden = true;
  startedAt = Date.now();
  lastEventAt = Date.now();
  activityLabel = 'starting…';
  const act = $('#activity');
  act.hidden = false;
  act.classList.remove('stalled', 'ended');
  $('#activityText').textContent = activityLabel;
  timer = setInterval(tick, 1000);
  tick();
  listen();
}

function fmtDuration(s) {
  const m = Math.floor(s / 60);
  return m ? `${m}m ${String(s % 60).padStart(2, '0')}s` : `${s}s`;
}

function tick() {
  $('#elapsed').textContent = fmtDuration(Math.round((Date.now() - startedAt) / 1000));

  // Liveness is measured from the last event off the wire, not from the clock, so the
  // spinner stops when the work does.
  const quiet = Date.now() - lastEventAt;
  const act = $('#activity');
  if (act.classList.contains('ended')) return;
  if (quiet > STALL_MS) {
    act.classList.add('stalled');
    $('#activityText').textContent = `no output for ${fmtDuration(Math.round(quiet / 1000))}`;
  } else {
    act.classList.remove('stalled');
    $('#activityText').textContent = activityLabel;
  }
}

function listen() {
  evtSource = new EventSource(`/api/events?run=${encodeURIComponent(runId)}`);

  evtSource.addEventListener('line', e => {
    const d = JSON.parse(e.data);

    // Every line is proof of life; tool lines additionally say what the life consists of.
    lastEventAt = Date.now();
    if (d.stream === 'tool' || d.stream === 'err') {
      activityLabel = d.line.trim().slice(0, 120);
    }

    const span = document.createElement('span');
    span.className = 'line' + (d.stream === 'err' ? ' err' : d.stream === 'tool' ? ' tool' : '');
    span.textContent = d.line + '\n';
    const log = $('#log');
    log.appendChild(span);
    if ($('#autoscroll').checked) log.scrollTop = log.scrollHeight;
  });

  evtSource.addEventListener('phases', e => {
    const ph = JSON.parse(e.data);
    for (const [k, state] of Object.entries(ph)) {
      const li = document.querySelector(`.phases li[data-phase="${k}"]`);
      if (!li) continue;
      li.dataset.state = state;
      li.querySelector('.pstate').textContent = state;
    }
  });

  // Liveness pulse. The log deliberately stays quiet during a long single message - that is
  // a token stream, not output worth reading - but the run is working, and the activity
  // line says so with a character count that climbs.
  evtSource.addEventListener('alive', e => {
    lastEventAt = Date.now();
    const d = JSON.parse(e.data);
    if (d.label) activityLabel = d.label;
  });

  evtSource.addEventListener('cost', e => renderCost(JSON.parse(e.data)));

  evtSource.addEventListener('done', e => {
    const d = JSON.parse(e.data);
    clearInterval(timer);
    evtSource.close();
    $('#cancelBtn').disabled = true;
    finish(d);
  });

  evtSource.onerror = () => { /* server closed the stream; 'done' already handled it */ };
}

function fmtTokens(n) {
  if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1) + 'M';
  if (n >= 1e3) return Math.round(n / 1e3) + 'K';
  return String(n);
}

/**
 * The cost strip.
 *
 * While the run is live this is an ESTIMATE priced from assets/pricing.json against the
 * usage on the event stream. When the run ends the CLI reports its own total and that
 * replaces it. The two are labelled differently on purpose: the report's measured figure is
 * the number that counts, and a local guess wearing the same clothes would undermine it.
 */
function renderCost(c) {
  const box = $('#cost');
  if (!c || !c.messages) return;
  box.hidden = false;
  box.classList.toggle('measured', !!c.measured);
  box.classList.toggle('partial', !!c.partial && !c.measured);

  $('#costUsd').textContent = c.usd == null ? 'no price' : '$' + c.usd.toFixed(c.usd < 1 ? 4 : 2);
  $('#costTag').textContent = c.measured ? 'measured by the CLI'
    : c.partial ? 'partial estimate' : 'running estimate';
  $('#costBreak').textContent =
    `${fmtTokens(c.tokens)} tokens · ${c.messages} msg` +
    (c.partial ? ` · unpriced: ${c.unpriced.join(', ')}` : '') +
    (c.measured ? '' : ` · rates ${c.pricingVersion}`);
  box.title = c.measured
    ? 'Reported by the CLI for this session. List-price equivalent — on a subscription plan this is not what you are billed.'
    : `Estimated locally from stream usage at the list rates in assets/pricing.json (${c.pricingVersion}). The report's own measured figure is authoritative.`;
}

function finish(d) {
  const act = $('#activity');
  act.classList.remove('stalled');
  act.classList.add('ended');
  $('#activityText').textContent = d.status === 'done' ? 'finished'
    : d.exitCode == null ? d.status : `${d.status} (exit ${d.exitCode})`;
  if (d.cost) renderCost(d.cost);

  const box = $('#results');
  const list = $('#reportList');
  if (d.reports && d.reports.length) {
    list.innerHTML = d.reports.map(r => `
      <a class="report" data-kind="${esc(r.kind)}" target="_blank" rel="noopener"
         href="/report?run=${encodeURIComponent(runId)}&f=${encodeURIComponent(r.file)}">
        <span class="kind">${esc(r.kind)}</span>
        <span class="fname">${esc(r.file)}</span>
        <span class="size">${Math.round(r.size / 1024)} KB</span>
      </a>`).join('');
  } else {
    list.innerHTML = `<p class="hint">No reports were produced. Read the output above &mdash; the
      run exited with code ${d.exitCode}.</p>`;
  }
  $('#resultPath').textContent = d.projectDir ? `Saved in ${d.projectDir}` : '';
  box.hidden = false;
  $('#elapsed').textContent = `${d.status} in ${d.seconds}s`;
}

/* ---------------------------------------------------------------- events */

const revalidate = debounce(validate, 250);
for (const k of ['projectName', 'legacyPath', 'modernizedPath', 'outDir']) {
  fields[k].addEventListener('input', revalidate);
}
fields.depth.addEventListener('change', () => validation && renderPlan(validation));

$('#runBtn').addEventListener('click', start);

$('#cancelBtn').addEventListener('click', async () => {
  if (!runId) return;
  $('#cancelBtn').disabled = true;
  await fetch('/api/cancel', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ runId })
  });
});

$('#againBtn').addEventListener('click', () => {
  runId = null;
  $('#runCard').hidden = true;
  $('#formCard').hidden = false;
  $('#cancelBtn').disabled = false;
  $('#activity').hidden = true;
  $('#activity').classList.remove('stalled', 'ended');
  $('#cost').hidden = true;
  $('#cost').classList.remove('measured', 'partial');
  for (const li of document.querySelectorAll('.phases li')) {
    li.dataset.state = 'queued';
    li.querySelector('.pstate').textContent = 'queued';
  }
  validate();
});

$('#copyBtn').addEventListener('click', async () => {
  const v = validation;
  if (!v) return;
  const q = s => `"${s}"`;
  const parts = ['/security-code-review', '--name', q(v.projectName.cleaned)];
  if (v.legacy.abs) parts.push('--legacy', q(v.legacy.abs));
  parts.push('--modernized', q(v.modernized.abs), '--out', q(v.outDir.abs),
             '--depth', fields.depth.value, '--yes');
  // The server spawns with the output folder as its working directory and grants the two
  // source trees; a command pasted into a terminal starts wherever that terminal happens to
  // be, so it has to grant all three - the two trees to read, the output folder to write.
  // Without them the run reads nothing and still produces a report, which is the one
  // outcome worth a few extra characters on the command line.
  const dirs = [v.legacy.abs, v.modernized.abs, ...(v.skillDirs || []), v.outDir.abs].filter(Boolean);
  const grants = dirs.map(d => `--add-dir ${q(d)}`).join(' ');
  // Same three grants the server spawns with, in the same order: read on the trees and on
  // the skill's templates, write on the output folder alone. The rule is absolute, so this
  // behaves the same from whatever directory the terminal happens to be sitting in.
  const cmd = `claude ${grants} --allowedTools ${q(v.writeRule)} Bash PowerShell -p '${parts.join(' ')}'`;
  try {
    await navigator.clipboard.writeText(cmd);
    $('#copyBtn').textContent = 'Copied';
  } catch {
    window.prompt('Copy the command:', cmd);
  }
  setTimeout(() => { $('#copyBtn').textContent = 'Copy CLI command'; }, 1600);
});

function msg(text) {
  const el = $('#formMsg');
  el.textContent = text || '';
  el.classList.remove('ok');
}

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

preflight();
validate();
