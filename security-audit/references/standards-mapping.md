# Standards crosswalk

Every finding carries the standards mapping its reader needs: OWASP for the developer, CWE for the
tracker, MITRE ATT&CK for the security team, NIST for the auditor.

> **The rule that matters most: never invent an identifier.** A plausible-looking wrong CWE or a
> fabricated CVE discredits the entire report, and the reader has no way to tell which other numbers
> are wrong. If you are not certain of an identifier, omit the field. An omitted mapping costs
> nothing; a wrong one costs the report's credibility.

---

## 1. OWASP Top 10 (2021) — the primary axis

| ID | Category | What lands here |
|---|---|---|
| **A01** | Broken Access Control | Missing authN/authZ, IDOR, path traversal, CSRF, forced browsing, privilege escalation, missing tenant isolation |
| **A02** | Cryptographic Failures | Secrets in source, weak/broken algorithms, cleartext transport or storage, poor key management, weak randomness |
| **A03** | Injection | SQL, NoSQL, OS command, LDAP, XPath, template (SSTI), expression language — **and XSS** |
| **A04** | Insecure Design | Missing validation, mass assignment, missing rate limits, business-logic flaws, absent threat modelling |
| **A05** | Security Misconfiguration | Missing headers, verbose errors, default credentials, unnecessary features, permissive CORS, XXE, exposed admin surfaces |
| **A06** | Vulnerable & Outdated Components | Known-vulnerable dependencies, unsupported runtimes, no dependency scanning |
| **A07** | Identification & Authentication Failures | Weak passwords, broken session management, missing MFA, credential stuffing exposure, JWT verification flaws |
| **A08** | Software & Data Integrity Failures | Unsafe deserialization, unsigned updates, untrusted CI actions, prototype pollution, missing lockfiles |
| **A09** | Security Logging & Monitoring Failures | No audit trail, secrets in logs, no alerting, insufficient detail for incident response |
| **A10** | Server-Side Request Forgery | Outbound requests to URLs influenced by input |

**On the 2025 revision.** OWASP publishes a new Top 10 on a multi-year cadence, and the category set
and ordering change between editions. This skill reports against **2021** as its primary axis because
it is the edition most tracking systems, compliance mappings and developer tooling are keyed to.

If the user asks for the current edition, or the project's compliance regime requires it:
1. Fetch the current list from `https://owasp.org/www-project-top-ten/` with `WebFetch` rather than
   recalling it — the category names and ordering are exactly the kind of detail worth verifying.
2. Report both: keep the 2021 category as `owasp` and add the current-edition category as
   `owaspCurrent`, with the edition year in `meta.standards`.
3. If you cannot fetch it, report 2021 only and say so. Do not guess at a category list.

---

## 2. CWE — the precise identifier

Use CWE when you need to be exact about *what kind* of flaw it is. These are the ones that come up
constantly and that you can use with confidence:

