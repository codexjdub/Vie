#!/usr/bin/env python3
"""Checks Vie's Vim spec files against real Vim.

Each spec runs in a fresh headless Vim (`vim -Nu NONE -es`) with the settings Vie's Vim
mode uses. Keys are fed with feedkeys(..., "xt"), as if typed, so undo steps match
interactive use. Prints every spec whose result differs from Vim.

    scripts/vim-oracle.py                  check all files in Tests/VieVimTests/Specs
    scripts/vim-oracle.py motions          only files whose name contains "motions"
    scripts/vim-oracle.py --show           also print Vim's result for every spec
    scripts/vim-oracle.py --fix FILES      rewrite differing specs with Vim's result (review first!)

Spec format, one per line (# starts a comment):

    "before" → keys → "after"

Keys in angle brackets are special only for known names (<Esc>, <CR>, <C-x>...), so regex
atoms like \\< stay literal. Texts are quoted; `|` marks the cursor (the character under it in Normal mode), `\\|` is a
literal bar, and \\n, \\t, \\\\ and \\" are escapes. Keys use Vim notation (<Esc>, <CR>,
<C-v>, <Space>, <lt>). An optional fourth field holds extra Vim settings to apply first,
such as `set ignorecase`; specs that need Vie-only behavior can say `vie-only` there to be
skipped here.
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPECS = os.path.join(ROOT, "Tests", "VieVimTests", "Specs")

# Keep in sync with VimOptions defaults in Sources/VieVim.
SETTINGS = (
    "set nocompatible encoding=utf-8 autoindent nojoinspaces backspace=indent,eol,start "
    "tabstop=4 shiftwidth=4 softtabstop=0 expandtab whichwrap=b,s nomore"
)


def unquote(field):
    field = field.strip()
    if len(field) < 2 or field[0] != '"' or field[-1] != '"':
        raise ValueError(f"expected a quoted string: {field!r}")
    out, cursor, i, body = [], None, 0, field[1:-1]
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            n = body[i + 1]
            out.append({"n": "\n", "t": "\t", "|": "|", "\\": "\\", '"': '"'}.get(n, "\\" + n))
            i += 2
            continue
        if c == "|" and cursor is None:
            cursor = len("".join(out).encode("utf-8"))
        else:
            out.append(c)
        i += 1
    return "".join(out), cursor or 0


def quote(text, cursor):
    data = text.encode("utf-8")
    shown = data[:cursor].decode("utf-8", "replace") + "|" + data[cursor:].decode("utf-8", "replace")
    escaped = []
    for i, c in enumerate(shown):
        bar = i == len(data[:cursor].decode("utf-8", "replace"))
        if c == "|" and not bar:
            escaped.append("\\|")
        else:
            escaped.append({"\n": "\\n", "\t": "\\t", "\\": "\\\\", '"': '\\"'}.get(c, c))
    return '"' + "".join(escaped) + '"'


# Keep in sync with VimKey.parse in Sources/VieVim.
KEY_NAMES = {"esc", "cr", "enter", "return", "bs", "tab", "space", "lt", "bar", "bslash", "del",
             "up", "down", "left", "right", "home", "end", "pageup", "pagedown", "nl"}


def special_key(keys, i):
    """Length of a special key like <Esc> or <C-v> at i, or 0."""
    j = keys.find(">", i)
    if j <= i + 1:
        return 0
    name = keys[i + 1:j].lower()
    if name in KEY_NAMES or (len(name) == 3 and name.startswith("c-")):
        return j - i + 1
    return 0


def vim_keys(keys):
    """Our notation to a Vim double-quoted string body."""
    out, i = [], 0
    while i < len(keys):
        c = keys[i]
        n = special_key(keys, i) if c == "<" else 0
        if n:
            out.append("\\" + keys[i:i + n])
            i += n
            continue
        out.append({"\\": "\\\\", '"': '\\"'}.get(c, c))
        i += 1
    return "".join(out)


def parse(path):
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split(" → ")
        if len(parts) not in (3, 4):
            raise ValueError(f"{path}:{n}: expected 3 or 4 fields separated by ' → '")
        before, cursor = unquote(parts[0])
        after, after_cursor = unquote(parts[2])
        extra = parts[3].strip() if len(parts) == 4 else ""
        yield n, before, cursor, parts[1].strip(), after, after_cursor, extra


def run_vim(text, cursor, keys, extra):
    data = text.encode("utf-8")
    before = data[:cursor]
    line = before.count(b"\n") + 1
    col = len(before) - (before.rfind(b"\n") + 1) + 1
    with tempfile.TemporaryDirectory() as tmp:
        src, out = os.path.join(tmp, "in.txt"), os.path.join(tmp, "out.txt")
        with open(src, "wb") as f:
            f.write(data)
        # readfile(..., "b") keeps a trailing empty line, so the buffer's lines are exactly the
        # spec text split at newlines.
        cmds = [SETTINGS, f'call setline(1, readfile("{src}", "b"))']
        if extra:
            cmds.append(extra)
        cmds += [
            f"call cursor({line}, {col})",
            f'call feedkeys("{vim_keys(keys)}", "xt")',
            f'call writefile([string(getpos("."))] + getline(1, "$"), "{out}", "b")',
            "qa!",
        ]
        args = ["vim", "-Nu", "NONE", "-i", "NONE", "-n", "-es"]
        for c in cmds:
            args += ["-c", c]
        subprocess.run(args, check=False, timeout=20)
        lines = open(out, "rb").read().decode("utf-8").split("\n")
    pos = [int(x) for x in re.findall(r"-?\d+", lines[0])]  # getpos(): [buf, line, col, off]
    result = "\n".join(lines[1:])  # writefile(..., "b") adds no final newline
    rb = result.encode("utf-8")
    offsets = [0]
    for i, b in enumerate(rb):
        if b == 0x0A:
            offsets.append(i + 1)
    row = min(pos[1], len(offsets)) - 1
    return result, min(offsets[row] + pos[2] - 1, len(rb))


def main():
    show = "--show" in sys.argv
    fix = "--fix" in sys.argv
    filters = [a for a in sys.argv[1:] if not a.startswith("--")]
    files = sorted(f for f in os.listdir(SPECS) if f.endswith(".vimspec"))
    if filters:
        files = [f for f in files if any(x in f for x in filters)]
    total = failed = skipped = 0
    for name in files:
        path = os.path.join(SPECS, name)
        fixes = {}
        for n, before, cursor, keys, after, after_cursor, extra in parse(path):
            if "vie-only" in extra:
                skipped += 1
                continue
            total += 1
            got, got_cursor = run_vim(before, cursor, keys, extra.replace("vie-only", ""))
            ok = got == after and got_cursor == after_cursor
            if not ok:
                failed += 1
                fixes[n] = quote(got, got_cursor)
            if not ok or show:
                mark = "ok  " if ok else "DIFF"
                print(f"{mark} {name}:{n}: {quote(before, cursor)} → {keys} → {quote(got, got_cursor)}"
                      + ("" if ok else f"   (spec says {quote(after, after_cursor)})"))
        if fix and fixes:
            lines = open(path, encoding="utf-8").read().split("\n")
            for n, new_after in fixes.items():
                parts = lines[n - 1].split(" → ")
                parts[2] = new_after
                lines[n - 1] = " → ".join(parts)
            open(path, "w", encoding="utf-8").write("\n".join(lines))
            print(f"rewrote {len(fixes)} specs in {name}")
    print(f"{total - failed}/{total} specs match Vim" + (f", {skipped} Vie-only skipped" if skipped else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
