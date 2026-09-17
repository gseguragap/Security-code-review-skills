# Non-breaking remediation playbook

A remediation is only useful if the team will actually apply it. The two things that stop them are
*"this will break the app"* and *"this is too vague to act on"*. This playbook exists to prevent both.

---

## 1. The non-breaking principle

> Prefer a fix that changes what an **attacker** can do without changing what a **legitimate user**
> experiences.

In rough order of preference:

1. **Configuration** — a setting, a header, an environment variable. No code change, trivially
   reversible.
2. **Additive middleware or filters** — applied globally, no per-file edits.
3. **Declarative attributes / decorators** — added to existing types, behaviour unchanged for
   authorized callers.
4. **Opt-in validation** — rejects invalid input; valid input behaves exactly as before.
5. **Localized code change** — a parameterized query replacing a concatenated one; same result set.
6. **Structural change** — a new auth flow, a schema migration, a rewritten module. Last resort.

Levels 1–5 are non-breaking. Level 6 is not — mark it `breakingChange: true`, describe the migration,
and let the team schedule it. **Do not present a breaking change as safe.** The one thing that will
get this skill's output ignored permanently is a "non-breaking" fix that breaks production.

### Every remediation needs a verification step

Not "verify it works" — a specific, runnable check with an expected result:

- *"`curl -i https://app/customers/1` while unauthenticated returns 302 to /login; the same request
  with a session cookie returns 200 with the record."*
- *"`dotnet build` reports 0 errors; the app starts; `/orders` renders seeded rows."*
- *"Browser console shows no CSP violations on page load and the app is interactive."*
- *"Submitting a 200-character value in a 15-character field shows a validation message; a
  14-character value saves normally."*

If you cannot write the verification, you do not understand the fix well enough to recommend it.

---

## 2. Ordering the roadmap

Sort by **risk reduction per unit of effort**, subject to dependencies:

1. **Access control first.** It is usually the largest single score component, and it often subsumes
   other findings — adding authentication frequently closes the IDOR and the unprotected-mutation
   findings at the same time. Say so explicitly in the roadmap.
2. **Then cheap configuration hardening.** Headers, CSP, error verbosity, cookie flags. Hours of work
   for real points.
3. **Then data and input.** Validation, encryption at rest, secret extraction.
4. **Then operational.** Audit logging, dependency scanning in CI, monitoring.

Phase 1 should be the phase that, if it were the only thing done, still meaningfully changes the
application's exposure.

---

## 3. Patterns by category

### A01 — Access control

**Missing authentication across the app.** Do not add `[Authorize]` to every page — that is a large,
error-prone diff that misses whatever gets added next week. Set a **global default-deny policy** and
opt specific endpoints out:

- ASP.NET Core: `AddAuthorizationBuilder().SetFallbackPolicy(new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build())`,
  then `[AllowAnonymous]` on login/health/error. Add `UseAuthentication()` / `UseAuthorization()`
  before `UseAntiforgery()`. Protect the hub with `MapBlazorHub().RequireAuthorization()`.
- Spring Security: `.anyRequest().authenticated()` last in the matcher chain, with explicit
  `permitAll()` for login and static assets *before* it.
- Express: an app-level `requireAuth` middleware mounted before the routers, with an allow-list.
- Django: `LoginRequiredMiddleware` (Django 5.1+) or a middleware checking
  `request.user.is_authenticated`, with `@login_not_required` for exceptions.
- FastAPI: a router-level `dependencies=[Depends(get_current_user)]`.

Default-deny means new endpoints are protected by default. That property is worth more than the
initial fix.

**IDOR.** Authentication alone does not fix it — user A can still request user B's id. The fix is an
ownership check in the data-access path, not the controller:

```
// before: returns any record by id
var order = await db.Orders.FindAsync(id);

// after: scoped to the caller. Same shape, same call sites.
var order = await db.Orders
    .Where(o => o.Id == id && o.CustomerId == currentUser.CustomerId)
    .SingleOrDefaultAsync();
```

