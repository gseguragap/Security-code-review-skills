---
name: security-audit
description: Run a standards-aligned security code audit (OWASP Top 10, CWE, MITRE ATT&CK, NIST SSDF/800-53) over a given source path and emit a self-contained HTML report with scored findings, non-breaking remediation guidance, and the token/dollar cost of the analysis. Use when the user asks for a security audit, security review, security scan, vulnerability assessment, or "check this code for security issues" — and when a modernized/migrated codebase needs a post-generation security gate.
---

# Security Code Audit

Produce a rigorous, evidence-backed security review of a single source tree and deliver it as one
portable HTML file an engineer can open, read, filter, and work through.

**Zero installs. Never ask the user to install anything.** Everything this skill needs either ships
inside the skill folder or is already on the machine. No pip, no npm, no Docker, no scanner binaries,
no interpreter to fetch.

| Step | Uses | Always available because |
|---|---|---|
| Inventory, rule pass, triage | `Grep` / `Glob` / `Read` tools | Built into Claude Code (ripgrep is bundled) |
| Report assembly | `cat` **or** `Get-Content` | One of bash / PowerShell is always present |
| Cost accounting | see the ladder below | Three interchangeable implementations |

### Cost collector: use the first one that works

1. **Python** — `bin/cost.py`. Resolve an interpreter with `bin/ensure_python.sh` (or
   `ensure_python.ps1`); if it prints a path, prefer this. Best JSON handling.
2. **bash + awk** — `bin/collect-cost.sh`. Git Bash on Windows, native on macOS/Linux.
3. **PowerShell 5.1** — `bin/collect-cost.ps1`. Ships with every Windows 10/11.

All three produce an identical `cost.json` and are held to that by `tests/run_corpus.py`'s sibling
checks. If none can run, the audit still completes and the report records cost as `unavailable`.

**Never stop the audit to install anything, and never present a tool as a prerequisite.**
`ensure_python.*` will not download unless it is passed `--allow-download`, which requires the
user's explicit say-so — see below.

---

## Invocation

```
/security-audit <target-path> [options]
```

| Option | Default | Meaning |
|---|---|---|
| `<target-path>` | *(required)* | Directory or file to audit. **Hard boundary** — see Scope Confinement. |
| `--name "<Project>"` | inferred | Project name used in the report title and filename. |
| `--out <dir>` | `<target-path>/../security-reports` | Where the HTML report is written. |
| `--depth quick\|standard\|deep` | `standard` | Effort tier — see Depth Tiers. |
| `--mode analyze\|plan` | `plan` | `analyze` = findings only, **no remediation of any kind**. `plan` = findings + per-finding fixes + phased roadmap + projected score. See Modes. |
| `--variant legacy\|modernized\|standalone` | `standalone` | Labels the report and its filename. Used by the modernization flow so Legacy and Modernized reports are unmistakable. |
| `--exclude "<globs>"` | see Inventory | Extra comma-separated globs to skip. |
| `--baseline <findings.json>` | none | Prior run to diff against; marks findings as New / Persisting / Resolved. |
| `--no-cost` | off | Skip cost accounting (report still renders, cost section shows "not collected"). |

If `<target-path>` is missing, ask for it before doing anything else. Do not default to the
current working directory — auditing the wrong tree wastes real money.

---

## Modes

| | `--mode plan` (default) | `--mode analyze` |
|---|---|---|
| Findings, evidence, severity, confidence | yes | yes |
| Standards mapping (OWASP/CWE/ATT&CK/NIST) | yes | yes |
| Strengths, evidence log, limitations | yes | yes |
| Current score | yes | yes |
| `finding.remediation` object | yes | **omit entirely** |
| `finding.verification` | yes | **omit entirely** |
| `roadmap[]` | yes | **omit entirely** |
| `scores.projected` + uplift | yes | **omit entirely** |

`analyze` is a **diagnosis-only** run. It exists because there are codebases nobody intends to fix —
a legacy system being retired at the end of a migration is the canonical case. Writing fix plans for
code that is about to be deleted burns tokens and invites someone to act on them.

When `--mode analyze` is set, say so in the report's Limitations section:
*"Remediation guidance was intentionally not produced for this codebase; this report is a diagnostic
baseline only."* A reader must never wonder whether the fixes were omitted or simply forgotten.

