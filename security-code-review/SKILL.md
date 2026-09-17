---
name: security-code-review
description: Run a complete security review of a software modernization project. Collects the project name, the legacy source path and the modernized source path, audits each codebase, and produces Legacy, Modernized and Comparison HTML reports in one project folder, each with its token and dollar cost. Use when the user asks to review the security of a migration or modernization, compare the security of an old and new codebase, or run "the security agent" on a project.
---

# Modernization Security Review

The entry point for auditing a modernization. One invocation produces up to three reports in one
folder:

| Report | Produced when | Contains |
|---|---|---|
| **Legacy** | a legacy path was given | Findings, evidence, score. **No remediation** — nobody is fixing a system that is being replaced. |
| **Modernized** | always | Findings, evidence, score, full non-breaking remediation and a phased roadmap. |
| **Comparison** | both paths were given | What the migration resolved, inherited, introduced, and newly exposed — plus remediation and the total cost of the whole review. |

**Zero installs. Never ask the user to install anything.** This skill orchestrates two skills that
are themselves dependency-free. It needs a shell and nothing else.

## Skills this orchestrates

| Skill | Role | Required |
|---|---|---|
| `security-audit` | Audits one source tree; emits one HTML report + `findings.json` | **yes** |
| `security-audit-compare` | Joins two `findings.json` into the comparison report | only for the comparison |

If `security-audit` is not installed, stop and say so — there is nothing to orchestrate. If
`security-audit-compare` is missing, still produce both audits, then say plainly that the comparison
was skipped and why. Deliver what you can; never fail the whole run over the last step.

---

## Invocation

```
/security-code-review [options]
```

| Option | Default | Meaning |
|---|---|---|
| `--name "<Project>"` | *asked* | Project name. Also the output folder name. |
| `--legacy <path>` | *asked* | Legacy source tree. Empty / `none` / `skip` = no legacy phase. |
| `--modernized <path>` | *asked* | Modernized source tree. Required. |
| `--out <dir>` | current working directory | Parent directory; the project folder is created inside it. |
| `--depth quick\|standard\|deep` | `standard` | Passed to both audits. Both sides must use the same depth. |
| `--yes` | off | Skip the confirmation step. For UI and CI callers that have already confirmed. |

Anything supplied on the command line is **not** asked for again. That is what lets the same skill
serve an engineer typing in VS Code and a UI or CI job shelling out:

```bash
claude --add-dir /src/acme/legacy --add-dir /src/acme/modern \
  -p '/security-code-review --name "AcmeBilling" \
      --legacy  /src/acme/legacy \
      --modernized /src/acme/modern \
      --out /reports --yes'
```

