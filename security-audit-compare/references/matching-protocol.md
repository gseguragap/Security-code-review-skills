# Matching protocol

Comparing two security audits is not a diff. The two codebases are in different languages, with
different file layouts, different frameworks and often different architecture. **Nothing joins on
file path.** A finding in `custorder.4gl:812` and a finding in `Services/OrderService.cs:47` may be
the same vulnerability, and there is no mechanical way to know it.

This file is how you decide. Follow it in order. The output of a sloppy match is a report that tells
a delivery team the migration introduced a flaw it did not introduce, or cleared one it did not
clear — and both of those are worse than no comparison at all.

---

## 1. Build the functional area map first

Before looking at a single finding pair, build a map of **what the software does**, independent of
how it is written. This is the join key that survives a language change.

Work from both inventories and both sets of finding locations. Name areas in business terms, not
technical ones:

```
Customer record CRUD          legacy: custmaint.4gl, custlook.4gl
                              modern: Pages/Customers.razor, Services/CustomerService.cs
Order entry and posting       legacy: ordent.4gl, ordpost.4gl
                              modern: Pages/Orders.razor, Services/OrderService.cs
Nightly batch invoicing       legacy: invbatch.4gl, JCL/INVRUN
                              modern: (no counterpart found)
Operator sign-on              legacy: signon.4gl
                              modern: (no counterpart found)
Reporting / CSV export        legacy: rptgen.4gl
                              modern: Pages/Reports.razor
```

Write this map into `comparison.json` as `functionalAreas[]` **before** classifying anything. Two
things fall out of it immediately and for free:

- areas in legacy with **no** modernized counterpart → candidate **coverage risks** (§5)
- areas in modernized with **no** legacy counterpart → the surfaces where `new-surface` findings live

If you cannot construct this map with reasonable confidence, say so and drop the comparison depth to
`category-only` (§7). Do not fake a map and then match against it.

---

## 2. The match key

Two findings are the same finding when **both** hold:

1. **Same weakness class.** Primary CWE matches, or — when one side has no CWE — the scoring
   category plus the concrete sink type match (SQL concatenation ↔ SQL concatenation, not
   SQL concatenation ↔ command injection).
2. **Same functional area**, from the map in §1.

Never match across weakness classes. Two different injection CWEs in the same file are two findings,
not one. Never match on severity, title wording, or "they feel related".

### Application-wide findings

Some findings are not attached to a functional area at all — "no authentication anywhere", "TLS
verification disabled globally", "no audit logging". Match these on weakness class alone, with
`functionalArea: "Application-wide"`. Where the legacy and modernized systems have genuinely
different trust models (a terminal app on a private network vs a public web app), say so in
`migrationNote` rather than pretending the two are equivalent controls.

---

## 3. Match confidence

Every pair carries one. It is rendered in the report, so it has to be honest.

| Confidence | Means |
|---|---|
| `Certain` | Same CWE, same functional area, and you have read both excerpts and can see it is the same defect in ported code. |
| `Probable` | Same CWE and same functional area, but the implementations diverge enough that you are reasoning about intent rather than reading the same logic twice. |
| `Tentative` | One of the two criteria is inferred rather than established — usually the functional area. Renders with a visible dotted badge. |

Anything weaker than `Tentative` is **not a match**. Leave both findings unpaired: the legacy one
becomes `not-comparable`, the modernized one is judged on its own under §4.

A `Tentative` match must state what is uncertain in `match.basis`. "Both appear to concern order
posting, but the legacy routine also performs inventory adjustment and may not be the same code
path" is a useful sentence. "Probably the same" is not.

---

## 4. Bucket classification

Once pairing is done, every item lands in exactly one bucket.

```
                    ┌─ in BOTH audits ──────────────► inherited
                    │
 finding ───────────┼─ in LEGACY only ──────────────► resolved      (then run §5)
                    │
                    └─ in MODERNIZED only ──┬─ the legacy system had this
                                            │  functional area and this
                                            │  weakness class was applicable
                                            │  there, but clean ──────────► introduced
                                            │
                                            └─ the weakness class could not
                                               exist in the legacy
                                               architecture ─────────────► new-surface
```

### `inherited`
Present before and after. The migration reproduced the flaw. This is the bucket that most often
surprises a delivery team, because the working assumption is that a rewrite leaves old defects
behind. Say plainly in `migrationNote` what was carried across — "the legacy string-built WHERE
clause was translated literally into a C# interpolated string" is the sentence that makes the point.

### `resolved`
In the legacy audit, absent from the modernized one. **Do not celebrate it yet** — run §5 first.