Putting the filter in the query (rather than an `if` after loading) means a missing check fails
closed and cannot be bypassed by another call path. In multi-tenant systems, prefer a global query
filter or row-level security so it cannot be forgotten at all.

**Unprotected destructive operations.** Role-gate writes while leaving reads broad — the smallest
change that removes the risk: `[Authorize(Policy = "CanModify")]` on the mutating surface.

### A02 — Cryptographic failures

**Secrets in source.** The remediation is always two steps, and the first is the one people skip:

1. **Rotate the credential.** It is compromised. It is in git history, on every developer's laptop,
   and in every CI log. Removing it from `HEAD` does not un-leak it.
2. Move it to a secret store — user-secrets in development, Key Vault / Secrets Manager / Parameter
   Store / Vault in production — read through the platform's configuration provider so the call
   sites do not change.
3. Add the path to `.gitignore` and consider history rewriting for high-value secrets.

**Weak hashing of passwords.** Do not rehash existing values — you cannot, you do not have the
plaintext. Migrate on next login: verify against the old algorithm, and on success rehash with
Argon2id / bcrypt / PBKDF2 and store the new value with an algorithm marker. Transparent to the user.

**Data at rest.** Prefer platform encryption (TDE, encrypted volumes, SQLCipher for SQLite) over
application-level column encryption — it needs no code change and no query rewriting. Application
encryption breaks searching and sorting on those columns, so if it is genuinely required, say so and
flag the query impact.

**TLS validation disabled.** Remove the bypass and fix the underlying cause — usually an internal CA
that is not in the trust store. Add the CA; do not keep the bypass.

### A03 — Injection

**SQL.** Parameterize. The result set is identical, so this is behaviour-preserving:

```
// before
var sql = "SELECT * FROM Customers WHERE City = '" + city + "'";

// after - EF Core, parameterized automatically
var sql = $"SELECT * FROM Customers WHERE City = {city}";  // FromSqlInterpolated
// or explicit
cmd.CommandText = "SELECT * FROM Customers WHERE City = @city";
cmd.Parameters.AddWithValue("@city", city);
```

Where the variable part is an **identifier** (table, column, sort direction) parameters cannot help:
map the input through an allow-list to a literal.

```
var column = sortBy switch { "name" => "Name", "date" => "CreatedUtc", _ => "Id" };
```

**Command injection.** Replace the shell form with the argument-array form
(`execFile`, `subprocess.run([...], shell=False)`, `ProcessStartInfo.ArgumentList`). Same command,
no shell to inject into.

**XSS.** Remove the escaping bypass, or sanitize immediately before the sink with a maintained
library (DOMPurify, HtmlSanitizer, bleach). Never write your own sanitizer. Add CSP as
defense-in-depth, not as the fix.

**CSP tightening without breaking the app.** Do it in this order:
1. Drop `unsafe-eval` first — most frameworks do not need it and nothing breaks.
2. Deploy `Content-Security-Policy-Report-Only` with the target policy and collect violations for a
   release. This is the step that makes the change safe.
3. Replace `script-src 'unsafe-inline'` with a per-request nonce on the framework script tags.
4. Keep `style-src 'unsafe-inline'` if a component library needs it — materially lower risk than
   scripts, and say so rather than pretending otherwise.

### A04 — Validation and design

Add annotations that mirror the **real schema constraints**, not invented ones. Read the column
lengths and types from the DDL or the entity configuration and match them exactly. Validation that is
stricter than the schema rejects data the system previously accepted — that *is* a breaking change.

Mass assignment: bind to a DTO containing only the fields the UI actually submits. Same endpoint,
same happy path.

### A05 — Misconfiguration

Security headers are additive middleware and safe to add as a block:
`Content-Security-Policy`, `X-Content-Type-Options: nosniff`, `Referrer-Policy`,
`Permissions-Policy`, `Strict-Transport-Security` (HTTPS only), `X-Frame-Options` or CSP
`frame-ancestors`.

