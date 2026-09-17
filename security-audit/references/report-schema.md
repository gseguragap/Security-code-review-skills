# findings.json — the report contract

`assets/report.part1.html` + `findings.json` + `assets/report.part2.html` concatenate into the final
report. The template does all rendering, so **this JSON is the only thing you author**.

Two hard rules:

1. **It must be valid JSON.** The whole report is blank if it is not. No trailing commas, no comments,
   no unescaped control characters. Newlines inside strings must be `\n`; literal quotes `\"`.
2. **It must be a single JSON object** — the template reads it from a `<script type="application/json">`
   block. Do not wrap it in an array or prepend anything.

The template degrades gracefully: optional fields that are absent are simply not rendered. Only
`meta`, `scores` and `findings` are required.

---

## Top-level shape

```json
{
  "schemaVersion": "1.0",
  "meta":       { ... },
  "scores":     { ... },
  "findings":   [ ... ],
  "strengths":  [ ... ],
  "roadmap":    [ ... ],
  "evidenceLog":[ ... ],
  "cost":       { ... },
  "limitations":[ ... ]
}
```

---

## `meta`

```json
"meta": {
  "projectName": "Informix-demo-3",
  "targetPath": "Test/Demo-3/Informix-demo-3",
  "scanDate": "2026-09-09",
  "analyst": "Claude Code - security-audit skill v1.0",
  "depth": "standard",
  "mode": "plan",
  "variant": "modernized",
  "variantLabel": "Modernized",
  "standards": [
    "OWASP Top 10 (2021)",
    "CWE",
    "MITRE ATT&CK v16",
    "NIST SP 800-218 (SSDF v1.1)",
    "NIST SP 800-53 Rev. 5"
  ],
  "stack": {
    "languages": ["C#", "Razor"],
    "frameworks": [".NET 10", "Blazor Server", "EF Core", "MudBlazor"],
    "dataStores": ["SQLite"],
    "entryPoints": ["Program.cs", "Pages/*.razor"]
  },
  "inventory": {
    "filesScanned": 148,
    "linesScanned": 21430,
    "filesSkipped": 2104,
    "skipReasons": ["node_modules", "bin/obj build output", "binary assets"]
  },
  "migration": {
    "isMigration": true,
    "sourceLanguage": "Informix 4GL",
    "targetLanguage": "C# / Blazor Server",
    "sourcePathAudited": null
  }
}
```

`migration` is optional — include it only for a modernization audit. `sourcePathAudited` is `null`
when only the generated output was in scope; say so, because it limits the origin classification.

`variant` is `standalone` | `legacy` | `modernized`, and `variantLabel` is the display string
(`Legacy` / `Modernized`). Both are optional and omitted for a standalone audit. When present the
template puts the label in the `<h1>`, the browser tab and a `Codebase` row in the meta grid.

### What `--mode analyze` omits

An `analyze` run must leave these out of the JSON entirely — not empty, not null, **absent**:
`findings[].remediation`, `findings[].verification`, `roadmap`, `scores.projected`, and every
`categories[].projected`. The template renders no remediation UI, no uplift tile and no roadmap
section when they are missing, which is exactly the intended output.

---

## `scores`

```json
"scores": {
  "profile": "default-v1",
  "current":   { "score": 53, "grade": "D-", "posture": "At Risk" },
  "projected": { "score": 90, "grade": "A-", "posture": "Hardened" },
  "categories": [
    {
      "key": "access-control",
      "name": "Access Control",
      "owasp": "A01",
      "weight": 22,
      "current": 10,
      "projected": 90,
      "assessed": true,
      "note": "No authN/authZ anywhere; all CRUD reachable anonymously; IDOR on record routes."
    },
    {
      "key": "dependencies",
      "name": "Vulnerable & Outdated Components",
      "owasp": "A06",
      "weight": 5,
      "current": null,
      "projected": null,
      "assessed": false,
      "note": "Not assessed - no advisory source was reachable. Inventory captured only."
    }
  ]
}
```

