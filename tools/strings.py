#!/usr/bin/env python3
"""Keeps the translation files in sync with the source code.

Every user-facing string in the code is wrapped in L("English text"). This script:
  * collects those keys from Sources/ (in order of appearance, grouped by file);
  * rewrites Resources/en.lproj/Localizable.strings — the template for new languages;
  * rewrites every other Resources/<lang>.lproj/Localizable.strings in the same order,
    keeping existing translations and reporting missing or obsolete ones.

    python3 tools/strings.py           update files, list what is missing
    python3 tools/strings.py --check   only check (exit 1 if anything is out of date)

Adding a language: copy en.lproj to <code>.lproj (for example de.lproj), translate the values,
run this script. The app picks the new folder up by itself.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
RESOURCES = ROOT / "Resources"
KEY = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"')
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')


def collect():
    """[(file, [keys])] in order of appearance; a key belongs to the first file that uses it."""
    seen, groups = set(), []
    for path in sorted(SOURCES.rglob("*.swift")):
        keys = []
        # Comment lines are skipped: doc comments show L("…") as an example.
        code = "\n".join(line for line in path.read_text(encoding="utf-8").splitlines()
                         if not line.lstrip().startswith("//"))
        for key in KEY.findall(code):
            if key not in seen:
                seen.add(key)
                keys.append(key)
        if keys:
            groups.append((path.relative_to(ROOT).as_posix(), keys))
    return groups


def load(path):
    table = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            m = ENTRY.match(line)
            if m:
                table[m.group(1)] = m.group(2)
    return table


def render(groups, table):
    lines = []
    for file, keys in groups:
        present = [k for k in keys if k in table]
        if not present:
            continue
        lines.append(f"/* {file} */")
        lines += [f'"{k}" = "{table[k]}";' for k in present]
        lines.append("")
    return "\n".join(lines)


def main():
    check = "--check" in sys.argv
    groups = collect()
    keys = [k for _, ks in groups for k in ks]
    problems = 0
    for lproj in sorted(RESOURCES.glob("*.lproj")):
        path = lproj / "Localizable.strings"
        table = {k: k for k in keys} if lproj.name == "en.lproj" else load(path)
        missing = [k for k in keys if k not in table]
        obsolete = [k for k in load(path) if k not in keys]
        text = render(groups, table)
        changed = not path.exists() or path.read_text(encoding="utf-8") != text
        for k in missing:
            print(f"{lproj.name}: missing  {k!r}")
        for k in obsolete:
            print(f"{lproj.name}: obsolete {k!r}")
        problems += len(missing) + len(obsolete) + (1 if changed and check else 0)
        if changed and check:
            print(f"{lproj.name}: out of date — run tools/strings.py")
        if not check:
            path.write_text(text, encoding="utf-8")
    print(f"{len(keys)} strings, {problems} problem(s)")
    sys.exit(1 if check and problems else 0)


if __name__ == "__main__":
    main()
