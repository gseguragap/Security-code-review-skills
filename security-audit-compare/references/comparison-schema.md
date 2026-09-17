# comparison.json — the report contract

`assets/compare.part1.html` + `comparison.json` + `assets/compare.part2.html` concatenate into the
final comparison report. The template does all rendering, so **this JSON is the only thing you
author**.

Two hard rules, identical to the audit schema:

1. **It must be valid JSON.** The whole report renders a single error card if it is not. No trailing
   commas, no comments. Newlines inside strings are `\n`; quotes are `\"`.
2. **It must be a single JSON object.** The template reads it from a
   `<script type="application/json">` block.

Optional fields that are absent are simply not rendered — the template degrades gracefully. Only
`meta`, `scores` and `items` are required.

---

## Top-level shape

```json
{
  "schemaVersion":   "1.0",
  "meta":            { ... },
  "scores":          { ... },
  "functionalAreas": [ ... ],
  "items":           [ ... ],
  "coverageRisks":   [ ... ],
  "roadmap":         [ ... ],
  "cost":            { ... },
  "methodology":     [ ... ],
  "limitations":     [ ... ]
}
```

---

## `meta`

```json
"meta": {
  "projectName": "AcmeBilling",
  "scanDate": "2026-09-11",
  "analyst": "Claude Code - security-audit-compare skill v1.0",
  "depth": "standard",
  "comparisonDepth": "full",
  "comparedCount": 23,
  "subtitle": "Informix 4GL to .NET 10 / Blazor Server - migration security comparison",
  "verdict": "The migration removed the legacy system's SQL injection surface wholesale by moving to EF Core, but it did not carry over the operator sign-on control: the modernized application has no authentication at all, and every record the legacy system protected behind a terminal login is now reachable anonymously. Net posture is worse despite 9 resolved findings.",
  "scoreCaveat": "Legacy and modernized scores use the same profile and weights, but not the same exposure assumptions - the legacy system was reachable only from a private network. Compare the category movement rather than the headline numbers alone.",
  "legacy": {
    "targetPath": "C:/src/acme/legacy",
    "stack": "Informix 4GL, ESQL/C",
    "reportFile": "AcmeBilling - Legacy - Security analysis report. - 2026-09-11.html",
    "findingsCount": 14,
    "mode": "analyze",
    "depth": "standard"
  },
  "modernized": {
    "targetPath": "C:/src/acme/modern",
    "stack": ".NET 10, Blazor Server, EF Core",
    "reportFile": "AcmeBilling - Modernized - Security analysis report. - 2026-09-11.html",
    "findingsCount": 17,
    "mode": "plan",
    "depth": "standard"
  }
}
```

`verdict` is the one paragraph a reader who reads nothing else must come away with. Write it last,
after the buckets are settled, and make it say what actually happened — including when the honest
answer is that the migration improved things.

`comparisonDepth` is `full` | `partial` | `category-only`, per `matching-protocol.md` §7.

---

## `scores`

```json
"scores": {
  "profile": "default-v1",
  "legacy":     { "score": 41, "grade": "F",  "posture": "Critical" },
  "modernized": { "score": 53, "grade": "F",  "posture": "Critical" },
  "projected":  { "score": 90, "grade": "A-", "posture": "Hardened" },
  "categories": [
    {
      "key": "access-control", "name": "Access Control", "owasp": "A01", "weight": 22,
      "legacy": 55, "modernized": 10,
      "note": "The legacy terminal sign-on was not reproduced; the web application has no authN/authZ at all."
    },
    {
      "key": "injection", "name": "Injection", "owasp": "A03", "weight": 14,
      "legacy": 10, "modernized": 100,
      "note": "Every hand-built SQL statement became an EF Core LINQ query. Injection surface eliminated."
    },
    {
      "key": "dependencies", "name": "Vulnerable & Outdated Components", "owasp": "A06", "weight": 5,
      "legacy": null, "modernized": null,
      "note": "Not assessed on either side - no advisory source was reachable."
    }
  ]
}
```