Omit `projected` entirely when `mode` is `analyze`. Set `assessed: false` and `current: null` for
categories you did not evaluate — the template renders those as "Not assessed" and excludes them
from the chart, which is the honest presentation.

---

## `findings[]`

```json
{
  "id": "S-1",
  "title": "No authentication or authorization anywhere in the application",
  "severity": "Critical",
  "confidence": "Confirmed",
  "category": "access-control",
  "owasp": "A01:2021 Broken Access Control",
  "owaspCurrent": null,
  "cwe": ["CWE-862", "CWE-306"],
  "attack": [{ "id": "T1190", "name": "Exploit Public-Facing Application" }],
  "nist": { "ssdf": ["PW.5", "PW.9"], "sp80053": ["AC-3", "IA-2"] },
  "origin": "migration-exposed",
  "status": "new",
  "locations": [
    { "file": "Program.cs", "line": 1, "excerpt": "// no AddAuthentication / UseAuthorization" },
    { "file": "Pages/Customers.razor", "line": 1, "excerpt": "@page \"/customers\"" }
  ],
  "evidence": "0 [Authorize] attributes across 148 files. No AddAuthentication, AddAuthorization, UseAuthentication or UseAuthorization in Program.cs. MapBlazorHub() is mapped without RequireAuthorization().",
  "risk": "Any anonymous visitor who can reach the URL can read and modify every customer, order and stock record, and can open a SignalR circuit to invoke server-side component logic.",
  "impact": { "confidentiality": "High", "integrity": "High", "availability": "Low" },
  "exposure": "internet-facing",
  "discovered": true,
  "remediated": false,
  "remediation": {
    "summary": "Register an identity provider and apply a global default-deny authorization policy.",
    "nonBreaking": true,
    "breakingChange": false,
    "effort": "M",
    "planned": true,
    "steps": [
      "Add AddAuthentication().AddOpenIdConnect(...) plus AddAuthorization(), and call UseAuthentication()/UseAuthorization() before UseAntiforgery().",
      "Set a global fallback policy with AddAuthorizationBuilder().SetFallbackPolicy(RequireAuthenticatedUser()) so every page requires sign-in by default - no per-page edits.",
      "Mark login, health and error endpoints [AllowAnonymous].",
      "Protect the circuit: MapBlazorHub().RequireAuthorization()."
    ],
    "codeBefore": "app.MapBlazorHub();\napp.MapFallbackToPage(\"/_Host\");",
    "codeAfter": "app.UseAuthentication();\napp.UseAuthorization();\napp.MapBlazorHub().RequireAuthorization();\napp.MapFallbackToPage(\"/_Host\");",
    "language": "csharp"
  },
  "verification": "An unauthenticated GET /customers returns 302 to the sign-in endpoint. After signing in, the page renders exactly as it does today. dotnet build reports 0 errors.",
  "references": [
    { "label": "OWASP A01:2021", "url": "https://owasp.org/Top10/A01_2021-Broken_Access_Control/" }
  ]
}
```

### Field notes

| Field | Required | Values / rules |
|---|---|---|
| `id` | yes | `S-1`, `S-2`, … stable within a run |
| `severity` | yes | `Critical` \| `High` \| `Medium` \| `Low` \| `Info` |
| `confidence` | yes | `Confirmed` \| `Likely` \| `Possible` |
| `category` | yes | a `key` from `scores.categories` |
| `owaspCurrent` | no | the current-edition category, only if you actually verified it |
| `cwe`, `attack`, `nist` | no | **omit rather than guess** |
| `origin` | no | `legacy-inherited` \| `migration-introduced` \| `migration-exposed` \| `new-surface` |
| `status` | no | `new` \| `persisting` \| `resolved` — only with `--baseline` |
| `locations[]` | yes | at least one; paths **relative to ROOT** |
| `exposure` | no | `internet-facing` \| `internal` \| `local-only` \| `unknown` |
| `remediated` | yes | always `false` on a fresh analysis run |
| `remediation.effort` | no | `S` (< 1 day) \| `M` (1–3 days) \| `L` (> 3 days) |
| `remediation.planned` | no | `false` excludes it from the projected score |
| `codeBefore` / `codeAfter` | no | rendered as a diff; keep short and real |
| `language` | no | hint for syntax highlighting (`csharp`, `java`, `javascript`, `python`, `sql`, `bash`, `yaml`, …) |