### `introduced`
New in the modernized codebase, on ground the legacy system also occupied. This is a regression: the
old system got this right, or the risk did not arise, and the new one does not. These carry the
highest reputational weight in the report, so the match reasoning must be airtight. Before assigning
`introduced`, confirm the legacy audit actually *assessed* that category. If the legacy category is
`assessed: false`, you cannot claim the legacy system was clean — use `new-surface` or leave the
origin unstated, and record it in Limitations.

### `new-surface`
New in the modernized codebase, on ground that did not exist before. A green-screen 4GL application
reached over a private network has no CSRF risk, no CORS policy, no session cookie flags and no
public HTTP surface. Finding those gaps in the web rewrite is not a regression — it is the cost of
the new architecture, and the report should say so in those words.

This distinction is not cosmetic. Filing every modernized-only finding under `introduced` produces a
document that reads as an indictment of the migration and gets dismissed for that reason. Separating
the two makes the genuine regressions visible, which is the entire point.

### `not-comparable`
A legacy finding whose functional area has no modernized counterpart **and** which §5 does not turn
into a coverage risk, or any finding where the other side's category was never assessed. Honest
filler — better than a forced pairing.

---

## 5. The `resolved` interrogation

For every `resolved` item, answer one question: **is it gone because it was fixed, or gone because
the code is gone?**

Set `resolution.reason` to exactly one of:

| Reason | Meaning | Report treatment |
|---|---|---|
| `fixed-by-construction` | The new framework makes the flaw structurally impossible. EF Core parameterizes; Razor auto-encodes; the ORM removed the hand-built SQL. | A real win. Credit the migration. |
| `explicitly-remediated` | Someone deliberately addressed it — a validation routine, an added check, a control that has no legacy equivalent. | A real win. Credit it and cite the control. |
| `feature-not-migrated` | The functionality carrying the flaw was not migrated. | **Not a win.** Raise a coverage risk. |
| `not-applicable` | The weakness class cannot arise in the target architecture at all (a COBOL buffer overflow in a memory-safe runtime). | Neutral. Note it; do not score it as an improvement. |

`feature-not-migrated` items go into `coverageRisks[]` as well as staying in `items[]`. The report
gives them their own section with its own explanation, because a reader skimming bucket counts will
otherwise read "12 resolved" as twelve fixes when some number of them are unmigrated features whose
vulnerabilities return the moment the feature does.

If you genuinely cannot tell which of the four applies, use `feature-not-migrated` only when the
functional area map supports it; otherwise say so in `resolution.detail` and leave `reason` out. An
absent field is honest; a confident wrong one is not.

---

## 6. Severity across the boundary

A finding's severity can legitimately differ between the two audits, because exposure differs. SQL
injection reachable only from a terminal session on a private network is not the same risk as the
same injection reachable from the public internet.

- `items[].severity` is the **effective** severity: the modernized side's, when a modernized side
  exists; the legacy side's for `resolved` items.
- Keep both original severities in `legacy.severity` and `modernized.severity` — the report shows
  them side by side, and the movement is informative.
- When they differ, explain why in `migrationNote`. "Unchanged defect, but now reachable
  unauthenticated from the internet rather than from an authenticated terminal session, so High
  becomes Critical" is exactly the kind of sentence this report exists to produce.

Never quietly average the two.

---

## 7. Degraded comparisons

State the depth in `meta.comparisonDepth`:

| Depth | When | What the report may claim |
|---|---|---|
| `full` | Both audits ran at `standard` or `deep`, and the functional area map is solid. | Everything in this document. |
| `partial` | One audit ran `quick`, or the area map has gaps. | Bucket everything you can; put unmatched findings in `not-comparable`; state which areas were unmappable. |
| `category-only` | The area map could not be built (wildly different decomposition, or a legacy tree too opaque to map). | Compare **category scores and counts only**. Do not emit per-finding buckets — an unmapped pairing is a guess wearing a badge. |

Depth is not a failure state to hide. A `partial` comparison that names its gaps is more useful than
a `full` one that invented the map, and an experienced reader checks this field early.

---

## 8. Things that are not matches

Recorded because each has been tempting in practice:

- **Same file name on both sides.** Generated code often reuses names. Name equality is evidence for
  the area map, never for a finding pair.
- **Same rule id.** Both audits ran `universal.json`; a `UNI-SEC-01` hit on each side means two
  hardcoded secrets, not the same secret.
- **Same OWASP category.** A01 covers a missing `[Authorize]` and an IDOR. Same category, different
  defects, two items.
- **Similar titles.** Both audits were written by a model that phrases things consistently. Title
  similarity is a hint to go read the excerpts, nothing more.
- **One legacy finding, several modernized ones.** If a legacy flaw fragmented across the new
  codebase, that is one `inherited` item with several `modernized.locations`, not several items.
  Conversely, several legacy findings consolidated into one modernized defect is one item whose
  `legacy.locations` lists them all — note the consolidation in `migrationNote`.