| CWE | Name | Typical trigger |
|---|---|---|
| CWE-20 | Improper Input Validation | No server-side validation |
| CWE-22 | Path Traversal | File path built from input |
| CWE-78 | OS Command Injection | Shell command with interpolated input |
| CWE-79 | Cross-Site Scripting | Unescaped output to HTML |
| CWE-89 | SQL Injection | Query built by concatenation |
| CWE-94 / CWE-95 | Code Injection / Eval Injection | Dynamic evaluation of input |
| CWE-200 | Information Exposure | Sensitive data disclosed |
| CWE-209 | Error Message Information Leak | Stack trace returned to client |
| CWE-256 / CWE-257 | Plaintext / Recoverable Password Storage | Passwords not hashed |
| CWE-259 | Hard-coded Password | Literal credential in source |
| CWE-284 | Improper Access Control | Broad access-control failure |
| CWE-287 | Improper Authentication | Broken auth mechanism |
| CWE-295 | Improper Certificate Validation | TLS verification disabled |
| CWE-306 | Missing Authentication for Critical Function | Unauthenticated endpoint |
| CWE-307 | Improper Restriction of Excessive Auth Attempts | No lockout / rate limit |
| CWE-311 | Missing Encryption of Sensitive Data | Data at rest or in transit unprotected |
| CWE-319 | Cleartext Transmission | HTTP instead of HTTPS |
| CWE-321 | Hard-coded Cryptographic Key | Embedded key material |
| CWE-327 | Broken/Risky Crypto Algorithm | DES, RC4, ECB mode |
| CWE-328 | Weak Hash | MD5/SHA-1 where collision resistance matters |
| CWE-338 | Cryptographically Weak PRNG | Math.random for a token |
| CWE-347 | Improper Verification of Signature | JWT not verified |
| CWE-352 | Cross-Site Request Forgery | No antiforgery token |
| CWE-434 | Unrestricted File Upload | No type/size/location control |
| CWE-502 | Deserialization of Untrusted Data | pickle, readObject, BinaryFormatter |
| CWE-521 | Weak Password Requirements | Short or trivial password policy |
| CWE-532 | Sensitive Information in Log File | Secrets or PII logged |
| CWE-540 | Information Exposure Through Source Code | Secret file committed |
| CWE-611 | XML External Entity (XXE) | Parser resolves external entities |
| CWE-613 | Insufficient Session Expiration | Sessions never expire |
| CWE-614 | Sensitive Cookie Without Secure | Cookie flags missing |
| CWE-639 | Authorization Bypass Through User-Controlled Key | IDOR |
| CWE-732 | Incorrect Permission Assignment | Over-broad file or DB permissions |
| CWE-778 | Insufficient Logging | No audit trail |
| CWE-798 | Use of Hard-coded Credentials | API key, password or token in source |
| CWE-829 | Inclusion of Functionality from Untrusted Control Sphere | Unpinned CI action, curl-to-shell |
| CWE-862 | Missing Authorization | No authorization check |
| CWE-863 | Incorrect Authorization | Wrong check applied |
| CWE-915 | Improperly Controlled Modification of Attributes | Mass assignment / over-posting |
| CWE-916 | Password Hash With Insufficient Computational Effort | Fast hash for passwords |
| CWE-918 | Server-Side Request Forgery | Outbound request from input |
| CWE-942 | Overly Permissive CORS Policy | Wildcard origin |
| CWE-1004 | Sensitive Cookie Without HttpOnly | Session cookie readable by script |
| CWE-1021 | Improper Restriction of Rendered UI Layers | Clickjacking / weak CSP |
| CWE-1104 | Use of Unmaintained Third-Party Components | Outdated dependency |
| CWE-1321 | Prototype Pollution | Recursive merge of untrusted keys |
| CWE-1336 | Server-Side Template Injection | Template rendered from input |

Anything not on this list: use it only if you are certain. Otherwise leave `cwe` empty and describe
the flaw in prose.

---

## 3. MITRE ATT&CK — how it would be used

ATT&CK describes adversary behaviour, not code defects, so the mapping is *indicative*: it answers
"what would an attacker do with this?" and helps a security team connect the finding to detections
they already have. Populate it only where the connection is real.

| Technique | Name | Maps from |
|---|---|---|
| T1078 | Valid Accounts | Weak/default/hard-coded credentials, auth bypass |
| T1078.004 | Valid Accounts: Cloud Accounts | Leaked cloud key |
| T1082 | System Information Discovery | Verbose errors, exposed actuator/debug endpoints |
| T1083 | File and Directory Discovery | Path traversal enabling read |
| T1090 | Proxy | SSRF used to pivot |
| T1189 | Drive-by Compromise | CSRF, stored XSS |
| T1190 | Exploit Public-Facing Application | SQLi, RCE, auth bypass on an internet-facing app |
| T1195.002 | Supply Chain Compromise: Software Supply Chain | Unpinned CI action, compromised dependency |
| T1213 | Data from Information Repositories | Secrets in a repository |
| T1505.003 | Server Software Component: Web Shell | File upload or LFI/RFI reaching code execution |
| T1530 | Data from Cloud Storage | Public bucket, over-permissive storage policy |
| T1550.001 | Use Alternate Authentication Material: Application Access Token | Forged or unverified JWT |
| T1552 | Unsecured Credentials | Credentials in logs, config or source |
| T1552.001 | Credentials In Files | `.env`, config, source literal |
| T1552.004 | Private Keys | Embedded key material |
| T1557 | Adversary-in-the-Middle | TLS validation disabled, cleartext transport |
| T1059 | Command and Scripting Interpreter | Command injection, deserialization RCE, eval |
| T1059.006 | Python | Python-specific code execution |
| T1059.007 | JavaScript | XSS, client-side code execution |
| T1611 | Escape to Host | Privileged container, root process |