---

## `strengths[]`

```json
"strengths": [
  { "title": "Parameterized data access throughout", "detail": "EF Core LINQ only; zero FromSqlRaw or string-concatenated SQL across 148 files.", "category": "injection" },
  { "title": "No XSS sinks", "detail": "Zero MarkupString or Html.Raw usages; Blazor's automatic encoding is intact.", "category": "xss" }
]
```

These justify the category scores. A report with none looks like it only went looking for problems.

---

## `roadmap[]`

```json
"roadmap": [
  { "phase": 1, "name": "Access control", "findings": ["S-1", "S-2", "S-3"], "effort": "M",
    "scoreAfter": 78,
    "rationale": "Largest single risk reduction. S-1 subsumes S-2 and S-3 once the fallback policy is in place." }
]
```

---

## `evidenceLog[]`

The audit trail — what was checked, so a reader can tell assessed-and-clean from not-assessed.

```json
"evidenceLog": [
  { "check": "Authorization attributes", "ruleId": "DN-AUTHZ-01", "method": "grep",
    "query": "\\[Authorize", "result": "0 matches across 148 files", "conclusion": "Finding S-1" },
  { "check": "Raw SQL execution", "ruleId": "DN-INJ-01", "method": "grep",
    "query": "FromSqlRaw|ExecuteSqlRaw", "result": "0 matches", "conclusion": "No injection sink; strength recorded" }
]
```

---

## `cost`

Paste `cost.json` from `bin/collect-cost.sh` here directly — the shapes match.

```json
"cost": {
  "source": "transcript",
  "startedAt": "2026-09-09T14:02:11Z",
  "finishedAt": "2026-09-09T14:19:48Z",
  "byModel": [
    { "model": "claude-opus-5", "priced": true, "messages": 42,
      "tokens": { "input": 1820, "cacheWrite5m": 96400, "cacheWrite1h": 0, "cacheRead": 1840220, "output": 58310, "total": 1996750 },
      "rates":  { "input": 5.00, "cacheWrite5m": 6.25, "cacheWrite1h": 10.00, "cacheRead": 0.50, "output": 25.00 },
      "costUSD":{ "input": 0.0091, "cacheWrite5m": 0.6025, "cacheWrite1h": 0.0, "cacheRead": 0.9201, "output": 1.4578, "total": 2.9895 } }
  ],
  "totals": { "totalTokens": 1996750, "totalCostUSD": 2.9895 },
  "unpricedModels": 0,
  "pricingVersion": "2026-06-24",
  "note": "Measured from the session transcript..."
}
```

`source` must be one of:

| Value | Meaning | Template behaviour |
|---|---|---|
| `transcript` | Measured from real usage records | Shows the figures plainly |
| `estimate` | You estimated it; measurement failed | Renders a visible "estimated" caveat |
| `unavailable` | Not measured at all | Renders "not collected" — **no numbers** |

Never label an estimate as measured. The cost section's whole value is that a reader can trust it.

---

## `limitations[]`

```json
"limitations": [
  "Static analysis only. No application was built, deployed or exercised at runtime.",
  "Dependency advisories were NOT verified against a live vulnerability database; dependency findings reflect inventory and policy only.",
  "Infrastructure, network policy, WAF rules and deployed secrets were out of scope - only files under the target path were examined.",
  "Business-logic correctness was assessed only where intent was inferable from the code.",
  "2,104 files were skipped as build output, vendored dependencies or binary assets."
]
```

Write these honestly and completely. This section is what separates a security report from a
marketing document, and an experienced reader checks it first.
