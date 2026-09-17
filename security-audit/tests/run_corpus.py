#!/usr/bin/env python3
"""Golden-corpus regression tests for the rule packs.

    python tests/run_corpus.py [--rg <path-to-ripgrep>] [--verbose]

Two properties are enforced, and the second matters more than the first:

  1. Every pattern in every rule pack COMPILES under ripgrep's Rust regex engine.
     Rust regex has no lookaround and no backreferences, so a pattern that works in PCRE
     can fail here - silently, because a broken rule just never matches.

  2. Rules fire on the vulnerable fixtures and STAY SILENT on the safe ones.
     The negative cases are the point. Precision is what makes the report worth reading;
     a rule that flags parameterized SQL trains engineers to ignore the tool, and that
     loss is permanent. Detection regressions are loud; precision regressions are invisible
     without a test that asserts silence.

Runs ripgrep itself rather than Python's `re`, because ripgrep is what the skill actually
uses at audit time - testing a different engine would prove nothing.

Exit code 0 = all green. Non-zero = something regressed.
Standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RULES_DIR = ROOT / "rules"
CORPUS_DIR = Path(__file__).resolve().parent / "corpus"
MANIFEST = CORPUS_DIR / "expected.json"

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"


def load_rules() -> dict:
    """rule id -> {pattern, glob, pack, ...} for every pack except the index."""
    rules = {}
    for f in sorted(RULES_DIR.glob("*.json")):
        if f.name == "00-index.json":
            continue
        doc = json.loads(f.read_text(encoding="utf-8"))
        for r in doc.get("rules", []):
            rid = r.get("id")
            if not rid:
                continue
            r["_pack"] = f.name
            rules[rid] = r
    return rules


def resolve_rg(explicit: str | None) -> tuple[list, dict] | None:
    """Return (argv-prefix, env-overrides) for invoking ripgrep, or None.

    Inside Claude Code there is usually no `rg` on PATH: it is a shell function that runs the
    Claude binary with argv[0] set to "rg". A Python child process cannot see a shell function,
    so reproduce the shim rather than give up - otherwise these tests only run for people who
    happen to have a standalone ripgrep installed.
    """
    if explicit:
        p = shutil.which(explicit) or (explicit if Path(explicit).exists() else None)
        if p:
            return [p], {}

    p = shutil.which("rg")
    if p:
        return [p], {}

    cc = os.environ.get("CLAUDE_CODE_EXECPATH")
    cands = [cc] if cc else []
    cands += [str(Path.home() / ".local" / "bin" / ("claude.exe" if os.name == "nt" else "claude")),
              shutil.which("claude")]
    for c in cands:
        if c and Path(c).exists():
            if os.name == "nt":
                # The shim's Windows path: ARGV0 env var selects the ripgrep personality.
                return [c], {"ARGV0": "rg"}
            # POSIX: run the Claude binary but present argv[0] as "rg".
            return ["rg", "--__exe__", c], {}
    return None


def _run_rg(rg: tuple[list, dict], args: list, **kw):
    prefix, envover = rg
    env = {**os.environ, **envover} if envover else None
    if len(prefix) == 3 and prefix[1] == "--__exe__":
        return subprocess.run(["rg", *args], executable=prefix[2], env=env,
                              text=True, capture_output=True, **kw)
    return subprocess.run([*prefix, *args], env=env, text=True, capture_output=True, **kw)


def rg_compiles(rg, pattern: str) -> tuple[bool, str]:
    """Feed the pattern to ripgrep. Exit >= 2 means it did not compile."""
    p = _run_rg(rg, ["-e", pattern, "--no-messages"], input="x\n")
    if p.returncode >= 2:
        err = (p.stderr or "").strip().splitlines()
        detail = next((l.strip() for l in err if "error" in l.lower()), (err[0].strip() if err else "unknown"))
        return False, detail
    return True, ""


def rg_hits(rg, pattern: str, path: Path) -> int:
    p = _run_rg(rg, ["-c", "--no-messages", "-e", pattern, str(path)])
    if p.returncode >= 2:
        return -1
    if p.returncode == 1:
        return 0
    try:
        return int((p.stdout or "0").strip().splitlines()[0])
    except (ValueError, IndexError):
        return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rg", default=None, help="path to ripgrep, or the Claude binary")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    rg = resolve_rg(args.rg)
    if rg is None:
        print(f"{RED}ripgrep not found{RESET}. Pass --rg <path-to-rg-or-claude-binary>.\n"
              f"Inside Claude Code, `rg` is a shell function rather than a binary on PATH, "
              f"so this looks for the Claude executable too.", file=sys.stderr)
        return 2

    rules = load_rules()
    print(f"loaded {len(rules)} rules from {len(list(RULES_DIR.glob('*.json'))) - 1} packs\n")

    failures: list[str] = []

    # ---------------------------------------------------------- 1. compilation
    print("== pattern compilation ==")
    checked = 0
    for rid, r in sorted(rules.items()):
        for field in ("pattern", "patternAlt"):
            pat = r.get(field)
            if not pat:
                continue
            checked += 1
            ok, err = rg_compiles(rg, pat)
            if not ok:
                failures.append(f"{rid} [{field}] does not compile: {err}")
                print(f"  {RED}FAIL{RESET} {rid} [{field}] {DIM}{err}{RESET}")
            elif args.verbose:
                print(f"  {GREEN}ok{RESET}   {rid} [{field}]")
    print(f"  {checked} patterns checked, "
          f"{len([f for f in failures if 'does not compile' in f])} broken\n")

    # ---------------------------------------------------------- 2. corpus
    if not MANIFEST.is_file():
        print(f"{YELLOW}no corpus manifest at {MANIFEST} - skipping fixture tests{RESET}")
    else:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        cases = manifest.get("cases", [])
        print(f"== corpus fixtures ({len(cases)} cases) ==")
        for case in cases:
            rel = case["file"]
            path = CORPUS_DIR / rel
            label = case.get("label", rel)
            if not path.is_file():
                failures.append(f"missing fixture: {rel}")
                print(f"  {RED}FAIL{RESET} {label} {DIM}(fixture missing){RESET}")
                continue

            problems = []
            for rid in case.get("expect", []):
                r = rules.get(rid)
                if not r:
                    problems.append(f"unknown rule {rid}")
                    continue
                n = rg_hits(rg, r["pattern"], path)
                if n <= 0:
                    problems.append(f"{rid} should fire but did not")

            # The important half: these rules must stay silent on this file.
            for rid in case.get("reject", []):
                r = rules.get(rid)
                if not r:
                    problems.append(f"unknown rule {rid}")
                    continue
                n = rg_hits(rg, r["pattern"], path)
                if n > 0:
                    problems.append(f"{rid} FALSE POSITIVE ({n} hit(s))")

            if problems:
                failures.extend(f"{rel}: {p}" for p in problems)
                print(f"  {RED}FAIL{RESET} {label}")
                for p in problems:
                    print(f"         {DIM}{p}{RESET}")
            else:
                print(f"  {GREEN}pass{RESET} {label}")
        print()

    # ---------------------------------------------------------- summary
    if failures:
        print(f"{RED}{len(failures)} failure(s){RESET}")
        for f in failures:
            print(f"  - {f}")
        return 1

    print(f"{GREEN}all green{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
