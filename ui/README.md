# Local web UI

A dark, single-page front end for `/security-code-review`. Collects the three inputs, validates the
paths before you spend anything, runs the review, streams progress, and links the reports.

```
node ui/server.js --open
```

Then open <http://127.0.0.1:7099>.

```
  Security Code Review - local UI
  http://127.0.0.1:7099

  node        v22.11.0
  claude CLI  1.2.3 (Claude Code)
  skill       C:\Users\you\.claude\skills\security-code-review\SKILL.md
  cwd         C:\src

  Bound to loopback only. Ctrl+C to stop.
```

---

## Requirements

| | |
|---|---|
| **Node** | 18+. Standard library only — no `npm install`, no `package.json`, no `node_modules` |
| **Claude Code CLI** | On `PATH` as `claude`, or set `CLAUDE_BIN` to its full path. **Must be a real executable, not a `.cmd`/`.bat` shim** — see below |
| **The skills** | Installed via `install.ps1` / `install.sh` |

The status pills at the top of the page check all three and tell you which is missing. The UI is the
only part of this project that needs Node; the skills themselves remain dependency-free.

```bash
node ui/server.js --port 8080          # different port
CLAUDE_BIN="/full/path/to/claude" node ui/server.js
```

```powershell
$env:CLAUDE_BIN = "C:\path\to\claude.exe"; node ui\server.js --open
```

If you run Claude Code through the VS Code extension, the binary is bundled inside it:

```powershell
$env:CLAUDE_BIN = "$HOME\.vscode\extensions\anthropic.claude-code-<version>-win32-x64\resources\native-binary\claude.exe"
```

### Windows: point at the `.exe`, not a `.cmd` shim

An npm-installed CLI on Windows appears as `claude.cmd`, a batch shim. This server **refuses to
run those** and tells you so, rather than silently turning the shell back on to make it work.
Spawning a `.bat`/`.cmd` requires `shell: true`, and that reopens the Windows argument-escaping
hole (the *BatBadBut* class) that `shell: false` exists to close — which would be a poor trade in
a tool whose entire job is finding that kind of bug. Point `CLAUDE_BIN` at the real executable.

---

## What it does

1. **Validates as you type.** Each path is resolved server-side and checked: does it exist, is it a
   directory, how many files, what stack. A mistyped path is caught while it is still free — which
   is the entire point of doing this before the run rather than after.
2. **Shows the plan.** Resolved absolute paths, file counts, detected stack, where reports will
   land, and what each phase will do. Same confirmation the CLI gives you.
