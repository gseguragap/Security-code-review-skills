# Triage protocol

The deterministic pass produces *candidates*. This file turns candidates into findings.

The failure mode of every automated security tool is the same: a wall of pattern matches, most of
them wrong, which the engineer learns to ignore. A report of 12 real findings is worth more than a
report of 200 candidates, and it is the only kind anyone acts on. **Precision is the product.**

---

## 1. The rule for every candidate

> A grep hit is a hypothesis about the code. Read the code and decide.

Concretely, for each candidate:

### Step A — Read the context

`Read` the file around the hit — enough to see the whole function or handler, not the matched line.
If the value comes from a parameter, follow it to the caller. If it goes into a sink, follow it to
the sink.

You cannot triage what you have not read. If you find yourself writing "appears to" or "may be", you
have not read enough yet, or the finding belongs at `Possible` confidence with the open question
stated.

### Step B — Establish reachability

Ask, in order:

1. **Is there a source?** Does untrusted data actually reach this code? Untrusted means: HTTP request
   (path, query, body, header, cookie), uploaded file, message queue, third-party API response,
   database content that was itself user-supplied, CLI arguments in a multi-user context, and
   environment in a shared-tenant deployment.
2. **Is there a path?** Can the source reach the sink without passing a control that neutralizes it?
3. **Is there a sink?** Does the dangerous operation actually execute, or is the string logged,
   returned as documentation, or dead code?

No source, no path, or no sink → **not a finding.** Say nothing about it, or note it in the evidence
appendix as a checked-and-cleared pattern if it is the sort of thing a reader would expect you to
have flagged.

### Step C — Look for the mitigating control

Before reporting, actively look for the thing that would close the finding. This is the step most
tools skip and it is where most of the false positives die:

| Candidate | Look for |
|---|---|
| Raw SQL | Parameter binding, an interpolated-but-parameterizing API (`FromSqlInterpolated`, `sql` tagged templates), an allow-listed identifier |
| XSS sink | A sanitizer immediately upstream, a literal value, framework auto-encoding |
| Missing authorization on an endpoint | A global fallback policy, a filter/middleware, a gateway, a base-class attribute |
| Path from input | Canonicalization plus a prefix check, an id resolved through a database lookup |
| Weak hash | Whether the use is password storage, a signature, or a non-security checksum |
| Missing header | A reverse proxy, CDN or ingress that sets it |
| SSRF | A host allow-list, a fixed base URL with only the path variable |
| Deserialization | A type filter, `safe_load`, a schema-validated format |

If the control exists, the candidate is closed. If the control exists but is weak or bypassable, that
is a *different, usually lower-severity* finding — describe the actual weakness, not the original
pattern.

### Step D — Assign confidence honestly

| Confidence | Means | Use when |
|---|---|---|
| **Confirmed** | You read the code and the flaw is present and reachable | You can quote the source, the path and the sink |
| **Likely** | Strong evidence, one assumption you could not verify from the code | e.g. an endpoint has no authorization and you found no global policy, but a gateway might exist |
| **Possible** | Needs a human to confirm | Requires runtime, infrastructure or business knowledge you do not have |

Then:
- `Possible` findings must state the specific question a human needs to answer.
- Anything below `Possible` is not reported. Delete it.
- **Never promote confidence to make a finding sound stronger.** The confidence factor feeds directly
  into the score (see `scoring.md`), so inflation corrupts the number too.

### Step E — Set severity from impact, not from the pattern

The rule pack's `severity` is a prior. Adjust it using what you now know:

| Severity | Meaning |
|---|---|
| **Critical** | Unauthenticated remote compromise, mass data exposure, or full authentication bypass. Exploitable now, by anyone who can reach the app. |
| **High** | Significant compromise requiring some precondition — an authenticated but unprivileged account, a specific reachable input, a user interaction. |
| **Medium** | Meaningful weakening of a control, or a defense-in-depth failure that needs another flaw to matter. |
| **Low** | Hardening gap with limited direct impact. |
| **Info** | Observation, hygiene, or a policy gap with no direct exploitability. |