---

## Variants

`--variant` labels a report so it cannot be confused with its counterpart. It changes three things
and nothing else — the analysis itself is identical.

| Variant | `meta.variantLabel` | Filename segment | Typical use |
|---|---|---|---|
| `standalone` | *(none)* | *(none)* | A normal one-off audit |
| `legacy` | `Legacy` | ` - Legacy` | The pre-migration source tree |
| `modernized` | `Modernized` | ` - Modernized` | The post-migration source tree |

Set `meta.variant` and `meta.variantLabel` in `findings.json`; the template renders the label in the
masthead and in the browser tab. See Step 8 for the filename rule.

---

## Scope Confinement (non-negotiable)

1. Resolve `<target-path>` to an absolute path. Call it **ROOT**.
2. Every `Grep`, `Glob`, and `Read` for *analysis purposes* must be rooted at ROOT.
3. Never read, and never quote in the report, a file outside ROOT. The only paths outside ROOT you
   may touch are:
   - this skill's own `rules/`, `references/`, `assets/`, `bin/` files,
   - the output directory you write the report to,
   - the session transcript, for cost accounting only (never its contents in the report).
4. **If ROOT is not inside the current workspace, check that you can actually read it before you
   audit it.** A directory outside the workspace is not merely unusual — it is unreadable: `Glob`
   and `Read` come back *denied*, which looks exactly like an empty tree and produces a report with
   no findings, i.e. a clean bill of health for a codebase nobody opened. `Glob` ROOT first. If it
   returns nothing or reports a permission error while the directory plainly exists, **stop and say
   so** — name the path, and say the caller must grant it: `--add-dir <ROOT>` on a `claude -p`
   command line, `/add-dir <ROOT>` in an interactive session. A skill cannot widen its own access,
   and guessing is not an option here: an unreadable tree and a clean tree are indistinguishable in
   the output. (On Windows, an 8.3 short path such as `C:UsersGILBER~1src` is rejected by the
   path guard for the same effect — ask for the long form.) Once readable, continue — but do not
   traverse upward from ROOT under any circumstance (no `../`).
5. Report every path in the findings **relative to ROOT**, so the report is portable and does not
   leak the auditor's local directory layout.
6. **ROOT is never written to.** Everything this skill produces goes under `--out`. Treat this as
   an absolute rule of your own, not as something the sandbox will catch: the file tools are
   confined to the output directory, but this skill also runs shell commands, and a shell is not.
   If you find yourself wanting to edit a file inside ROOT, stop — remediation is *described* in
   the report, never applied. That includes "harmless" fixes, formatting, and test files.
7. **The output directory has to be writable, and so does this skill's own folder.** `bin/` and
   `assets/` are read to collect cost and render the report; `--out` is written. In a headless run
   both need granting by the caller (`--add-dir`, plus `--allowedTools "Edit(<out>/**)"` for the
   write). Check early: if the output directory cannot be written, say so **before** Step 2 rather
   than after Step 7, so nobody pays for an analysis that cannot be saved.

---

## Depth Tiers

| Tier | Rule packs | Manual review | Relative cost | Use for |
|---|---|---|---|---|
| `quick` | universal + detected stack | Critical/High evidence only | 1x | CI gate, smoke check, re-run after fixes |
| `standard` | all matching packs | Every rule hit triaged; auth and data-flow read of entry points | ~3x | Default; release review |
| `deep` | all matching packs | Above, plus manual reading of every entry point, trust boundary, auth path and data sink; business-logic review | ~8x | Pre-production, regulated workloads, first audit of a codebase |

State the tier in the report.

---

## Procedure

### Step 0 — Start the cost watermark

Before any analysis work, run:

```bash
PY=$(bash <skill>/bin/ensure_python.sh --quiet) && "$PY" <skill>/bin/cost.py --mark --out <out>/.security-audit \
  || bash <skill>/bin/collect-cost.sh --mark --out <out>/.security-audit
```