Sub-technique ids beyond these: verify before using. `T1190` is a safe general choice for
remotely-exploitable application flaws when nothing more specific is certain.

---

## 4. NIST — the compliance axis

### SP 800-218 (SSDF v1.1) — secure development practices

Maps findings to *process* gaps, which is what an auditor asks about. Use the practice id.

| Practice | Name | Findings that indicate a gap |
|---|---|---|
| PO.5 | Implement and Maintain Secure Environments | Insecure CI configuration, exposed build secrets |
| PS.1 | Protect All Forms of Code | Secrets committed, no access control on the repository |
| PS.2 | Provide a Mechanism for Verifying Integrity | Unsigned artifacts, no lockfile, unpinned actions |
| PW.4 | Reuse Existing, Well-Secured Software | Vulnerable or unmaintained dependencies |
| PW.5 | Create Source Code Adhering to Secure Practices | Injection, XSS, unsafe deserialization, weak crypto |
| PW.6 | Configure the Compilation and Build Process | Debug builds shipped, symbols exposed |
| PW.7 | Review and/or Analyze Human-Readable Code | No security review in the pipeline |
| PW.8 | Test Executable Code | No security testing (SAST/DAST/dependency scanning) |
| PW.9 | Configure Software to Have Secure Settings by Default | Insecure defaults, missing headers, verbose errors |
| RV.1 | Identify and Confirm Vulnerabilities | No vulnerability intake or monitoring |

### SP 800-53 Rev. 5 — control families

Use where the organization tracks controls (FedRAMP, FISMA and most enterprise GRC programs do).

| Control | Name | Findings |
|---|---|---|
| AC-2 | Account Management | Weak account lifecycle |
| AC-3 | Access Enforcement | Missing authorization, IDOR |
| AC-4 | Information Flow Enforcement | Missing tenant isolation, SSRF |
| AC-6 | Least Privilege | Over-broad grants, root container, GRANT ALL |
| AU-2 | Event Logging | No audit trail on mutations |
| AU-9 | Protection of Audit Information | Logs writable or unprotected |
| CM-6 | Configuration Settings | Insecure configuration |
| CM-7 | Least Functionality | Unnecessary endpoints exposed |
| IA-2 | Identification and Authentication | Missing or broken authentication |
| IA-5 | Authenticator Management | Hard-coded credentials, weak password policy |
| RA-5 | Vulnerability Monitoring and Scanning | No dependency scanning |
| SA-11 | Developer Testing and Evaluation | No security testing |
| SC-8 | Transmission Confidentiality and Integrity | Cleartext transport, TLS bypass |
| SC-13 | Cryptographic Protection | Weak or broken algorithms |
| SC-28 | Protection of Information at Rest | Unencrypted sensitive storage |
| SI-10 | Information Input Validation | Missing input validation |
| SI-11 | Error Handling | Verbose errors to the client |

---

## 5. Worked mapping

> **Finding:** no authorization on `DELETE /api/customers/{id}`; any anonymous caller can delete any
> customer record.

```json
{
  "owasp":  "A01:2021 Broken Access Control",
  "cwe":    ["CWE-862", "CWE-306"],
  "attack": [{ "id": "T1190", "name": "Exploit Public-Facing Application" }],
  "nist":   { "ssdf": ["PW.5", "PW.9"], "sp80053": ["AC-3", "IA-2"] }
}
```

Note what is *absent*: no CVE (this is not a known-vulnerability finding), and no speculative
sub-technique. Each identifier present is one that genuinely applies.
