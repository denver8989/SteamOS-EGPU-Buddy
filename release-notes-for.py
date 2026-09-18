#!/usr/bin/env python3
"""Print the RELEASE-NOTES.md section of ONE version (a section starts with 'X.Y.Z[-tag] — ' at the start of a line)."""
import re, sys
ver, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
heads = [(m.start(), m.group(1)) for m in re.finditer(r"^(\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?) — ", text, re.M)]
for i, (pos, v) in enumerate(heads):
    if v == ver:
        end = heads[i + 1][0] if i + 1 < len(heads) else len(text)
        print(text[pos:end].strip()); sys.exit(0)
sys.exit(f"no section for {ver} in {path}")