or, where bash/awk are absent (a Windows machine without Git Bash):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>/bin/collect-cost.ps1 -Mark -Out <out>/.security-audit
```

It records the transcript path and current line count. Everything billed after this point is
attributed to the audit. If it fails (no transcript at all), note it and continue — the report falls
back to an estimated cost and says so plainly. Do not treat this as a blocker.

### Step 1 — Inventory and stack detection

Confined to ROOT:

- `Glob` for build/manifest files: `**/*.csproj`, `**/*.sln`, `pom.xml`, `build.gradle*`,
  `package.json`, `requirements*.txt`, `pyproject.toml`, `Pipfile`, `go.mod`, `composer.json`,
  `Gemfile`, `*.cbl`, `*.4gl`, `*.per`, `*.vbp`, `*.dpr`.
- Count files and lines by extension. Record what you skipped.
- **Always exclude** from analysis (but count as skipped): `node_modules/`, `bin/`, `obj/`, `dist/`,
  `build/`, `out/`, `target/`, `vendor/`, `.git/`, `packages/`, `__pycache__/`, `.venv/`, `venv/`,
  `*.min.js`, `*.map`, `*.lock`, and binary/media files. Vendored third-party source is out of
  scope for findings but **in scope for the dependency check**.
- Identify: languages, frameworks, web/UI layer, data-access layer, auth mechanism (or its
  absence), deployment/config files, and the application's entry points.

**An empty inventory is a stop condition, not a result.** If the file count is zero — or absurdly
low against a tree the user described as a real codebase — do not proceed to Step 2. Say what you
found and check access first (Scope Confinement rule 4); a scored report over zero files is worse
than no report, because it looks like good news.

Write `<out>/.security-audit/inventory.json`.

### Step 2 — Deterministic rule pass

Read `rules/00-index.json`, then load every rule pack whose `appliesTo` matches the detected stack
(`universal.json` always applies). Each rule looks like:

```json
{ "id": "DN-INJ-01", "pattern": "<ripgrep regex>", "glob": "**/*.cs",
  "severity": "High", "owasp": "A03:2021", "cwe": ["CWE-89"],
  "expect": "absent-is-ok",
  "title": "...", "why": "...", "falsePositiveHints": "..." }
```

Run each rule with the `Grep` tool: `pattern` + `glob` + `path: ROOT` + `output_mode: "content"` +
`-n: true`. Batch independent greps in a single message so they run concurrently.

`expect` has two values:
- `absent-is-ok` (default) — hits are candidate findings.
- `present-required` — a **zero-hit** result is the candidate finding (e.g. no `[Authorize]`
  anywhere in a web app, no parameterized-query usage, no CSP header). These absence checks catch
  what pattern matching structurally cannot.

Collect every hit with file, line and matched text into `<out>/.security-audit/raw-hits.json`.

> The rule pass is a **sensor, not a verdict.** It produces candidates. Nothing from it reaches the
> report untriaged.

### Step 3 — Triage (this is the part that matters)

Follow `references/triage-protocol.md` in full. In short, for every candidate:

1. **Read the surrounding code** — not just the matched line. A grep hit is a hypothesis.
2. **Decide reachability.** Is it on a path untrusted input can reach? Raw SQL built from a
   compile-time constant is not an injection. `MarkupString` over a literal is not XSS.
3. **Classify confidence**: `Confirmed` (you read the code and the flaw is present), `Likely`
   (strong signal, one unverified assumption), `Possible` (needs human confirmation). Anything you
   cannot get to `Confirmed` or `Likely` is dropped, or filed as `Info` with the open question
   stated. **Never inflate confidence.**
4. **Deduplicate** — one finding per root cause, with all locations listed under it. Not one
   finding per grep hit.
5. **Add what grep cannot see.** The deterministic pass finds patterns; you find *design* flaws:
   missing authorization on a mutation, an IDOR, a trust boundary crossed without validation, a
   tenant check done in the UI but not the service, a secret "encrypted" with a hard-coded key. On
   `standard` and `deep`, read the entry points and follow the request path.
6. **Record the strengths too.** Controls correctly in place raise the score and belong in the
   report — this is what makes the score credible rather than alarmist.

Then map every finding to OWASP Top 10 (2021 primary; note the 2025 category where it differs),
CWE, MITRE ATT&CK technique and NIST SSDF / SP 800-53 control, using
`references/standards-mapping.md`. **Do not invent identifiers.** If you are unsure of an ATT&CK ID
or a CVE, omit the field rather than guess.

### Step 4 — Dependency check

- Parse the manifests found in Step 1; list declared direct dependencies with versions.
- If a native toolchain is present **and the user approves running it**, prefer ground truth:
  `dotnet list package --vulnerable --include-transitive`, `npm audit --json`, `pip-audit`,
  `mvn org.owasp:dependency-check-maven:check`. **Ask before running any of these** — they execute
  project tooling and may hit the network.
- Otherwise you may confirm advisories against the public OSV API via `WebFetch`
  (`https://api.osv.dev/v1/query`). See **MCP & network** below.