3. **Grants access.** Read on the two source trees and on the skill's own templates; write on the
   output folder, and nowhere else. All four are derived from the form, listed in the plan under
   **Access** before you spend anything, and echoed into the run log — see
   [Directory access](#directory-access).
4. **Runs it.** Spawns `claude --add-dir … --allowedTools … -p '/security-code-review …  --yes'`
   and streams stdout to the browser over Server-Sent Events, with a coarse per-phase progress strip.
5. **Shows that it is alive, and what it is doing.** An activity line names the tool currently
   running; it is driven by arriving events, not by a timer, so after 90 seconds of silence it stops
   and says how long it has been quiet — see [Liveness](#liveness).
6. **Counts the spend as it goes.** A running token and dollar total, replaced by the CLI's own
   measured figure when the run ends — see [The cost strip](#the-cost-strip).
7. **Links the reports.** Legacy, Modernized and Comparison open in new tabs when the run finishes.

**Copy CLI command** gives you the exact command instead, if you would rather run it in a terminal.

### Checks that run before the button enables

- project name is present, and illegal filename characters are flagged with the name that will
  actually be used
- modernized path exists and is non-empty
- legacy path exists, *or* is deliberately blank (the phase is then marked SKIP)
- the two paths are not the same directory — comparing a tree with itself yields an all-inherited
  report and a zero delta
- the output folder does not already contain a run for this project name
- the output folder exists, *or* its parent does — a folder that is merely missing is created on
  the spot and flagged *"will be created"*; one whose **parent** is also missing is almost always a
  typo, and blocks the button. See [The output folder](#the-output-folder)

---

## The output folder

It is created before the run starts if it does not exist, because it is also the CLI's working
directory — and that combination produces one of the worst error messages in the system.

**Node reports a missing `cwd` as `ENOENT` naming the executable.** A perfectly good CLI and a
misspelled output folder come out as:

```
Failed to start "…\claude.exe": spawn …\claude.exe ENOENT
```

which accuses the one component that is working. Both halves are now handled: the folder is created
(the run was about to write reports into it anyway, and the write grant already names it), and if
the spawn still fails with `ENOENT` the log says which of the three causes it was — binary absent,
working directory absent, or an executable blocked by policy or antivirus.

**Order matters here.** The path is canonicalised *after* the directory is created, never before.
`realpath` only resolves something that exists, so canonicalising first silently returns the raw
string — and if that string is an 8.3 short name such as `C:\Users\GILBER~1\src`, the CLI's path
guard rejects it and denies every read, which on screen is indistinguishable from an empty folder.
The run log shows the expanded form, so you can confirm it at a glance.

## Liveness

A twenty-minute audit that is working and a twenty-minute audit that has wedged look identical from
a browser. The spinner therefore never runs on a timer of its own: it is driven by events arriving
off the stream, and the label beside it is the tool the CLI most recently invoked.

### Why `--include-partial-messages` is not optional

An `assistant` event reaches the stream only when its message is **complete**. The audit's longest
steps are single enormous messages — writing the findings document was measured at **178 seconds** —
and for that entire stretch `stream-json` emits nothing at all. The log stops, the spinner has no
events to run on, and the page reports `no output for 2m` about a run that is working perfectly.

That is not a spinner fault and not a skill fault: the server simply never asked the CLI for
progress. `--include-partial-messages` makes it emit `content_block` deltas as the message is
produced — on a sample capture, one `assistant` event became **52** — so there is a pulse every few
hundred milliseconds even mid-document.

Those deltas are **never written to the log**. They are a token stream, and reproducing a terminal
is not the job. The server counts them and the activity line reports the size instead:

```
preparing Write… 8.1K chars
thinking… 1.2K chars
writing… 369 chars
```

A number that climbs is proof of life in a way that a spinning circle is not. Unknown event types
also refresh the liveness clock rather than being dropped, so a healthy stream can never read as a
dead one just because this renderer does not recognise something.

After `STALL_MS` (90 seconds) with nothing on the wire it stops spinning and says `no output for
4m 12s`. A long `Grep` over a large tree can genuinely take a minute, so the threshold sits well
past that — the point is to catch a dead run, not to cry wolf at a slow one.

Motion is decoration: every state ships a word beside it, and `prefers-reduced-motion` turns the
animation off without losing information.

## The cost strip

Two different numbers appear here over the life of a run, and they are deliberately styled
differently because they are not the same claim:

| | |
|---|---|
| **running estimate** | Computed here, from the `usage` on each assistant event, priced at the list rates in `security-audit/assets/pricing.json` |
| **measured by the CLI** | `total_cost_usd` from the final `result` event, which supersedes the estimate when the run ends |

The estimate is honest about its own limits:

- **Deduplicated by message id, keeping the maximum per field.** The CLI writes the same assistant
  message to the stream several times as it streams. Summing every event overstates the bill by
  2–3× — on a real transcript, 121 usage records collapse to 67 messages.
- **Cache writes with no per-TTL breakdown are billed at the 5-minute rate**, the cheaper of the
  two. Understating is the honest way to err. Both rules mirror `bin/cost.py`, and the two agree to
  the cent on the same input.
- **An unlisted model contributes tokens but no dollars**, and is named in the strip as `unpriced`.
  That is `pricing.json`'s own `unknownModelPolicy`: an invented rate is worse than an absent one.
- **Rates are read from `pricing.json`, never hardcoded here.** One pricing table, not two that
  drift apart.

**The report's figure remains authoritative.** It is measured from the session transcript and
attributed per phase via a watermark; this strip covers the whole session and cannot see subagent
turns that never reach the stream. When the two differ, the report is right.

On a subscription plan (Team, Max) these are list-price equivalents, not what you are billed.

## Directory access

A spawned CLI starts with almost no access to the disk, and the two ways that bites are opposites:
it cannot **read** the code you asked it to audit, and it cannot **write** the report it just paid
to produce. Neither one announces itself. A denied read yields a report with no findings, which
reads like a clean codebase; a denied write yields a finished analysis with nothing on disk.

The server therefore grants exactly four things on every run, derived from the form — never a list
of folders pinned in the source. Change the fields and the grants change with them.

| Grant | Directory | Why |
|---|---|---|
| read | the **Legacy** path | one `--add-dir` of its own |
| read | the **Modernized** path | one `--add-dir` of its own |
| read | `~/.claude/skills` | the audit runs the skill's `bin/` collectors and cats its `assets/` templates to render the report. Unreadable templates fail at the *last* step, with the analysis already paid for |
| **write** | the **output folder** | `--allowedTools "Edit(<out>/**)"` — the reports and `.security-audit/` |

Every one is echoed into the run log (`Granted read access to …`, `Granted write access to …`), so
what a run can touch is visible where you are already looking rather than buried in a process's
argv.

**Reports are written only to the output folder** — the `Edit` rule covers every file-editing tool
and nothing outside that path.

That boundary has a limit worth stating plainly. The audit runs the skill's own shell scripts to
collect cost and assemble the HTML, so `Bash` and `PowerShell` are granted too — and a shell can
write wherever the OS allows. The file tools are confined; the shell is not. So your source trees
are protected by the skill's read-only contract (it describes remediation, it never applies it)
rather than by the sandbox. That is a weaker guarantee than "cannot", and worth knowing before you
point this at a tree you could not restore.

The narrower alternative — allowlisting individual commands — was tried and rejected: the skill
composes multi-command shell lines, prefix rules miss them, and every miss is a run that dies twenty
minutes in with the analysis already paid for.

Three details in the write rule are load-bearing, each found by watching a run fail:

- **`Edit`, not `Write`.** Only `Edit` rules are consulted by the file permission check. A rule
  named after the `Write` tool matches nothing — the CLI mentions it on stderr and then denies
  every write anyway.
- **Forward slashes**, even on Windows. A rule spelled with backslashes never matches.
- **No leading `//`.** The absolute form this matcher accepts is the bare path.

Because the rule names the folder outright instead of relying on it being the working directory, the
same string works from any directory — which is what lets **Copy CLI command** hand you a command
that behaves exactly like the run you just watched.

The run is also spawned with `--permission-prompts none`. Nothing in a headless run can answer a
permission question, so this turns one that would otherwise stall the run into an immediate, logged
denial: a failure you can read instead of one you wait out.

Paths are canonicalised first — symlinks resolved and Windows 8.3 short names expanded. That last
one is not cosmetic: the CLI's path guard rejects a short name such as `C:\Users\GILBER~1\src` and
denies every read through it, which on screen is indistinguishable from an empty folder.

---

## Security

This is a local tool for a security product, so it follows the advice the product gives. Each of
these is asserted by the project's static checks so it cannot regress silently.

| Concern | How it is handled |
|---|---|
| **Command injection** | The CLI is spawned with an **argv array** and `shell: false`. Paths are arguments, never shell text, so `C:\x & calc.exe` is just an odd directory name. This is the single most important line in the server |
| **Network exposure** | Binds `127.0.0.1` only — never `0.0.0.0`. The audit in this repo filed exactly that as a High finding; repeating it here would be poor form |
| **Cross-site request** | `Host`/`Origin` are checked on every request, so a page you happen to be browsing cannot drive the server behind your back |
| **Path traversal** | Reports are served only from inside the run's own project folder, via `basename()` plus a resolved prefix check |
| **XSS** | Strict CSP: no inline script, no CDN, no `eval`. All interpolation goes through an escape helper |
| **Supply chain** | Zero npm dependencies. Nothing to audit but the one file |
| **Least privilege** | The spawned CLI reads the two trees named in the form plus the skill's own templates — not their parents, not a drive root — and its file tools can write only to the output folder. Every grant is echoed in the run log. The shell it needs for cost collection and rendering is not path-confined; see [Directory access](#directory-access) |

**There is no authentication**, by design — it is a loopback-only developer tool. Do not put it
behind a reverse proxy or bind it to a routable interface without adding auth first. If you need it
on a shared host, the honest answer is that this server is not the right shape for that.

---

## Files

```
ui/
├── server.js            Node stdlib HTTP server: static, validation, spawn, SSE
├── public/
│   ├── index.html       the page
│   ├── styles.css       dark theme, single stylesheet, no external fonts
│   └── app.js           client: validation, SSE, progress, results
└── README.md            this file
```

## Endpoints

| Route | Purpose |
|---|---|
| `GET  /api/preflight` | Node version, CLI presence, whether the skill is installed |
| `POST /api/validate` | Path resolution, file counts, stack detection, plan data |
| `POST /api/run` | Start a review; returns a `runId` |
| `GET  /api/events?run=` | SSE stream: `line`, `phases`, `alive`, `cost`, `done` |
| `POST /api/cancel` | SIGTERM the running child |
| `GET  /report?run=&f=` | Serve a generated report, confined to that run's folder |

## Limitations

- **The live cost figure is an estimate, not a measurement**, until the run ends. It is labelled as
  such on screen, and the report's per-phase measured cost is the number to quote.
- **Runs are in memory.** Restarting the server loses the log of a completed run. The reports on
  disk are unaffected — they are the durable output.
- **Phase progress is heuristic while running**, matched from the skill's own announcements, so the
  strip may lag if that wording changes. It is *settled* against the artifacts, though: when the run
  ends, a phase is marked done only if its report is actually on disk. A phase that never ran reads
  **not run**, never a misleading green. The streamed log is always authoritative.
- **One machine.** The UI drives a local CLI against local paths. It is not a shared service.
