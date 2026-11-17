#!/usr/bin/env python3
"""Replace em dashes in Sparkle's bundled UI strings with " - ".

Sparkle's own texts ("Xylem 1.1 is now available<dash>you have 1.0", U+2014) use an em
dash with no spaces; Xylem's text rule is a spaced hyphen. Run by
make-dmg.sh on the exported app, before re-signing and notarization.
Usage: sparkle-strings.py <Xylem.app>  - prints how many strings changed.
"""
import glob, plistlib, re, sys

app = sys.argv[1]
changed = 0
pattern = re.compile(r"\s*\u2014\s*")  # re understands \uXXXX
for path in glob.glob(f"{app}/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/*.lproj/*.strings"):
    with open(path, "rb") as f:
        data = plistlib.load(f)
    fixed = {k: pattern.sub(" - ", v) if isinstance(v, str) else v for k, v in data.items()}
    n = sum(1 for k in data if fixed[k] != data[k])
    if n:
        with open(path, "wb") as f:
            plistlib.dump(fixed, f, fmt=plistlib.FMT_BINARY)
        changed += n
print(changed)