- If you cannot verify advisories, say exactly that: report the inventory and file a finding for
  *"no automated dependency scanning in the pipeline"* rather than asserting packages are clean.
  **An unverified dependency is not a safe dependency.**

### Step 5 — Score

Apply `references/scoring.md` — weighted per-category scores, 0–100, letter grade, posture band,
plus the projected post-remediation score when `--mode plan`. The report's methodology section
shows the arithmetic, so the number is auditable rather than magical.

### Step 6 — Remediation plan (`--mode plan`)

**If `--mode analyze`, skip this step entirely** and omit `remediation`, `verification`, `roadmap`
and `scores.projected` from `findings.json`. Do not write "TBD" or an empty remediation object —
absent means absent. Then continue at Step 7.

For every finding write a **non-breaking** remediation per `references/remediation-playbook.md`:
additive middleware, attributes, configuration, opt-in validation — preserving behavior for
legitimate users. Each carries a concrete `verification` step the engineer can run. Group findings
into phases ordered by risk reduction per unit of effort, with the projected score after each phase.

Where a fix genuinely cannot be non-breaking, mark it `breakingChange: true` and give the migration
note. Do not present a breaking change as safe.

### Step 7 — Write the findings document

Write `<out>/.security-audit/findings.json`, conforming to `references/report-schema.md`.

Include the cost block as an **empty placeholder** — it is filled in mechanically two steps from
now, so do not try to write real numbers into it:

```json
  "cost": {},
```

This document is the largest single output of the audit. It is written *before* cost is collected
so that writing it lands inside the measured window; collecting cost first left the most expensive
step of the phase outside the meter and understated every report.

### Step 8 — Collect cost

```bash
# same ladder as Step 0 - use whichever collector resolved there
PY=$(bash <skill>/bin/ensure_python.sh --quiet) && "$PY" <skill>/bin/cost.py --report --out <out>/.security-audit \
  || bash <skill>/bin/collect-cost.sh --report --out <out>/.security-audit
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>/bin/collect-cost.ps1 -Report -Out <out>/.security-audit
```

This replays the transcript from the watermark, dedupes assistant messages by id, sums input /
cache-write / cache-read / output tokens per model, prices them from `assets/pricing.json`, and
writes `cost.json`.

**A measured figure is only ever produced from a watermark that still resolves.** If the watermark
is missing, unreadable, points at a transcript that is gone, sits past the end of the file, or spans
no assistant turns, the collector writes `"source": "unavailable"` with a `reason` and refuses to
put a number on it. It will never fall back to scanning the whole session — that would bill every
turn since the session began to this audit and label the result measured.

If you get `"source": "unavailable"`, read the `reason`, then either fix it and re-run or supply an
honest estimate and set `"source": "estimate"`. The template renders an explicit caveat for
estimates. **Never edit an `unavailable` result into a confident number.**

### Step 9 — Merge the cost block and render

1. Splice the measured cost into the findings document. This is deterministic text work and costs
   no model tokens, which is why it is safe to run after the meter has stopped:

   ```bash
   PY=$(bash <skill>/bin/ensure_python.sh --quiet) && "$PY" <skill>/bin/merge-cost.py \
        --findings <out>/.security-audit/findings.json --cost <out>/.security-audit/cost.json \
     || bash <skill>/bin/merge-cost.sh \
        --findings <out>/.security-audit/findings.json --cost <out>/.security-audit/cost.json
   ```

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File <skill>/bin/merge-cost.ps1 `
     -Findings <out>/.security-audit/findings.json -Cost <out>/.security-audit/cost.json
   ```

   It replaces the `"cost": {},` placeholder line in place. Exit 65 means the placeholder was
   missing — go back to Step 7 and add it rather than hand-editing the JSON.


