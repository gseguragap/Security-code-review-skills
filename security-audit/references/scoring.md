# Scoring model

The score exists to make risk comparable across runs and across projects. It is only worth having if
the arithmetic is fixed, published, and reproducible. Follow this file exactly, and reproduce the
working in the report's methodology section so a reader can recompute it by hand.

---

## 1. Category weights

### Default profile (`default-v1`)

| Key | Category | OWASP | Weight |
|---|---|---:|---:|
| `access-control` | Access Control | A01 | 22 |
| `injection` | Injection (SQL/OS/LDAP/template) | A03 | 14 |
| `xss` | Cross-Site Scripting | A03 | 8 |
| `misconfiguration` | Security Misconfiguration | A05 | 13 |
| `cryptographic` | Cryptographic Failures | A02 | 10 |
| `validation` | Input Validation / Insecure Design | A04 | 9 |
| `authentication` | Authentication Failures | A07 | 8 |
| `logging` | Logging & Monitoring | A09 | 7 |
| `dependencies` | Vulnerable & Outdated Components | A06 | 5 |
| `integrity` | Software & Data Integrity | A08 | 2 |
| `ssrf` | Server-Side Request Forgery | A10 | 2 |
| | **Total** | | **100** |

### Modernizer-compatible profile (`modernizer-v1`)

Use this when the report must line up with existing Modernizer security documents.

| Category | Weight |
|---|---:|
| Access Control (A01) | 25 |
| Injection (A03) | 15 |
| XSS (A03) | 10 |
| Misconfiguration (A05) | 15 |
| Cryptographic (A02) | 10 |
| Input Validation (A04) | 10 |
| Logging/Audit (A09) | 10 |
| Vulnerable Dependencies (A06) | 5 |
| **Total** | **100** |

Under `modernizer-v1`, fold A07 into Access Control, A08 into Dependencies and A10 into
Misconfiguration, and say so in the report.

Record the profile name in `scores.profile`. **Do not invent weights per project** — a score you can
tune is a score that means nothing.

---

## 2. Category score

Every category starts at **100** and loses points per finding:

| Severity | Base penalty |
|---|---:|
| Critical | 45 |
| High | 25 |
| Medium | 12 |
| Low | 5 |
| Info | 0 |

Each penalty is multiplied by a **confidence factor**:

| Confidence | Factor |
|---|---:|
| Confirmed | 1.00 |
| Likely | 0.75 |
| Possible | 0.40 |

```
categoryScore = max(0, 100 - Σ (basePenalty × confidenceFactor))
```

Penalties accumulate across findings in the category and the result floors at 0. Two Criticals and a
High in one category is 100 − (45 + 45 + 25) = 0, which is the correct signal.

### Clean categories

| Situation | Score |
|---|---:|
| Assessed, no findings, **and** a control was positively verified present | 100 |
| Assessed, no findings, no positive control evidence | 95 |
| **Not assessed** (no rule pack applied, language unparsed, tooling unavailable) | `null` |

A `null` category is **excluded from the weighted average** and its weight is redistributed
proportionally across the assessed categories. Every `null` must be listed in the report's
Limitations section. Never score an unassessed category as 100 — that is the difference between a
report and a rubber stamp.

---

## 3. Overall score

```
overall = Σ (categoryScore × weight) / Σ (weight)      -- assessed categories only
```

Round half-up to the nearest integer.

### Grade

| Score | Grade | | Score | Grade |
|---|---|---|---|---|
| 97–100 | A+ | | 70–72 | C− |
| 93–96 | A | | 67–69 | D+ |
| 90–92 | A− | | 63–66 | D |
| 87–89 | B+ | | 60–62 | D− |
| 83–86 | B | | < 60 | F |
| 80–82 | B− | | | |
| 77–79 | C+ | | | |
| 73–76 | C | | | |

### Posture band

| Band | Condition |
|---|---|
| **Hardened** | ≥ 90 **and** zero Critical **and** zero High |
| **Adequate** | 75–89 **and** zero Critical |
| **At Risk** | 55–74, **or** any single Critical regardless of score |
| **Critical** | < 55, **or** two or more Criticals regardless of score |

The override matters: an application with one Critical finding is **At Risk** even if it scores 91.
A single unauthenticated administrative endpoint is not a "Hardened" application, and the band must
not say otherwise.

---

## 4. Projected score (`--mode plan` only)

Recompute the category scores as if every finding marked `remediation.planned = true` were fixed and
verified, then re-run the same weighted formula.

Rules:
- A finding you cannot describe a concrete fix for stays in the projected calculation at full penalty.
- A finding whose fix is `breakingChange: true` **and** unapproved stays at full penalty.
- Do not project above 95 for a category unless the remediation includes a verification step that
  actually proves the control (a test, a request, a header check).
- Label it *projected*, never *achieved*. Once fixes land and are verified, re-run the audit and
  publish the measured score.

The uplift figure is simply `projected − current`.

---

## 5. Phase scores in the roadmap

For each phase, recompute the overall score with only that phase's findings (and all earlier phases')
resolved. This gives the reader the marginal value of each phase and lets them stop when the
remaining work stops paying for itself.

---

## 6. Worked example

Two findings: one Critical in Access Control (Confirmed), one Medium in Misconfiguration (Confirmed).
Everything else assessed and clean, with control evidence for Injection and XSS. Profile `default-v1`.

```
access-control   : 100 - (45 × 1.00) = 55    weight 22 -> 1210
injection        : 100 (verified)            weight 14 -> 1400
xss              : 100 (verified)            weight  8 ->  800
misconfiguration : 100 - (12 × 1.00) = 88    weight 13 -> 1144
cryptographic    : 95                        weight 10 ->  950
validation       : 95                        weight  9 ->  855
authentication   : 95                        weight  8 ->  760
logging          : 95                        weight  7 ->  665
dependencies     : null (not assessed - no advisory source available)
integrity        : 95                        weight  2 ->  190
ssrf             : 95                        weight  2 ->  190

assessed weight  = 100 - 5 = 95
weighted sum     = 8164
overall          = 8164 / 95 = 85.9 -> 86
grade            = B
posture          = At Risk   (score would give "Adequate", but one Critical forces At Risk)
```

Note how the unassessed `dependencies` category is removed from the denominator rather than being
scored as either 0 or 100, and how the posture override fires. Both behaviours are deliberate.