- `legacy` / `modernized` / `projected` are the score objects copied from each audit's
  `scores.current` (and the modernized audit's `scores.projected`).
- `categories[].legacy` and `.modernized` are the per-category scores from each run. Use `null` for
  a category that side did not assess — the template renders `n/a` and no delta, which is the
  honest presentation. **Never substitute 0 or 100 for a null.**
- Both sides must use the same `profile`. If the two audits used different scoring profiles, re-run
  one of them; do not rescale by hand.

---

## `functionalAreas[]`

The join key from `matching-protocol.md` §1. Not rendered directly, but it is the audit trail for
every pairing decision, and a reviewer will ask for it.

```json
"functionalAreas": [
  { "name": "Customer record CRUD",
    "legacyPaths":   ["custmaint.4gl", "custlook.4gl"],
    "modernPaths":   ["Pages/Customers.razor", "Services/CustomerService.cs"],
    "counterpart": "both" },
  { "name": "Nightly batch invoicing",
    "legacyPaths":   ["invbatch.4gl"],
    "modernPaths":   [],
    "counterpart": "legacy-only",
    "note": "No scheduled-job equivalent found anywhere in the modernized tree." }
]
```

`counterpart` is `both` | `legacy-only` | `modern-only`.

---

## `items[]`

One entry per compared finding. This is the body of the report.

```json
{
  "id": "C-1",
  "bucket": "inherited",
  "title": "Customer lookup builds its WHERE clause by string concatenation",
  "severity": "Critical",
  "category": "injection",
  "functionalArea": "Customer record CRUD",
  "owasp": "A03:2021 Injection",
  "cwe": ["CWE-89"],
  "attack": [{ "id": "T1190", "name": "Exploit Public-Facing Application" }],
  "nist": { "ssdf": ["PW.5"], "sp80053": ["SI-10"] },

  "legacy": {
    "id": "L-3",
    "severity": "High",
    "confidence": "Confirmed",
    "evidence": "custlook.4gl builds the SELECT with a LET stmt = ... || cust_name concatenation before PREPARE.",
    "locations": [
      { "file": "custlook.4gl", "line": 812,
        "excerpt": "LET stmt = \"SELECT * FROM customer WHERE name LIKE '\", p_name CLIPPED, \"%'\"" }
    ]
  },
  "modernized": {
    "id": "M-5",
    "severity": "Critical",
    "confidence": "Confirmed",
    "evidence": "CustomerService.Search interpolates the search term straight into FromSqlRaw.",
    "locations": [
      { "file": "Services/CustomerService.cs", "line": 47,
        "excerpt": "FromSqlRaw($\"SELECT * FROM Customers WHERE Name LIKE '%{term}%'\")" }
    ]
  },

  "match": {
    "confidence": "Certain",
    "basis": "Same CWE-89 defect in the same customer-search routine; the 4GL concatenation was translated line for line into an interpolated C# string rather than a parameter."
  },

  "migrationNote": "The migration parameterized 11 of the 12 legacy queries by moving them to EF Core LINQ. This one was ported as raw SQL because of the LIKE wildcard, and the concatenation came with it. Severity rises from High to Critical because the endpoint is now anonymous and internet-facing rather than behind the terminal sign-on.",

  "risk": "An anonymous visitor can read, and with a stacked statement modify, any row in the billing database.",

  "remediation": {
    "summary": "Pass the search term as a parameter; the LIKE wildcards belong in the parameter value, not the SQL text.",
    "nonBreaking": true,
    "breakingChange": false,
    "effort": "S",
    "planned": true,
    "steps": [
      "Replace the interpolated FromSqlRaw with FromSqlInterpolated, which parameterizes automatically.",
      "Or use EF Core LINQ: Customers.Where(c => EF.Functions.Like(c.Name, $\"%{term}%\")).",
      "Add a length cap and a character allow-list on the search term at the page boundary."
    ],
    "codeBefore": "FromSqlRaw($\"SELECT * FROM Customers WHERE Name LIKE '%{term}%'\")",
    "codeAfter": "FromSqlInterpolated($\"SELECT * FROM Customers WHERE Name LIKE {\\\"%\\\" + term + \\\"%\\\"}\")",
    "language": "csharp"
  },
  "verification": "Search for ' OR 1=1 -- and confirm zero rows and no error. dotnet build reports 0 errors.",
  "references": [
    { "label": "OWASP A03:2021", "url": "https://owasp.org/Top10/A03_2021-Injection/" }
  ]
}
```

### Field notes

| Field | Required | Values / rules |
|---|---|---|
| `id` | yes | `C-1`, `C-2`, … stable within a run |
| `bucket` | yes | `inherited` \| `introduced` \| `new-surface` \| `resolved` \| `not-comparable` |
| `severity` | yes | the **effective** severity — see `matching-protocol.md` §6 |
| `legacy` | for `inherited`, `resolved`, `not-comparable` | omit entirely for `introduced` / `new-surface` |
| `modernized` | for `inherited`, `introduced`, `new-surface` | omit entirely for `resolved` |
| `match` | when both sides present | `confidence` is `Certain` \| `Probable` \| `Tentative` |
| `resolution` | `resolved` only | `{ "reason": …, "detail": … }`, see §5 of the protocol |
| `remediation` | actionable buckets | copy from the modernized audit; **never** attach one to a `resolved` item |
| `migrationNote` | strongly recommended | what the migration did, or failed to do, in one short paragraph |

**Locations stay relative to their own audit's ROOT.** Do not rewrite legacy paths to look like
modernized ones.

### Which items get remediation

| Bucket | Remediation |
|---|---|
| `inherited`, `introduced`, `new-surface` | **Yes** — carry it from the modernized audit's finding. If that audit ran in `plan` mode it is already written; reuse it rather than inventing a second version. |
| `resolved` | **No.** There is nothing to fix. Attaching a fix to a resolved finding is how a reader loses trust in the whole document. |
| `not-comparable` | Only if the finding exists in the modernized tree. |

---

## `coverageRisks[]`

Every `resolved` item whose `resolution.reason` is `feature-not-migrated`, grouped by functional
area. The report gives these their own section.

```json
"coverageRisks": [
  {
    "area": "Operator sign-on",
    "why": "signon.4gl authenticated operators against the OPERATOR table before any screen opened. No equivalent exists anywhere in the modernized tree - there is no login page, no identity provider registration and no session concept.",
    "findings": ["C-12", "C-13"],
    "recommendation": "Two legacy findings (weak password hashing, no lockout) disappear with this code, but so does the control itself. Treat sign-on as an open migration item, not a resolved risk, and design the replacement before the application is exposed."
  }
]
```

`findings[]` are `items[].id` values — the template links them.

---

## `roadmap[]`

Same shape as the audit report's roadmap, scoped to the modernized codebase. Order by risk reduction
per unit of effort, and include the `inherited` items — they are the ones a team is most likely to
assume were dealt with by the rewrite.

```json
"roadmap": [
  { "phase": 1, "name": "Restore access control", "findings": ["C-2", "C-3", "C-12"],
    "effort": "M", "scoreAfter": 78,
    "rationale": "The single largest regression. Also closes the sign-on coverage gap." }
]
```

---

## `cost`

Unlike the audit schema, this block covers **every phase of the run**, so the reader sees what the
whole review cost rather than just this report.

```json
"cost": {
  "source": "transcript",
  "phases": [
    { "name": "Legacy audit",     "byModel": [ ... ], "subtotalTokens": 1840220, "subtotalCostUSD": 2.9895 },
    { "name": "Modernized audit", "byModel": [ ... ], "subtotalTokens": 2110400, "subtotalCostUSD": 3.4120 },
    { "name": "Comparison",       "byModel": [ ... ], "subtotalTokens":  640300, "subtotalCostUSD": 1.0044 }
  ],
  "totals": { "totalTokens": 4590920, "totalCostUSD": 7.4059 },
  "pricingVersion": "2026-06-24",
  "note": "Measured from the session transcript, segmented per phase by watermark. Assistant messages are deduplicated by message id. Dollar figures use list rates and exclude any enterprise or Batch API discount."
}
```

Each phase's `byModel[]` is copied verbatim from that phase's `cost.json` — the shapes match
exactly. A phase that could not be measured keeps its name and carries
`"byModel": [], "note": "not collected"`; the template renders the row greyed rather than dropping
it, so a missing phase is visible instead of silently absent.

`source` follows the audit contract: `transcript` | `estimate` | `unavailable`. If **any** phase was
estimated, the whole block is `estimate` and the template shows the caveat. Do not present a mixed
measurement as fully measured.

---

## `methodology[]`

Plain paragraphs, rendered in order. Say how pairing was done, so the reader can judge it:

```json
"methodology": [
  "Both codebases were audited independently with the security-audit skill at standard depth, using the default-v1 scoring profile, before any comparison was attempted.",
  "Findings were paired on weakness class (primary CWE) plus functional area, never on file path - the two trees share no layout. The functional area map was built from both inventories before classification began.",
  "Each pairing carries a match confidence. Pairings weaker than Tentative were rejected and both findings left unpaired.",
  "Modernized-only findings were split into regressions (the legacy system occupied the same ground and was clean) and new surface (the weakness class could not arise in the legacy architecture)."
]
```

---

## `limitations[]`

Everything from both audits' limitations that still applies, plus the comparison's own. At minimum:

```json
"limitations": [
  "Static analysis only. Neither application was built, deployed or exercised at runtime.",
  "Findings were paired by a model reading both codebases, not by a mechanical identity. 3 pairings are marked Tentative and should be confirmed by someone who knows the systems.",
  "The legacy audit ran in analyze mode and produced no remediation guidance by design; remediation in this report applies to the modernized codebase only.",
  "Exposure differs between the two systems - the legacy application was reachable only from a private network - so equal severities do not imply equal risk.",
  "Dependency advisories were not verified against a live vulnerability database on either side.",
  "2 legacy functional areas could not be mapped to the modernized tree and their findings are filed as not-comparable."
]
```
