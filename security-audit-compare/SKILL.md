---
name: security-audit-compare
description: Compare two completed security audits - a legacy codebase and its modernized replacement - and emit a self-contained HTML comparison report showing which vulnerabilities the migration resolved, which it carried across, and which it introduced, with remediation guidance for the modernized code and the token/dollar cost of the whole review. Use after auditing both sides of a migration, or when the user asks what a modernization did to their security posture.
---

# Migration Security Comparison

Take two `findings.json` files produced by the `security-audit` skill — one for a legacy codebase,
one for its modernized replacement — and answer the question a delivery team actually has:
**what did the migration do to our security posture?**

The answer has four parts, and the report is built around them:

| Bucket | The question it answers |
|---|---|
| **Resolved** | What did the migration fix? (and what merely disappeared with unmigrated code) |
| **Inherited** | What did we carry across without noticing? |
| **Introduced** | What did the migration break that used to work? |
| **New surface** | What risks come with the new architecture that could not exist before? |

**Zero installs. Never ask the user to install anything.** This skill reads two JSON files, writes
one JSON file, and concatenates three files into an HTML report. It needs a shell and nothing else.

---

## Invocation

```
/security-audit-compare --legacy <findings.json> --modernized <findings.json> [options]
```

| Option | Default | Meaning |
|---|---|---|
| `--legacy <path>` | *(required)* | The legacy audit's `findings.json`. |
| `--modernized <path>` | *(required)* | The modernized audit's `findings.json`. |
| `--name "<Project>"` | from the audits' `meta.projectName` | Project name for the title and filename. |
| `--out <dir>` | the modernized audit's report directory | Where the HTML report is written. |
| `--cost <dir>[,<dir>…]` | none | Phase `cost.json` files to roll into the cost section, in order. |
| `--no-cost` | off | Skip cost accounting entirely. |

Both inputs are required. **Do not run this skill against one audit and infer the other side** —
the entire output is a claim about two codebases, and half the evidence produces confident fiction.
If only one audit exists, say so and stop.

Normally you are invoked by `security-code-review`, which passes all of this. Run
standalone only when both audits already exist on disk.

---

## Preconditions — check these before doing any work

1. **Both files exist and parse as JSON.** If either fails, stop and say which one. Do not attempt a
   partial comparison from a damaged input.
2. **Both are `security-audit` outputs**, carrying `meta`, `scores` and `findings`. A file that is
   not one of ours is not something to guess at.
3. **Same scoring profile.** `scores.profile` must match on both sides. If it does not, the category
   numbers are not comparable — stop and say which audit needs re-running. Do not rescale by hand.
4. **Sanity-check the pairing.** `meta.projectName` will often differ between the two runs
   (`AcmeBilling` vs `AcmeBilling-Modern`); that is fine. But if the two audits are plainly of
   unrelated systems, ask rather than proceed.

Record the answers in the report's methodology section.

---

## Procedure

### Step 0 — Start the cost watermark

This skill reuses the `security-audit` skill's cost collectors rather than shipping a second copy —
one pricing table, one implementation, no drift between two sets of numbers that must agree.

```bash
SA=<path to the security-audit skill>
PY=$(bash "$SA/bin/ensure_python.sh" --quiet) && "$PY" "$SA/bin/cost.py" --mark --out <out>/.security-audit/comparison \
  || bash "$SA/bin/collect-cost.sh" --mark --out <out>/.security-audit/comparison
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SA\bin\collect-cost.ps1" -Mark -Out "<out>\.security-audit\comparison"
```

If the `security-audit` skill is not installed alongside this one, skip cost collection for the
comparison phase, still render the phases you were handed via `--cost`, and mark this phase
`"note": "not collected"`. Never block the comparison on cost accounting.

### Step 1 — Load and inventory both audits

Read both `findings.json` files in full. For each side record: project name, target path, stack,
depth, mode, finding count, `scores.current`, and every `scores.categories[]` entry.

Note which categories each side marked `assessed: false`. You will need this in Step 3 — you cannot
call a modernized finding a regression if the legacy audit never looked at that category.

### Step 2 — Build the functional area map