Consider, explicitly: exposure (internet-facing vs internal vs local-only), authentication required,
data sensitivity, and blast radius. A SQL injection in an internal admin tool behind SSO is not the
same finding as one on a public signup form, and the report should reflect that.

---

## 2. Deduplicate to root causes

One finding per root cause. If the same missing authorization affects 14 endpoints, that is **one**
finding with 14 locations — not 14 findings. If one file has three separate injection sites with
three distinct causes, that is three findings.

The test: *would fixing this one thing resolve all these locations?* If yes, it is one finding.

This matters for the score as much as for readability: 14 duplicated Highs would zero out a category
that contains one real problem.

---

## 3. Find what grep cannot

Pattern matching cannot see design. On `standard` and `deep` runs, spend real effort here — these are
usually the most valuable findings in the report:

- **Trace the entry points.** For each route, endpoint, page, handler, job or message consumer: who
  can call it, what does it trust, and what does it change?
- **Authorization, not just authentication.** Signed-in is not authorized. For every read of a
  record by id, ask what stops user A reading user B's record. For every write, ask what role is
  required and where that is enforced.
- **Check the layer the enforcement actually lives in.** A check in the UI component that is absent
  from the service is a finding, because the service is reachable another way.
- **Trust boundaries.** Where does data cross from untrusted to trusted? Is it validated *there*, or
  is validation assumed to have happened upstream?
- **Business logic.** Negative quantities, price or total supplied by the client, state transitions
  that skip a step, race conditions on balance or inventory, replayable idempotency keys.
- **Multi-tenancy.** If the data model has a tenant/org/account column, is every query filtered by
  it? One unfiltered query is a cross-tenant data leak.
- **The gap between config and code.** A control configured but not applied, or applied only in one
  of two hosting paths.

---

## 4. Record the strengths

Controls that are correctly implemented belong in the report. List them with the same evidence
standard as findings. Three reasons:

1. They are what the category scores are built on — an unexplained 95 looks arbitrary.
2. They tell the reader what *not* to change during remediation.
3. A report that only lists problems reads as alarmism and gets discounted wholesale.

---

## 5. Special handling for modernization audits

When auditing generated or migrated code, classify each finding by origin:

| Origin | Meaning | Implication |
|---|---|---|
| `legacy-inherited` | The same flaw exists in the source system; the migration reproduced it | Pre-existing risk, now possibly more exposed |
| `migration-introduced` | The flaw does not exist in the source; generation created it | A defect in the migration — the highest-priority class |
| `migration-exposed` | The legacy code relied on an environmental control the new deployment does not have | The most commonly missed class — see below |
| `new-surface` | Functionality that did not exist before | Assess normally |

**`migration-exposed` deserves particular attention.** Legacy systems frequently depend on controls
that live outside the code: a green-screen terminal only reachable from the office network, an
operator who was already authenticated by the OS, a fixed-width form field that made over-long input
impossible, a batch job that only ran from a trusted host. Re-hosting that logic behind HTTP removes
every one of those controls silently — the code is unchanged, so nothing looks different, and the
application is now reachable by the internet with no authentication and no field-length enforcement.

Ask, for each legacy control: *what was enforcing this before, and does that still exist?*

For `legacy-inherited` findings, do not recommend translating the legacy mechanism. Home-grown
plaintext password comparison should be replaced with the target platform's identity provider, not
faithfully reimplemented in the new language.

---

## 6. Before you write the report

Re-read your findings list and check each one against these:

- [ ] Every finding cites a real `file:line` inside ROOT, and the excerpt matches the file.
- [ ] Every finding has a source, a path and a sink, or states which is assumed.
- [ ] Confidence reflects what you actually verified.
- [ ] Severity reflects impact in *this* application, not the pattern's generic reputation.
- [ ] No two findings share a root cause.
- [ ] Every CWE / ATT&CK / CVE identifier is one you actually know. Unsure → omit the field.
- [ ] Every remediation is specific to this codebase — names the real file, the real framework, the
      real setting. "Use parameterized queries" is not a remediation; a diff is.
- [ ] Every remediation has a verification step the engineer can actually run.
- [ ] Everything you did not check is in Limitations.

If a finding fails any of these, fix it or drop it before it reaches the report.