Remove `X-XSS-Protection` — modern browsers ignore it and its legacy filter could itself introduce
issues. CSP is the modern control.

Errors: ensure production runs with the production environment flag and a generic error handler; keep
full detail server-side in the log.

### A06 — Dependencies

Patch within the same major version first — usually a lockfile change with no code impact. For a
major bump, note the breaking-change risk and treat it as its own task.

Add scanning to CI so the finding does not recur: `dotnet list package --vulnerable --include-transitive`
(fail on High/Critical), `npm audit --audit-level=high`, `pip-audit`, `govulncheck`, or Dependabot /
Renovate. **This is the durable fix** — a one-time patch is obsolete the following week.

### A07 — Authentication

Follow NIST SP 800-63B: length over composition rules, check against a breached-password list, do not
force periodic rotation. Add lockout or progressive delay. Set session cookies `HttpOnly`, `Secure`,
`SameSite=Lax` (or `Strict` where no cross-site flow exists). Regenerate the session id on login.

JWT: always `verify()` with an explicit algorithm allow-list, never `decode()` alone; validate `exp`,
`iss` and `aud`.

### A08 — Integrity

Replace unsafe deserializers with data formats: JSON with a schema, or a type-filtered deserializer.
`yaml.safe_load` instead of `yaml.load`. In .NET, `BinaryFormatter` is removed in modern versions —
migrate to `System.Text.Json`.

Pin CI actions to a full commit SHA. Commit the lockfile. Prefer signed artifacts.

### A09 — Logging

Add structured audit events on mutations: who, what, when, from where, and the outcome — after
authentication exists to supply identity. Purely additive.

Redact secrets at the logging layer (a destructuring policy or filter), not at each call site, so a
new call site cannot reintroduce the leak.

### A10 — SSRF

Allow-list the destination host. Where user-supplied URLs are genuinely required: resolve the DNS
name, reject private and link-local ranges (including `169.254.169.254`), disable redirect following
or re-validate after each hop, and prefer routing through an egress proxy that enforces the policy.

---

## 4. Modernization-specific guidance

When the audit covers migrated code, the remediation advice changes:

- **Do not port a legacy security mechanism.** Home-grown password comparison, custom "encryption",
  and menu-based access control should be replaced with the target platform's identity and
  authorization primitives — not translated. Translating them carries the flaw into a system that
  will live for another decade.
- **Re-establish the controls the environment used to provide.** Terminal-only access becomes
  authentication plus network policy. Fixed-width screen fields become explicit server-side
  validation with the real column lengths. Operator-only batch execution becomes a service identity
  with a scoped role.
- **The generated code is young.** Fixing the *generator* is worth more than fixing the output when
  the same flaw will appear in the next migration. Note which findings are generator-level so the
  Modernizer team can act on them once rather than per project.

---

## 5. What a good remediation looks like in the report

```
S-4 — CSP allows 'unsafe-inline' and 'unsafe-eval' in script-src   [Medium, A05]

Evidence   Middleware/SecurityHeadersMiddleware.cs:34
           script-src 'self' 'unsafe-inline' 'unsafe-eval'
Risk       Removes most of CSP's value as an XSS mitigation; an injected inline
           script executes despite the policy being present.
Fix        1. Drop 'unsafe-eval' - Blazor Server does not require it.
           2. Deploy the tightened policy as Content-Security-Policy-Report-Only
              for one release and review violation reports.
           3. Replace 'unsafe-inline' for scripts with a per-request nonce, added
              to the framework script tags in _Layout.cshtml.
           Keep style-src 'unsafe-inline' - MudBlazor requires it, and style
           injection is materially lower risk than script injection.
Breaking   No. Step 2 makes the change observable before it is enforced.
Effort     S (about half a day including the report-only soak)
Verify     App loads and is interactive with the tightened policy; browser console
           shows zero CSP violations across the main routes.
```

Specific file. Real line. Named framework. Staged rollout. Honest about what is being kept and why.
A concrete verification. That is the standard.
