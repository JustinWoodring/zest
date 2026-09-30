#!/usr/bin/env python3
"""Render real zest command sessions into GIFs for the README and the website.

Every frame is generated from the *actual* output of running the built zest
binary against local git fixtures, so the recordings can never drift from
what the tool really prints. Frames are composited with Pillow and assembled
into looping GIFs with a typewriter reveal and a blinking block cursor.

Usage:  zig build && python3 scripts/make-gifs.py
Output: assets/gifs/{install,inspect,update}.gif
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parent.parent
ZEST = REPO / "zig-out" / "bin" / ("zest.exe" if os.name == "nt" else "zest")
OUT_DIR = REPO / "assets" / "gifs"

FONT_REG = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf"
FONT_BOLD = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf"
if not os.path.exists(FONT_REG):  # fallback
    FONT_REG = "/usr/share/fonts/TTF/NotoSansMono-Regular.ttf"
    FONT_BOLD = "/usr/share/fonts/TTF/NotoSansMono-Bold.ttf"

# Palette aligned with www/index.html.
BG = (11, 16, 22)
BAR = (22, 27, 34)
TEXT = (230, 237, 243)
MUTED = (139, 152, 165)
ACCENT = (45, 212, 167)
WARN = (247, 164, 29)
PROMPT = (45, 212, 167)

FS = 19
PAD = 18
BAR_H = 30
LINE_H = 26
COLS_W = 92
ROWS = 22

FRAME_MS = 45
TAIL_PAUSE = 35


def font(size=FS, bold=False):
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REG, size)


def run(cmd, cwd, env=None):
    """Run a command, returning combined output as a list of lines."""
    e = dict(os.environ)
    if env:
        e.update(env)
    p = subprocess.run(cmd, cwd=cwd, env=e, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, errors="replace")
    lines = [ln.rstrip() for ln in p.stdout.splitlines()]
    while lines and not lines[-1].strip():
        lines.pop()
    return lines, p.returncode


class Line:
    """A rendered line: a list of (text, color) segments."""
    def __init__(self, segs):
        self.segs = segs


# Machine-specific strings replaced in the recording so the demo reads clean.
REPLACEMENTS = []


def add_replacement(real: str, shown: str):
    REPLACEMENTS.append((real, shown))


def scrub(text: str) -> str:
    for real, shown in REPLACEMENTS:
        text = text.replace(real, shown)
    return text


def prompt_cmd(cmd, cwd_label=None):
    return Line([("$ ", PROMPT), (scrub(cmd), TEXT)])


def out_lines(raw):
    lines = []
    for ln in raw:
        ln = scrub(ln) or " "
        col = MUTED
        if ln.startswith(("installed ", "updated ", "verdict", "zest self-updated", "upstream")):
            col = ACCENT
        elif ln.startswith(("error:", "zest:")):
            col = WARN
        lines.append(Line([(ln, col)]))
    return lines


def make_fixture(root: Path, name: str, version: str, exe: str, extra_note=""):
    """Create a git fixture that zest can actually install.

    `zig init` generates a build.zig.zon with a content-derived fingerprint
    that Zig 0.16 validates, so we start from that and only override the
    fields the demo needs.
    """
    d = root / name
    d.mkdir(parents=True)
    subprocess.run(["zig", "init"], cwd=d, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (d / "build.zig").write_text(
        "const std = @import(\"std\");\n"
        "pub fn build(b: *std.Build) void {\n"
        "    const t = b.standardTargetOptions(.{});\n"
        "    const o = b.standardOptimizeOption(.{});\n"
        "    const exe = b.addExecutable(.{ .name = \"%s\", .root_module = b.createModule(.{\n"
        "        .root_source_file = b.path(\"src/main.zig\"), .target = t, .optimize = o }) });\n"
        "    b.installArtifact(exe);\n"
        "}\n" % exe
    )
    (d / "src" / "root.zig").unlink(missing_ok=True)
    zon = (d / "build.zig.zon").read_text()
    zon = re.sub(r'\.name = \.[A-Za-z0-9_]+,', '.name = .%s,' % name.replace("-", "_"), zon)
    zon = re.sub(r'\.version = "[^"]*",', '.version = "%s",' % version, zon)
    zon = re.sub(r'\.minimum_zig_version = "[^"]*",',
                 '.minimum_zig_version = "0.16.0",', zon)
    (d / "build.zig.zon").write_text(zon)
    (d / "README.md").write_text(
        "# %s\n\n%sA demo tool used to record zest for the README.\n" % (name, extra_note)
    )
    (d / "LICENSE").write_text("MIT License\n\nPermission is hereby granted, free of charge\n")
    (d / "src" / "main.zig").write_text(
        "const std = @import(\"std\");\n"
        "pub fn main(init: std.process.Init) !void {\n"
        "    var buf: [128]u8 = undefined;\n"
        "    var w: std.Io.File.Writer = .init(.stdout(), init.io, &buf);\n"
        "    const args = try init.minimal.args.toSlice(init.arena.allocator());\n"
        "    for (args[1..]) |a|\n"
        "        try w.interface.print(\"arg:{s}\\n\", .{a});\n"
        "    try w.interface.print(\"@NAME@ @VER@\\n\", .{});\n"
        "    try w.interface.flush();\n}\n".replace("@NAME@", name).replace("@VER@", version)
    )
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=d, check=True)
    subprocess.run(["git", "add", "-A"], cwd=d, check=True)
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                    "commit", "-qm", "init"], cwd=d, check=True)
    subprocess.run(["git", "tag", "v%s" % version], cwd=d, check=True)
    return d


def build_frames(scene_title, lines, cursor_line=None):
    """Return PIL frames revealing `lines`, typing commands in and blinking a cursor."""
    f_reg, f_bold = font(FS, False), font(FS, True)
    f_small = font(14, False)
    probe = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    cw = probe.textlength("M", font=f_reg)
    W = int(PAD * 2 + cw * COLS_W)
    rows = min(ROWS, len(lines) + 1)
    H = BAR_H + PAD * 2 + LINE_H * rows

    def line_text(line):
        return "".join(t for t, _ in line.segs)

    def line_width(dr, line, max_chars=None):
        total, used = 0, 0
        for i, (t, _) in enumerate(line.segs):
            take = len(t) if max_chars is None else max(0, min(len(t), max_chars - used))
            if take <= 0:
                break
            total += dr.textlength(t[:take], font=f_bold if i == 0 else f_reg)
            used += take
        return total

    def draw_line(dr, y, line, max_chars=None):
        x, used = PAD, 0
        for i, (t, col) in enumerate(line.segs):
            take = len(t) if max_chars is None else max(0, min(len(t), max_chars - used))
            if take <= 0:
                break
            fnt = f_bold if i == 0 else f_reg
            seg = t[:take]
            dr.text((x, y), seg, font=fnt, fill=col)
            x += dr.textlength(seg, font=fnt)
            used += take

    def render(nlines, last_max, cursor_on):
        img = Image.new("RGB", (W, H), BG)
        dr = ImageDraw.Draw(img)
        dr.rectangle([0, 0, W, BAR_H], fill=BAR)
        for i, col in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
            dr.ellipse([14 + i * 18, BAR_H // 2 - 5, 24 + i * 18, BAR_H // 2 + 5], fill=col)
        tw = dr.textlength(scene_title, font=f_small)
        dr.text((W / 2 - tw / 2, BAR_H // 2 - 9), scene_title, font=f_small, fill=MUTED)
        start = max(0, nlines - rows)
        for i in range(start, nlines):
            y = BAR_H + PAD + (i - start) * LINE_H
            draw_line(dr, y, lines[i], last_max if i == nlines - 1 else None)
        if cursor_on:
            last = nlines - 1
            y = BAR_H + PAD + (last - start) * LINE_H
            wpx = line_width(dr, lines[last], last_max)
            dr.rectangle([PAD + wpx + 2, y, PAD + wpx + 2 + int(cw * 0.6), y + FS + 4], fill=ACCENT)
        return img

    frames = []
    first = line_text(lines[0])
    for k in range(1, len(first) + 1, 2):
        frames.append(render(1, k, True))
    for n in range(2, len(lines) + 1):
        frames.append(render(n, None, True))
    for _ in range(8):
        frames.append(render(len(lines), None, False))
    for _ in range(24):
        frames.append(render(len(lines), None, True))
    return frames


def save_gif(frames, path, fps_ms=FRAME_MS, tail=TAIL_PAUSE):
    path.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        path, save_all=True, append_images=frames[1:], loop=0,
        duration=[fps_ms] * (len(frames) - tail) + [tail * (len(frames) - 1)] * tail,
        optimize=True, disposal=2,
    )
    print(f"wrote {path.relative_to(REPO)}  ({len(frames)} frames, {path.stat().st_size//1024} KB)")


def main():
    if not ZEST.exists():
        sys.exit("build zest first: zig build")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="zest-gif-"))
    try:
        env = {"XDG_DATA_HOME": str(work / "local" / "share")}
        tool = make_fixture(work / "tools", "mytool", "1.4.2", "mytool",
                            "A demo tool used to record zest for the README.\n\n")
        url = "file://" + str(tool)
        z = str(ZEST)
        data_dir = str(work / "xdg")
        # Clean up machine-specific paths in the recording.
        add_replacement(str(tool), "github.com/user/mytool")
        add_replacement(str(work), "/home/you")
        add_replacement(z, "zest")
        add_replacement(str(work / "local"), "~/.local")

        def rec(cmd, cwd=work):
            lines, rc = run(cmd, cwd=cwd, env=env)
            return lines

        # --- scene 1: install, list, run -----------------------------------
        s1 = []
        s1.append(prompt_cmd(f"zest install {url}"))
        s1 += out_lines(rec([z, "install", url], work))
        s1.append(prompt_cmd("zest list"))
        s1 += out_lines(rec([z, "list"], work))
        s1.append(prompt_cmd("zest run mytool --help"))
        s1 += out_lines(rec([z, "run", "mytool", "--help"], work))
        save_gif(build_frames("zest: install, list, run", s1), OUT_DIR / "install.gif")

        # --- scene 2: inspect ---------------------------------------------
        s2 = []
        s2.append(prompt_cmd("zest inspect ."))
        s2 += out_lines(rec([z, "inspect", "."], cwd=tool))
        s2.append(prompt_cmd(f"zest inspect {url}"))
        s2 += out_lines(rec([z, "inspect", url], work))
        save_gif(build_frames("zest: inspect", s2), OUT_DIR / "inspect.gif")

        # --- scene 3: update (new tag lands) ------------------------------
        (tool / "src" / "main.zig").write_text(
            (tool / "src" / "main.zig").read_text().replace("1.4.2", "1.5.0"))
        subprocess.run(["git", "add", "-A"], cwd=tool, check=True)
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "-qm", "v1.5.0"], cwd=tool, check=True)
        subprocess.run(["git", "tag", "v1.5.0"], cwd=tool, check=True)
        s3 = []
        s3.append(prompt_cmd("zest update mytool"))
        s3 += out_lines(rec([z, "update", "mytool"], work))
        s3.append(prompt_cmd("zest run mytool"))
        s3 += out_lines(rec([z, "run", "mytool"], work))
        save_gif(build_frames("zest: update to the latest tag", s3), OUT_DIR / "update.gif")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