2. Concatenate template + data + template:

   ```bash
   cat "<skill>/assets/report.part1.html" \
       "<out>/.security-audit/findings.json" \
       "<skill>/assets/report.part2.html" \
       > "<out>/<Project> - Security analysis report. - YYYY-MM-DD.html"
   ```

   PowerShell equivalent:
   ```powershell
   Get-Content "<skill>/assets/report.part1.html","<out>/.security-audit/findings.json","<skill>/assets/report.part2.html" -Raw |
     Set-Content "<out>/<Project> - Security analysis report. - YYYY-MM-DD.html" -Encoding utf8
   ```

   The template renders the JSON — **you never hand-write report HTML.** This keeps output
   consistent, keeps escaping correct, and spends your tokens on analysis instead of markup.

3. **Filename is exact:**

   ```
   <Project name>[ - <Variant>] - Security analysis report. - <YYYY-MM-DD>.html
   ```

   The period after "report" is part of the required format. `<Variant>` is `Legacy` or
   `Modernized`, present only when `--variant` was given; a `standalone` run omits the segment
   entirely and keeps the original two-part name. Strip only characters illegal in filenames
   (`\ / : * ? " < > |`) from the project name.

   ```
   AcmeBilling - Security analysis report. - 2026-09-11.html              # standalone
   AcmeBilling - Legacy - Security analysis report. - 2026-09-11.html     # --variant legacy
   AcmeBilling - Modernized - Security analysis report. - 2026-09-11.html # --variant modernized
   ```

4. Verify the result: the file is non-trivial in size, and the JSON you injected parses. A report
   that renders a blank page is worse than no report.

5. **Leave `<out>/.security-audit/findings.json` in place.** It is not a temp file — it is the
   machine-readable record of this run, and it is the input the `security-audit-compare` skill and
   the `--baseline` option both read. Deleting it means the audit has to be paid for twice.

### Step 10 — Report back

Tell the user in a few lines: score and grade, counts by severity, the top three things to fix
first, the report path, and the measured cost. If cost came back
`unavailable`, say so plainly rather than quoting a number. Do not paste the report into the terminal.

---

## MCP & network requirements

**The core audit requires no MCP server and no network access.** Static analysis, triage, scoring,
report generation and cost accounting are all local.

Two areas are *improved* by network access, and the report must state which was used:

| Need | Preferred | Fallback | If neither |
|---|---|---|---|
| Confirm CVEs for declared dependencies | An advisory MCP server, if the org has one (GitHub Advisory / OSV / Snyk / Sonatype) | Built-in `WebFetch` against `https://api.osv.dev/v1/query`, or `WebSearch` | Report the dependency inventory plus a finding for missing dependency scanning. **Never claim a package is clean without checking.** |
| Confirm a framework's current hardening guidance | A vendor-docs MCP server, if available | `WebFetch` of the vendor's security documentation | Use `references/` and label the guidance with its version date |

**Advertise the gap.** If a run had no network and no advisory MCP, the report's Limitations
section must state: *"Dependency advisories were not verified against a live vulnerability
database; dependency findings reflect inventory and policy only."* Say the same in the terminal
summary. Silence here would be the most misleading thing this skill could do.

No MCP server is bundled with this skill and none is auto-enabled. Enabling one, or approving
`WebFetch`, is the user's call.

---

## Python policy

Python is an **optional accelerator, never a prerequisite.** The audit is fully functional without
it. `bin/ensure_python.sh` / `.ps1` resolve an interpreter in this order:

1. `$SECURITY_AUDIT_PYTHON`
2. PATH candidates — **probed by executing code**, not trusted
3. Well-known install locations, and the registry PATH on Windows
4. A previously bootstrapped copy in the user cache
5. A pinned download — **only with `--allow-download`**

Steps 2 and 3 exist for a specific reason. On Windows,
`%LOCALAPPDATA%\Microsoft\WindowsApps\python.exe` is a **0-byte App Execution Alias** that resolves
on PATH, prints a Microsoft Store advert and exits non-zero. Anything that trusts `command -v` picks
it and fails. Equally common: the registry PATH is correct but the *running process* started before
Python was installed, so a perfectly good interpreter is invisible to PATH. Step 3 finds it anyway.

**Do not run step 5 on your own initiative.** Ask the user first, tell them what will be downloaded
and how large it is, and proceed only on a clear yes. If they decline, fall back and say nothing
further — the audit is unaffected. The download is pinned to an exact version and **verified against
a SHA-256 in `assets/python-bootstrap.json` before anything is extracted**; a mismatch fails closed.
It installs into the user cache, never into the skill folder or the audited repository.

