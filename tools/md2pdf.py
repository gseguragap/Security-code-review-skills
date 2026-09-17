#!/usr/bin/env python3
"""Render Markdown documents to print-quality PDF.

    python tools/md2pdf.py docs/*.md
    python tools/md2pdf.py docs/Foo.md --out-dir docs --keep-html

Markdown -> styled HTML -> headless Chromium `--print-to-pdf`. This is the same path the
Modernizer security-module design plan specifies for its own PDF output, and it needs nothing
installed: Python for the conversion, and Edge or Chrome (already on any Windows/macOS box)
for the rendering.

Standard library only. Deliberately not a general-purpose Markdown engine - it implements the
subset these documents actually use, and does that subset correctly:

    headings, paragraphs, --- rules, fenced code, pipe tables (incl. escaped \\| in cells),
    nested ordered/unordered lists, task lists, blockquotes, and inline
    **bold** *italic* `code` ~~strike~~ [links](url).

If a document starts using something not listed above, add it here rather than hand-editing HTML.
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# --------------------------------------------------------------------------- inline

CODE_TOKEN = "\x00CODE{}\x00"


def inline(text: str) -> str:
    """Inline markdown -> HTML. Code spans are extracted first so their contents are literal."""
    spans: list[str] = []

    def stash(m: re.Match) -> str:
        spans.append(m.group(1))
        return CODE_TOKEN.format(len(spans) - 1)

    text = re.sub(r"`([^`]+)`", stash, text)
    text = html.escape(text, quote=False)

    # links before emphasis, so [**a**](url) works and underscores in URLs survive
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)",
                  lambda m: f'<a href="{html.escape(m.group(2), quote=True)}">{m.group(1)}</a>',
                  text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"~~([^~]+)~~", r"<del>\1</del>", text)
    # single * for italic, but not inside an already-consumed ** pair
    text = re.sub(r"(?<![*\w])\*([^*\n]+)\*(?![*\w])", r"<em>\1</em>", text)

    for i, s in enumerate(spans):
        text = text.replace(CODE_TOKEN.format(i), f"<code>{html.escape(s, quote=False)}</code>")
    return text


# --------------------------------------------------------------------------- tables

def split_row(line: str) -> list[str]:
    """Split a pipe-table row, honouring \\| escapes inside cells."""
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|") and not line.endswith(r"\|"):
        line = line[:-1]
    cells, buf, i = [], [], 0
    while i < len(line):
        c = line[i]
        if c == "\\" and i + 1 < len(line) and line[i + 1] == "|":
            buf.append("|")
            i += 2
            continue
        if c == "|":
            cells.append("".join(buf).strip())
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    cells.append("".join(buf).strip())
    return cells


def is_delim_row(line: str) -> bool:
    cells = split_row(line)
    return bool(cells) and all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c != "")


def alignments(line: str) -> list[str]:
    out = []
    for c in split_row(line):
        left, right = c.startswith(":"), c.endswith(":")
        out.append("center" if left and right else "right" if right else "left")
    return out


# --------------------------------------------------------------------------- blocks

def convert(md: str) -> tuple[str, str]:
    """Return (title, body_html)."""
    lines = md.replace("\r\n", "\n").split("\n")
    out: list[str] = []
    title = ""
    i, n = 0, len(lines)

    def close_lists(stack: list[str]) -> None:
        while stack:
            out.append(f"</{stack.pop()}>")

    list_stack: list[str] = []
    list_indents: list[int] = []

    while i < n:
        line = lines[i]

        # ---- fenced code
        m = re.match(r"^\s*```+\s*([A-Za-z0-9_+-]*)\s*$", line)
        if m:
            close_lists(list_stack); list_indents.clear()
            lang = m.group(1)
            i += 1
            buf = []
            while i < n and not re.match(r"^\s*```+\s*$", lines[i]):
                buf.append(lines[i])
                i += 1
            i += 1
            src = chr(10).join(buf)
            if lang.lower() == "mermaid":
                # Rendered client-side by the headless browser - see wrap(). If mermaid.js cannot
                # be reached, the element is left untouched and the diagram source shows as a code
                # block, which is the same output this tool produced before mermaid was supported.
                out.append(f'<pre class="mermaid">{html.escape(src, quote=False)}</pre>')
                continue
            cls = f' class="lang-{lang}"' if lang else ""
            out.append(f"<pre{cls}><code>{html.escape(src, quote=False)}</code></pre>")
            continue

        # ---- table
        if "|" in line and i + 1 < n and is_delim_row(lines[i + 1]) and line.strip():
            close_lists(list_stack); list_indents.clear()
            head = split_row(line)
            aligns = alignments(lines[i + 1])
            i += 2
            body = []
            while i < n and lines[i].strip() and "|" in lines[i]:
                body.append(split_row(lines[i]))
                i += 1
            out.append('<div class="tw"><table><thead><tr>')
            for j, c in enumerate(head):
                a = aligns[j] if j < len(aligns) else "left"
                out.append(f'<th class="a-{a}">{inline(c)}</th>')
            out.append("</tr></thead><tbody>")
            for row in body:
                out.append("<tr>")
                for j, c in enumerate(row):
                    a = aligns[j] if j < len(aligns) else "left"
                    out.append(f'<td class="a-{a}">{inline(c)}</td>')
                out.append("</tr>")
            out.append("</tbody></table></div>")
            continue

        # ---- blank
        if not line.strip():
            close_lists(list_stack); list_indents.clear()
            i += 1
            continue

        # ---- horizontal rule
        if re.fullmatch(r"\s*([-*_])\s*(\1\s*){2,}", line):
            close_lists(list_stack); list_indents.clear()
            out.append("<hr>")
            i += 1
            continue

        # ---- heading
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            close_lists(list_stack); list_indents.clear()
            lvl, txt = len(m.group(1)), m.group(2).strip()
            if lvl == 1 and not title:
                title = re.sub(r"<[^>]+>", "", inline(txt))
            out.append(f"<h{lvl}>{inline(txt)}</h{lvl}>")
            i += 1
            continue

        # ---- blockquote
        if re.match(r"^\s*>\s?", line):
            close_lists(list_stack); list_indents.clear()
            buf = []
            while i < n and re.match(r"^\s*>\s?", lines[i]):
                buf.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            _, inner = convert("\n".join(buf))
            out.append(f"<blockquote>{inner}</blockquote>")
            continue

        # ---- list item
        m = re.match(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$", line)
        if m:
            indent = len(m.group(1).expandtabs(4))
            ordered = bool(re.match(r"\d", m.group(2)))
            tag = "ol" if ordered else "ul"
            content = m.group(3)

            while list_indents and indent < list_indents[-1]:
                out.append(f"</{list_stack.pop()}>")
                list_indents.pop()
            if not list_stack or indent > (list_indents[-1] if list_indents else -1):
                out.append(f"<{tag}>")
                list_stack.append(tag)
                list_indents.append(indent)
            elif list_stack[-1] != tag:
                out.append(f"</{list_stack.pop()}>")
                out.append(f"<{tag}>")
                list_stack.append(tag)

            task = re.match(r"^\[([ xX])\]\s+(.*)$", content)
            if task:
                checked = " checked" if task.group(1).lower() == "x" else ""
                out.append(f'<li class="task"><input type="checkbox" disabled{checked}> '
                           f"{inline(task.group(2))}</li>")
            else:
                out.append(f"<li>{inline(content)}</li>")

            # continuation lines belonging to this item
            i += 1
            cont = []
            while i < n and lines[i].strip() and not re.match(r"^(\s*)([-*+]|\d+[.)])\s+", lines[i]) \
                    and not re.match(r"^\s*(#{1,6}\s|```)", lines[i]) \
                    and len(lines[i]) - len(lines[i].lstrip()) > indent:
                cont.append(lines[i].strip())
                i += 1
            if cont:
                out[-1] = out[-1][:-5] + " " + inline(" ".join(cont)) + "</li>"
            continue

        # ---- paragraph
        close_lists(list_stack); list_indents.clear()
        buf = [line.strip()]
        i += 1
        while i < n and lines[i].strip() and not re.match(
                r"^\s*(#{1,6}\s|```|>|([-*+]|\d+[.)])\s|([-*_])\s*\3\s*\3)", lines[i]) \
                and not ("|" in lines[i] and i + 1 < n and is_delim_row(lines[i + 1])):
            buf.append(lines[i].strip())
            i += 1
        out.append(f"<p>{inline(' '.join(buf))}</p>")

    close_lists(list_stack)
    return title, "\n".join(out)


# --------------------------------------------------------------------------- styling

CSS = """
@page { size: A4; margin: 18mm 16mm 20mm 16mm; }
* { box-sizing: border-box; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body {
  margin: 0; color: #16161a; background: #fff;
  font: 10.5pt/1.55 "Segoe UI", -apple-system, system-ui, Roboto, Helvetica, Arial, sans-serif;
}
code, pre, .mono { font-family: "Cascadia Mono", Consolas, "SF Mono", Menlo, monospace; }

h1 { font-size: 21pt; line-height: 1.2; letter-spacing: -.01em; margin: 0 0 4pt; }
h2 { font-size: 14pt; margin: 20pt 0 7pt; padding-bottom: 3pt; border-bottom: .8pt solid #d8d8d2;
     break-after: avoid; page-break-after: avoid; }
h3 { font-size: 11.6pt; margin: 14pt 0 5pt; break-after: avoid; page-break-after: avoid; }
h4 { font-size: 10.5pt; margin: 11pt 0 4pt; color: #35353a; break-after: avoid; }
h2 + *, h3 + * { break-before: avoid; page-break-before: avoid; }

p { margin: 0 0 7pt; orphans: 3; widows: 3; }
ul, ol { margin: 0 0 8pt; padding-left: 17pt; }
li { margin: 0 0 3pt; }
li.task { list-style: none; margin-left: -14pt; }
li.task input { margin-right: 5pt; }

a { color: #1c5cab; text-decoration: none; }
hr { border: 0; border-top: .8pt solid #e2e2dc; margin: 14pt 0; }

code {
  font-size: 9pt; background: #f2f2ee; border: .5pt solid #e2e2dc;
  border-radius: 2pt; padding: .5pt 3pt; word-break: break-word;
}
pre {
  font-size: 8.6pt; line-height: 1.45; background: #f7f7f4; border: .5pt solid #e2e2dc;
  border-left: 2pt solid #c3c2b7; border-radius: 3pt; padding: 7pt 9pt; margin: 0 0 9pt;
  white-space: pre-wrap; word-wrap: break-word; overflow-wrap: anywhere;
  break-inside: avoid; page-break-inside: avoid;
}
pre code { background: none; border: 0; padding: 0; font-size: inherit; }

blockquote {
  margin: 0 0 9pt; padding: 6pt 10pt; background: #f7f7f4;
  border-left: 2pt solid #c3c2b7; border-radius: 0 3pt 3pt 0;
}
blockquote p:last-child { margin-bottom: 0; }

.tw { margin: 0 0 10pt; }
table { width: 100%; border-collapse: collapse; font-size: 8.8pt; table-layout: auto; }
th, td {
  border: .5pt solid #dcdcd6; padding: 3.5pt 5pt; vertical-align: top;
  /* break-word, not anywhere: `anywhere` lets the column shrink to one character wide,
     which hyphenates headers mid-syllable ("Requireme / nt"). */
  overflow-wrap: break-word; word-break: normal; hyphens: none;
}
th { white-space: nowrap; }
/* ...but let a genuinely long header wrap rather than blow out the table width. */
th.wrap, table.wide th { white-space: normal; }
th { background: #f2f2ee; font-weight: 600; text-align: left; }
tbody tr:nth-child(even) { background: #fafaf8; }
td code, th code { font-size: 8pt; padding: 0 2pt; }
.a-right { text-align: right; }
.a-center { text-align: center; }
/* Long tables may break across pages, but never mid-row. */
table { break-inside: auto; }
tr { break-inside: avoid; page-break-inside: avoid; }
thead { display: table-header-group; }

.docmeta {
  margin: 0 0 16pt; padding-bottom: 8pt; border-bottom: 1.2pt solid #16161a;
  font-size: 8.6pt; color: #6a6a63;
}
"""


MERMAID_CDN = "https://cdnjs.cloudflare.com/ajax/libs/mermaid/10.9.1/mermaid.min.js"

# Loaded only when a document actually contains a mermaid block. The script tag is ordinary
# network I/O by the renderer; offline, mermaid never initializes, the <pre class="mermaid">
# keeps its text, and the diagram degrades to a readable source listing.
MERMAID_HEAD = f"""<style>
pre.mermaid {{ background: none; border: none; padding: 0; text-align: center;
               break-inside: avoid; page-break-inside: avoid; margin: 18px 0; }}
pre.mermaid svg {{ max-width: 100%; height: auto; }}
</style>
<script src="{MERMAID_CDN}"></script>
<script>
  window.addEventListener("load", function () {{
    if (!window.mermaid) return;            // offline - leave the source visible
    mermaid.initialize({{ startOnLoad: false, theme: "neutral",
                         flowchart: {{ htmlLabels: true, curve: "basis" }} }});
    mermaid.run({{ querySelector: "pre.mermaid" }});
  }});
</script>"""


def wrap(title: str, body: str, subtitle: str) -> str:
    extra = MERMAID_HEAD if 'class="mermaid"' in body else ""
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>{html.escape(title or 'Document')}</title>
<style>{CSS}</style>{extra}</head>
<body>
<div class="docmeta">{html.escape(subtitle)}</div>
{body}
</body></html>"""


# --------------------------------------------------------------------------- browser

def find_browser(explicit: str | None) -> str | None:
    if explicit and Path(explicit).exists():
        return explicit
    for c in (
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    ):
        if Path(c).exists():
            return c
    for c in ("msedge", "google-chrome", "chromium", "chromium-browser", "chrome"):
        p = shutil.which(c)
        if p:
            return p
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--out-dir")
    ap.add_argument("--browser")
    ap.add_argument("--keep-html", action="store_true")
    args = ap.parse_args()

    browser = find_browser(args.browser)
    if not browser:
        print("No Chromium-based browser found. Install Edge/Chrome or pass --browser <path>.",
              file=sys.stderr)
        return 2
    print(f"renderer: {browser}\n")

    rc = 0
    for spec in args.files:
        src = Path(spec)
        if not src.is_file():
            print(f"  skip   {spec} (not a file)", file=sys.stderr)
            rc = 1
            continue

        md = src.read_text(encoding="utf-8")
        title, body = convert(md)
        subtitle = f"{src.stem.replace('-', ' ')}  \u00b7  generated from {src.name}"
        page = wrap(title or src.stem, body, subtitle)

        out_dir = Path(args.out_dir) if args.out_dir else src.parent
        out_dir.mkdir(parents=True, exist_ok=True)
        pdf = out_dir / (src.stem + ".pdf")

        if args.keep_html:
            tmp_html = out_dir / (src.stem + ".html")
            tmp_html.write_text(page, encoding="utf-8")
            html_path = tmp_html
        else:
            fd = tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, encoding="utf-8")
            fd.write(page)
            fd.close()
            html_path = Path(fd.name)

        # Chromium's --print-to-pdf= mishandles output paths containing spaces, so always
        # render to a space-free temp path and move the result into place afterwards.
        tmp_pdf = Path(tempfile.gettempdir()) / f"md2pdf_{abs(hash(str(pdf.resolve())))}.pdf"
        # A throwaway --user-data-dir is essential: without it, headless Edge contends with an
        # already-running browser's profile and can hang indefinitely instead of exiting.
        # The disable-* flags stop it reaching the network for sync/telemetry on startup.
        profile = Path(tempfile.mkdtemp(prefix="md2pdf_profile_"))
        # Mermaid has to be fetched and then draw every diagram before the page is printed, so
        # give those documents a longer virtual clock. Plain documents keep the fast path.
        budget = 25000 if 'class="mermaid"' in page else 8000
        cmd = [browser, "--headless=new", "--disable-gpu", "--no-sandbox",
               f"--user-data-dir={profile}",
               "--no-first-run", "--no-default-browser-check",
               "--disable-background-networking", "--disable-sync",
               "--disable-extensions", "--disable-default-apps",
               "--no-pdf-header-footer", f"--virtual-time-budget={budget}",
               f"--print-to-pdf={tmp_pdf}", html_path.resolve().as_uri()]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            print(f"  FAILED {src.name}: renderer timed out after 120s", file=sys.stderr)
            shutil.rmtree(profile, ignore_errors=True)
            rc = 1
            continue
        shutil.rmtree(profile, ignore_errors=True)

        if tmp_pdf.is_file() and tmp_pdf.stat().st_size > 1000:
            pdf.unlink(missing_ok=True)
            shutil.move(str(tmp_pdf), str(pdf))

        if not args.keep_html:
            try:
                html_path.unlink()
            except OSError:
                pass

        if pdf.is_file() and pdf.stat().st_size > 1000:
            print(f"  ok     {pdf.name}  ({pdf.stat().st_size // 1024} KB)")
        else:
            print(f"  FAILED {src.name}: {(p.stderr or '').strip()[:200]}", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