Note the `--add-dir` for each source tree. Both normally sit outside the working directory, and a
directory outside the workspace is unreadable no matter how correct the path is — see
[Directory access](#directory-access) below.

---

## Directory access

The two source trees are almost always outside the working directory, and **a path outside the
workspace cannot be read at all** — `Read` and `Glob` come back denied rather than empty. That
failure mode is the dangerous one for this skill: an audit that could not open a single file still
produces a report, and a report with no findings reads exactly like a clean codebase.

So confirm access before Phase A rather than assume it:

- `Glob` each resolved path, as Step 1 already requires. A tree that exists on disk but returns
  nothing, or returns a permission error, is **not** an empty tree — it is an unreadable one.
- If reads are denied, **stop and say so**. Name the path and the fix. Do not audit what you could
  not open, and never let a phase report zero findings on a tree it never read.

**Writing is a separate grant, and it fails just as quietly.** A headless run will not write a file
anywhere it has not been allowed to, so an audit can read the whole codebase, score it, and then
save none of it. Phase A gets all the way to `findings.json` and stops. If a write is denied, say
so and stop — do not keep auditing to produce reports that cannot be saved.

The fix belongs to the **caller** — a skill cannot widen its own access:

| Caller | Reading the source trees | Writing the reports |
|---|---|---|
| Local web UI | Automatic, from the form fields | Automatic, output folder only |
| `claude -p` / CI | `--add-dir <path>` per tree, ahead of `-p` | `--add-dir <out>` **and** `--allowedTools "Edit(<out>/**)" Bash PowerShell` |
| Interactive session | `/add-dir <path>` per tree | `/add-dir <out>`, then approve the writes when asked |

The rule is `Edit`, not `Write` — only `Edit` rules are consulted by the file permission check —
spelled with forward slashes even on Windows, and with no leading `//`.

The skill's own folder (`~/.claude/skills`) must be readable too: the audit runs its `bin/`
collectors and cats its `assets/` templates to render the report. In an interactive session it
already is. A headless caller has to grant it, or the run analyses correctly and then fails at the
very last step with the expensive part already paid for.

Grant those and nothing wider. A common parent, or a drive root, hands the run access to everything
alongside them for no benefit — each phase reads only its own ROOT anyway, and writes only under
`--out`.

**On Windows, pass the long path.** An 8.3 short name (`C:\Users\GILBER~1\src`) is rejected by the path
guard and every read through it is denied — which looks identical to an empty tree. The UI
canonicalises what you type; a command line does not.

---

## Step 1 — Collect the inputs

Ask for everything still missing **in one message**, numbered, then wait:

```
Before I start, three things:

1. Project name?            (used for the report folder and titles)
2. Legacy source path?      (leave blank or say "none" if there is no legacy codebase to audit)
3. Modernized source path?  (required)
```

One message rather than three round trips — the questions are independent and a reader can answer
them together. Follow up only on what is missing or ambiguous.

### Validating what comes back

Do this **before** spending anything. A typo caught here costs nothing; caught after the audit it
costs a full run.

- **Project name** — strip characters illegal in filenames (`\ / : * ? " < > |`). If stripping
  changes it, show the name you will actually use. If it is blank, ask again.
- **Each path** — resolve to an absolute path and confirm with `Glob` that it exists, is readable
  and contains source files. If a path does not exist, say so and ask again; do not guess at a
  correction, and never silently fall back to the working directory. If it exists but reads come
  back denied, that is a directory-access problem rather than an empty tree — see
  [Directory access](#directory-access).
- **Empty legacy** — blank, `none`, `n/a`, `-`, `skip` and similar all mean *skip the legacy phase*.
  Take it at face value and move on; do not press for a path the user has said is not there.
- **Modernized is required.** If it is missing or does not exist, ask again. If the user genuinely
  has no modernized tree, they want `/security-audit` on the legacy tree instead — say so and stop.
- **Same tree twice?** If both paths resolve to the same directory, say so and ask. Comparing a tree
  with itself produces a report whose every finding is "inherited" and whose delta is zero.

## Step 2 — Confirm the plan

Unless `--yes` was given, show the plan and wait for a yes. Audits cost real money — the example
review in the comparison skill's `examples/` cost about **$6** — and the point of this step is that
the user sees the resolved output path and both resolved source paths before any of it is spent.

```
Project:     AcmeBilling
Legacy:      C:\src\acme\legacy        (2,140 files)      -> audit, no remediation
Modernized:  C:\src\acme\modern        (148 files)        -> audit + remediation
Depth:       standard
Output:      C:\reports\AcmeBilling\
             3 reports: Legacy, Modernized, Comparison

Proceed?
```

State file counts from `Glob` — an unexpectedly large or small number is the cheapest possible
signal that a path is wrong, and it shows up here rather than twenty minutes later.

If the user declines, stop. Do not offer a reduced version unprompted.

## Step 3 — Create the project folder

```
<out>/<Project name>/
  .security-audit/
    legacy/            findings.json, inventory.json, raw-hits.json, cost.json, cost-watermark
    modernized/        (same)
    comparison/        comparison.json, functional-areas.json, pairings.json, cost.json
    run.json           this run's manifest
```

The three HTML reports land directly in `<out>/<Project name>/` so the folder opens clean. The
`.security-audit/` working directory holds the machine-readable record — it is what makes a re-run
cheap, what feeds `--baseline` on the next audit, and what the comparison phase reads.

If the folder already exists and holds reports from an earlier run, say so and ask whether to
overwrite or write into a dated subfolder. Never silently overwrite a previous review — someone may
have circulated those files.

Write `run.json` as you go: project name, both source paths, depth, start time, and per-phase status
(`pending` / `done` / `skipped` / `failed`). If a later phase fails, this file plus the artifacts
already on disk let the run resume without repeating what was paid for.

## Step 4 — Run the phases

### Phase A — Legacy audit  *(skip entirely if no legacy path)*

Invoke `security-audit` with:

```
--name "<Project>"  --variant legacy  --mode analyze  --depth <depth>
--out <project folder>            <legacy path>
```

`--mode analyze` is the point of this phase: findings, evidence and a score, and **no remediation of
any kind**. The legacy system is being replaced; a fix plan for it would be work nobody will do, and
it invites a reader to spend effort on the wrong codebase.

Point the cost watermark at `.security-audit/legacy/` so this phase's cost is measured on its own.

Produces: `<Project> - Legacy - Security analysis report. - <date>.html`

### Phase B — Modernized audit  *(always)*

```
--name "<Project>"  --variant modernized  --mode plan  --depth <depth>
--out <project folder>            <modernized path>
```

Full run with per-finding non-breaking remediation, verification steps and a phased roadmap. Cost
watermark at `.security-audit/modernized/`.

Produces: `<Project> - Modernized - Security analysis report. - <date>.html`

### Phase C — Comparison  *(only when both audits completed)*

```
/security-audit-compare
  --legacy      <project folder>/.security-audit/legacy/findings.json
  --modernized  <project folder>/.security-audit/modernized/findings.json
  --name "<Project>"  --out <project folder>
  --cost <...>/legacy,<...>/modernized
```

Produces: `<Project> - Comparison - Security analysis report. - <date>.html`

### Phase rules

- **Sequential, always.** Phase C reads what A and B wrote. Running the two audits concurrently
  would also make the per-phase cost watermarks overlap and the segmented figures meaningless.
- **Each phase is confined to its own ROOT.** The legacy audit never reads the modernized tree and
  vice versa. Scope confinement is per phase, not per run.
- **A failed phase does not abort the run.** If the legacy audit fails, note it and continue with
  the modernized audit; deliver that report and say the comparison could not be produced. Record it
  in `run.json` and say it in the summary. Partial delivery beats nothing, as long as the gap is
  stated.

## Step 5 — Announce completion

The user asked for this explicitly, so make it unmissable — and make it readable without opening
anything:

```
Security review complete - AcmeBilling

  Legacy       58/100  F   At Risk     5 findings   (2 Critical, 1 High)
  Modernized   49/100  F   Critical    4 findings   (1 Critical, 1 High)
  Comparison   -9 points across the migration

  Introduced by the migration   1   <- authentication was not carried across
  Inherited from legacy         1
  New surface                   1
  Resolved                      2   (1 of them only because the feature was not migrated)

  Reports in C:\reports\AcmeBilling\
    AcmeBilling - Legacy - Security analysis report. - 2026-09-11.html
    AcmeBilling - Modernized - Security analysis report. - 2026-09-11.html
    AcmeBilling - Comparison - Security analysis report. - 2026-09-11.html

  Total cost: 4,022,570 tokens, $6.24
```

Then, in one or two sentences, the single most important thing found. Lead with what the comparison
exposes that neither audit alone would — a control dropped in the migration, or a legacy flaw
carried across. That is the finding this whole flow exists to surface.

Do not paste report contents into the terminal.

---

## Cost accounting across phases

Each phase marks its own watermark before it starts and reports against it when it finishes, into
its own `.security-audit/<phase>/` directory. Because phases run sequentially, the transcript
segments never overlap, so no turn is billed to two phases.

The segments are disjoint but not contiguous: the watermark closes after each phase writes its
findings document, and the handful of deterministic steps that follow — rendering the HTML, moving
to the next phase — fall outside every window. The reported total is therefore the **analysis cost
of the three phases**, and a close floor on the run rather than a ceiling. Say "analysis cost" when
the distinction matters; do not inflate the measured figure to guess at the remainder.

A phase whose cost could not be measured keeps its row and the total is flagged `partial`. Never
present a partial total as the cost of the whole review.

Each audit report shows its own phase's cost. The comparison report shows **all three phases and the
total** — so a reader who opens only the comparison still sees what the review cost across all
three phases, which is the figure anyone approving the next one actually needs.

If cost collection fails for a phase, that phase's report says so, the comparison keeps the row and
marks it not collected, and the total is flagged as partial. Never present a partial total as
complete, and never hold up a report over cost accounting.

---

## Portability and embedding

This skill is a folder of Markdown and static assets. It has no runtime, no package manifest and
nothing to install. To use it in another project, copy three folders into that project's
`.claude/skills/` (or `~/.claude/skills/` for every project on the machine):

```
security-audit/
security-audit-compare/
security-code-review/
```

Keep them siblings. `security-audit-compare` reuses `security-audit`'s cost collectors and pricing
table by relative path — one pricing table, one implementation, no drift between two sets of numbers
that have to agree.

For a UI or CI caller, pass every input and `--yes` so nothing is asked, grant both source trees
with `--add-dir` (see [Directory access](#directory-access)), and read the exit summary plus
`run.json` for machine-readable results. The reports are self-contained HTML: no server, no
CDN, no network. They can be attached to an email, committed, or served as static files unchanged.

---

## Rules of engagement

- **Ask, then confirm, then spend.** Never start an audit on an unvalidated path.
- **Prove you can read the tree before you audit it.** An unreadable directory and an empty one look
  the same in a report and could not be more different. If reads are denied, stop and say which path
  and why — a clean-looking report on a tree nobody opened is the worst thing this skill can emit.
- **Prove you can write the output folder before you spend.** Create the project folder at Step 3,
  before Phase A rather than after it. If that write is denied, stop there — the alternative is
  paying for three phases of analysis that have nowhere to land.
- **Legacy gets no remediation.** That is a deliberate product decision, not an oversight, and the
  Legacy report says so in its Limitations.
- **Never fabricate the skipped phase.** No legacy path means no Legacy report and no Comparison
  report. Do not synthesize a comparison against an imagined legacy baseline — say the run produced
  the Modernized report only, and why.
- **Same depth on both sides.** A `deep` legacy audit compared against a `quick` modernized one
  produces bucket counts that reflect the effort spent, not the codebases. The comparison skill
  degrades to `partial` when it sees mismatched depth; do not put it in that position.
- **Report the total honestly.** If any phase's cost was estimated or uncollected, the total says so.
- **Read-only.** This flow audits and reports. It never edits either codebase.