Follow `references/matching-protocol.md` §1. **Do this before classifying anything.** Name areas in
business terms and map each to paths on both sides.

This step is the one that makes the comparison meaningful, and it is the one with no shortcut: you
are reading two codebases' worth of finding locations and working out what the software does. Budget
real effort here. Everything downstream inherits its quality.

Write the map to `<out>/.security-audit/comparison/functional-areas.json`.

If you cannot build a credible map, set `meta.comparisonDepth` to `category-only` and skip to Step 5
— compare category scores and counts, emit no per-finding buckets, and say plainly in the report why.

### Step 3 — Pair and classify

Follow `references/matching-protocol.md` §§2–6 in full:

- pair on **weakness class + functional area**, never on file path;
- assign a `match.confidence` of `Certain` / `Probable` / `Tentative` to every pair, and reject
  anything weaker, leaving both findings unpaired;
- bucket every item as `inherited` / `introduced` / `new-surface` / `resolved` / `not-comparable`;
- before calling anything `introduced`, confirm the legacy audit **assessed** that category;
- interrogate every `resolved` item against §5 — fixed, or merely not migrated?

Each `feature-not-migrated` item also becomes a `coverageRisks[]` entry. This is the part of the
report a delivery lead needs most and is least likely to already know.

Write the classified set to `<out>/.security-audit/comparison/pairings.json` as your working record.

### Step 4 — Compose the per-item narrative

For every item, write `migrationNote`: one short paragraph on what the migration did or failed to do
here. Concrete and specific — name the construct that was ported, the control that was dropped, the
framework behaviour that removed the flaw.

Carry `remediation` and `verification` across from the modernized audit's finding **verbatim**. That
audit already did this work in `plan` mode; rewriting it produces two differently-worded fixes for
one defect across two reports in the same folder, and the reader has to work out whether they differ
on purpose. If the modernized audit ran in `analyze` mode and has no remediation, write it now using
`../security-audit/references/remediation-playbook.md`, and say in Limitations that remediation was
authored during the comparison rather than the audit.

Never attach remediation to a `resolved` item.

### Step 5 — Scores

Copy `scores.current` from each audit into `scores.legacy` and `scores.modernized`, and the
modernized audit's `scores.projected` into `scores.projected`. Build `categories[]` by joining the
two audits' category arrays on `key`, keeping `null` for either side's unassessed categories.

**Do not recompute either score.** Each audit already applied `scoring.md`; recomputing here would
produce a third number that agrees with neither report in the same folder.

The headline delta is `modernized.score - legacy.score`. Be careful with what you claim it means —
the two systems usually differ in exposure, and a private-network terminal application and a public
web application are not scored against the same threat model even when the arithmetic is identical.
Put that caveat in `meta.scoreCaveat` whenever the exposure differs, and let it render.

### Step 6 — Write the verdict

One paragraph, in `meta.verdict`, that a reader who reads nothing else takes away. Write it **after**
the buckets are settled, never before. It must reflect what the evidence shows — including when the
migration clearly improved things, which happens and should be said plainly.

A good verdict names the single most important movement in each direction and gives the net. A bad
one hedges so thoroughly that it commits to nothing.

### Step 7 — Write the comparison document

Write `<out>/.security-audit/comparison/comparison.json` per `references/comparison-schema.md`,
with the cost block left as an **empty placeholder**:

```json
  "cost": {},
```

It is filled in mechanically two steps from now. This document is written *before* cost is
collected so that writing it lands inside the measured window — collecting cost first left the
largest output of the phase outside the meter.

### Step 8 — Close the watermark and roll up cost

```bash
"$PY" "$SA/bin/cost.py" --report --out <out>/.security-audit/comparison \
  || bash "$SA/bin/collect-cost.sh" --report --out <out>/.security-audit/comparison
```

**A measured figure is only ever produced from a watermark that still resolves.** If the collector
writes `"source": "unavailable"`, read its `reason`; never edit that into a confident number.

Then roll the three phases into one cost block. Do this with the helper rather than by hand —
transcribing `byModel[]` rows costs output tokens after the meter has stopped, and a slip silently
changes a number the reader is being asked to trust:

```bash
"$PY" "$SA/bin/rollup-cost.py" --out <out>/.security-audit/comparison/cost-rollup.json \
  --phase "Legacy audit=<out>/.security-audit/legacy/cost.json" \
  --phase "Modernized audit=<out>/.security-audit/modernized/cost.json" \
  --phase "Comparison=<out>/.security-audit/comparison/cost.json"
```

It keeps a row for every phase — a phase it could not read stays visible as `"not collected"`
rather than vanishing — degrades the whole block to `estimate` if any phase was estimated, and sets
`"partial": true` with an explicit note when a phase is missing. **Never present a partial total as
the cost of the whole review.**

If the `security-audit` skill is not installed alongside this one, skip the rollup, render the
phases you were handed via `--cost`, and mark the comparison phase `"not collected"`.

### Step 9 — Merge the cost block and render

1. Splice the rolled-up cost into the comparison document. Deterministic text work, so it is safe
   to run after the meter has stopped:

   ```bash
   "$PY" "$SA/bin/merge-cost.py" \
     --findings <out>/.security-audit/comparison/comparison.json \
     --cost <out>/.security-audit/comparison/cost-rollup.json
   ```


2. Concatenate:

   ```bash
   cat "<skill>/assets/compare.part1.html" \
       "<out>/.security-audit/comparison/comparison.json" \
       "<skill>/assets/compare.part2.html" \
       > "<out>/<Project> - Comparison - Security analysis report. - YYYY-MM-DD.html"
   ```

   ```powershell
   Get-Content "<skill>\assets\compare.part1.html","<out>\.security-audit\comparison\comparison.json","<skill>\assets\compare.part2.html" -Raw |
     Set-Content "<out>\<Project> - Comparison - Security analysis report. - YYYY-MM-DD.html" -Encoding utf8
   ```

3. **Filename is exact:**
   `<Project name> - Comparison - Security analysis report. - <YYYY-MM-DD>.html`
   matching the Legacy and Modernized reports it sits beside. Strip only characters illegal in
   filenames (`\ / : * ? " < > |`).

4. Verify: the file is non-trivial in size and the JSON you injected parses. A comparison that
   renders a blank page is worse than none.

### Step 10 — Report back

Score movement, bucket counts, the verdict in one line, the report path, and the total measured cost
across all phases. Call out the `introduced` count and any coverage risks explicitly — those are the
two things a reader must not miss. Do not paste the report into the terminal.

---

## Rules of engagement

- **Two audits or nothing.** Never infer the missing side.
- **Never re-score.** The audits own their numbers; this report joins them.
- **Match confidence is published.** Every pairing shows its confidence in the report. A `Tentative`
  badge is a feature — it tells a reviewer exactly where to check your work.
- **`resolved` is not automatically good news.** Run the §5 interrogation on every one. A
  vulnerability that vanished with an unmigrated feature is an open item, not an achievement.
- **`introduced` is an accusation.** Hold it to the highest evidence bar in the report. If the
  legacy audit did not assess the category, you do not have the evidence — use `new-surface` or
  leave it unclassified and say why.
- **No invented identifiers.** CWE / ATT&CK / CVE numbers come from the source audits. Do not add
  new ones during comparison.
- **Report what you could not compare.** Unmapped functional areas, `category-only` degradation,
  rejected pairings, unassessed categories on either side — all belong in Limitations.
- **Read-only.** This skill reads two audits and writes one report. It never edits either codebase.

---

## Files in this skill

```
SKILL.md                              this file
references/matching-protocol.md       how findings are paired and bucketed - read it in full
references/comparison-schema.md       the comparison.json contract the template renders
assets/compare.part1.html             report template, head half (shared stylesheet + comparison styles)
assets/compare.part2.html             report template, tail half (the renderer)
examples/comparison.example.json      a worked comparison.json
```

Cost collection reuses `../security-audit/bin/` — `cost.py`, `collect-cost.sh`, `collect-cost.ps1`,
`ensure_python.*` and `assets/pricing.json`. That is deliberate: two copies of a pricing table drift,
and the moment they do, the per-phase figures in this report stop adding up against the per-run
figures in the other two. If `security-audit` is not installed alongside, this skill still produces
its report with the cost section marked not collected.