That verification is not ceremony: this skill's own `CFG-CI-02` rule flags curl-piped-to-shell and
unpinned dependencies as findings. A pinned version plus a verified hash is what keeps the skill on
the right side of the advice it gives.

## Related skills

This skill audits **one** source tree. Two companions extend it to modernization work:

| Skill | Does |
|---|---|
| `security-code-review` | Orchestrator. Collects project name + legacy path + modernized path, runs this skill once or twice, then runs the comparison, and files everything under one project folder. |
| `security-audit-compare` | Consumes two `findings.json` files from this skill and produces the Legacy-vs-Modernized comparison report. |

Either can be absent — this skill never depends on them. But when you are auditing one side of a
migration, two things change:

- **Do not populate `origin`** (`legacy-inherited` / `migration-introduced` / …) from a single-tree
  audit. Origin is a claim about two codebases, and you can only see one. Guessing it produces a
  confident-looking field that is unverifiable. Leave it out; `security-audit-compare` derives it
  from both runs, with a stated matching confidence.
- Do fill in `meta.migration` with what you *can* see (source and target language, and
  `sourcePathAudited: null` when the other side was not in scope).

## Rules of engagement

- **Evidence or it does not ship.** Every finding cites `file:line` inside ROOT with a real excerpt.
- **No invented identifiers.** CWE / ATT&CK / CVE numbers must be ones you actually know. Omit
  rather than guess — a wrong CVE discredits the whole document.
- **Read-only by default.** This skill audits; it does not edit the code under review. Applying
  fixes is a separate, explicitly requested step, and each fix must be build-verified before it is
  claimed as done.
- **Report what you did not do.** Skipped directories, unparsed languages, unreachable tooling,
  absent runtime testing — all belong in Limitations. Static analysis cannot see runtime
  configuration, deployed secrets, infrastructure policy or business-logic intent.
- **No false comfort.** "No findings in category X" is reportable only if X was actually checked.
  Otherwise it is "not assessed".
- **The score serves the reader.** Do not tune weights to produce a nicer number.

---

## Files in this skill

```
SKILL.md                            this file
rules/00-index.json                 rule pack registry + stack matching
rules/*.json                        ripgrep rule packs by stack
references/triage-protocol.md       turning grep hits into findings
references/scoring.md               the scoring model and its arithmetic
references/standards-mapping.md     OWASP / CWE / ATT&CK / NIST crosswalk
references/remediation-playbook.md  non-breaking fix patterns by category
references/report-schema.md         the findings.json contract the template renders
assets/report.part1.html            report template, head half
assets/report.part2.html            report template, tail half (the renderer)
assets/pricing.json                 model token rates for cost accounting
assets/python-bootstrap.json        pinned CPython builds + SHA-256, for the opt-in bootstrap
bin/ensure_python.sh / .ps1         resolve a Python interpreter; never demands an install
bin/cost.py                         cost collector (preferred when Python is available)
bin/collect-cost.sh                 cost collector (bash + awk fallback)
bin/collect-cost.ps1                cost collector (PowerShell 5.1 fallback)
bin/cost.awk                        transcript usage extractor used by the bash collector
bin/merge-cost.py / .sh / .ps1      splice a measured cost.json into findings.json
bin/rollup-cost.py                  combine per-phase cost.json files into one cost block
tests/run_corpus.py                 rule-pack regression tests (maintainers only)
tests/test_cost.py                  cost-measurement regression tests (maintainers only)
tests/corpus/                       vulnerable/safe fixtures + expected.json
examples/                           a worked findings.json and the report it produces
```

### Maintaining the rule packs

Any change to `rules/*.json` must be followed by:

```bash
python tests/run_corpus.py
```

It checks that every pattern compiles under ripgrep's Rust regex engine (no lookaround, no
backreferences) and that rules fire on the vulnerable fixtures **and stay silent on the safe ones**.
The silence half is the one that matters: a rule that flags parameterized SQL teaches engineers to
ignore the report, and that loss is permanent. Every new rule should arrive with at least one
`reject` case drawn from its own `falsePositiveHints`.

This is the only part of the skill that needs Python, and only for maintainers — never for users.
