#!/usr/bin/env python3
"""Generate en/cs .lproj/Localizable.strings from Resources/Localizable.xcstrings.

Full Xcode compiles .xcstrings itself; the Command Line Tools cannot, so build.sh uses this instead.
It also FAILS the build when the sources use a string the catalog lacks (or lacks a Czech translation),
so a missing translation can never ship silently.

usage: gen_lproj.py <catalog.xcstrings> <sources dir> <output Resources dir>
"""
import glob
import json
import os
import re
import sys


def escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main() -> int:
    catalog_path, sources, out = sys.argv[1:4]
    catalog = json.load(open(catalog_path, encoding="utf-8"))
    strings = catalog["strings"]

    used = set()
    for path in glob.glob(os.path.join(sources, "**", "*.swift"), recursive=True):
        text = open(path, encoding="utf-8").read()
        for m in re.finditer(r'\bL\(\s*"((?:[^"\\]|\\.)*)"', text):
            used.add(m.group(1).encode().decode("unicode_escape") if "\\" in m.group(1) else m.group(1))

    missing = sorted(k for k in used if k not in strings)
    untranslated = sorted(k for k in used if k in strings and
                          strings[k].get("localizations", {}).get("cs", {}).get("stringUnit", {}).get("value", "") == "")
    unused = sorted(k for k in strings if k not in used)
    if missing or untranslated:
        for k in missing:
            print(f"error: string not in catalog: {k!r}", file=sys.stderr)
        for k in untranslated:
            print(f"error: no Czech translation: {k!r}", file=sys.stderr)
        return 1
    if unused:
        print(f"note: {len(unused)} catalog string(s) are not used by the code: {unused[:3]}...", file=sys.stderr)

    for lang in ("en", "cs"):
        d = os.path.join(out, f"{lang}.lproj")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
            f.write("/* Generated from Localizable.xcstrings by Scripts/gen_lproj.py. Do not edit. */\n")
            for key in sorted(strings):
                # English is the key itself unless the catalog overrides it (used for Czech plural forms,
                # e.g. "%d subagents (2-4)" -> "%d subagents").
                value = strings[key].get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("value")
                if value is None:
                    value = key
                f.write(f'"{escape(key)}" = "{escape(value)}";\n')
    print(f"Localization: {len(strings)} strings, en + cs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
