#!/usr/bin/env python3
"""Render RELEASE_NOTES.md into a small HTML fragment for the Sparkle appcast.

Sparkle's standard update UI displays the appcast item's <description> as
HTML in the "Software Update" alert. This script does a minimal Markdown
subset -> HTML conversion (headings, bullet lists, paragraphs) so authors can
write plain Markdown in RELEASE_NOTES.md without pulling in a Markdown
dependency.

Usage:
  python3 Scripts/render_release_notes.py RELEASE_NOTES.md

Prints the HTML fragment to stdout. Prints nothing (exit 0) if the file is
missing or contains only the placeholder/template text.
"""
import html
import sys

if len(sys.argv) != 2:
    print("usage: render_release_notes.py <path>", file=sys.stderr)
    sys.exit(1)

path = sys.argv[1]

try:
    with open(path, encoding="utf-8") as f:
        raw = f.read()
except FileNotFoundError:
    sys.exit(0)

lines = [line.rstrip() for line in raw.splitlines()]

html_parts = []
in_list = False


def close_list():
    global in_list
    if in_list:
        html_parts.append("</ul>")
        in_list = False


in_comment = False
for line in lines:
    stripped = line.strip()
    if in_comment:
        if stripped.endswith("-->"):
            in_comment = False
        continue
    if stripped.startswith("<!--"):
        if not stripped.endswith("-->"):
            in_comment = True
        continue
    if not stripped:
        continue
    if stripped.startswith("# "):
        close_list()
        html_parts.append(f"<h2>{html.escape(stripped[2:].strip())}</h2>")
    elif stripped.startswith(("- ", "* ")):
        if not in_list:
            html_parts.append("<ul>")
            in_list = True
        html_parts.append(f"<li>{html.escape(stripped[2:].strip())}</li>")
    else:
        close_list()
        html_parts.append(f"<p>{html.escape(stripped)}</p>")

close_list()

output = "\n".join(html_parts).strip()
PLACEHOLDER = "<ul>\n<li>No notable changes.</li>\n</ul>"
if output and output != PLACEHOLDER:
    print(output)
