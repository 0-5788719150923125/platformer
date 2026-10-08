#!/usr/bin/env python3
"""Render a recorded `terraform apply` session to an animated webp.

Input is the pair of files written by util-linux `script -T <timing> -O <log>`
(see scripts/apply.sh). The playback is retimed so it stays readable and short:

  hold on the command line  ->  head at 1x  ->  middle fast-forwarded
  ->  tail at 1x  ->  hold on the final output

Idle gaps (the approval prompt, "Still creating..." pauses) are capped first, so
the head and tail show output rather than waiting. The total stays under ~30s
no matter how long the apply took.

  python3 scripts/render_apply_webp.py --log LOG --timing TIMING \\
      [--command "terraform apply"] [--out static/apply.webp]
"""

import argparse
import codecs
import os
import re

from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT_PATH = os.path.join(REPO, "scripts/assets/DejaVuSansMono.ttf")
BOLD_PATH = os.path.join(REPO, "scripts/assets/DejaVuSansMono-Bold.ttf")
OUT_PATH = os.path.join(REPO, "static/apply.webp")

# Grid matches the pty size apply.sh forces, so Terraform wraps for this width.
COLS, ROWS = 120, 36
FONT_SIZE = 16
PAD = 16
FRAME_S = 0.1  # 10fps sampling of the retimed playback

# Playback budget (seconds). Worst case: 2.5 + 5 + 8 + 5 + 8 = 28.5s.
START_HOLD = 2.5  # command line alone, before any output
HEAD = 5.0  # first seconds of output at 1x
MIDDLE_MAX = 8.0  # everything between head and tail, compressed into this
TAIL = 5.0  # last seconds of output at 1x
END_HOLD = 8.0  # final screen
IDLE_CAP = 1.0  # longest real gap kept between two chunks of output

BG = (13, 13, 16)
FG = (222, 224, 228)
DIM = (120, 124, 132)
# Standard 8 colors, then their bright variants (SGR 30-37 / 90-97).
PALETTE = [
    (40, 42, 46), (224, 108, 117), (152, 195, 121), (229, 192, 123),
    (97, 175, 239), (198, 120, 221), (86, 182, 194), (222, 224, 228),
    (92, 99, 112), (240, 128, 136), (172, 215, 141), (245, 212, 143),
    (117, 195, 255), (218, 140, 241), (106, 202, 214), (255, 255, 255),
]

# AWS account IDs are masked; same length, so the timing byte counts still line up.
REDACT = [re.compile(rb"(?<!\d)\d{12}(?!\d)")]


class Terminal:
    """Just enough of a VT100 for Terraform's line-oriented output: SGR colors,
    CR/LF/BS/TAB, erase-in-line and a few cursor moves. Other sequences are dropped."""

    def __init__(self, cols):
        self.cols = cols
        self.lines = [[]]
        self.row = self.col = 0
        self.style = (None, None, False)  # fg, bg, bold
        self.state = "text"
        self.seq = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    def feed(self, data):
        for ch in self.decoder.decode(data):
            if self.state == "esc":
                self.state = {"[": "csi", "]": "osc", "(": "skip", ")": "skip"}.get(ch, "text")
                self.seq = ""
            elif self.state == "skip":  # charset designator, e.g. ESC ( B
                self.state = "text"
            elif self.state == "csi":
                if "@" <= ch <= "~":
                    self._csi(self.seq, ch)
                    self.state = "text"
                else:
                    self.seq += ch
            elif self.state == "osc":
                if ch == "\x07":
                    self.state = "text"
                elif ch == "\x1b":  # ESC \ terminator; "esc" swallows the backslash
                    self.state = "esc"
            elif ch == "\x1b":
                self.state = "esc"
            elif ch == "\n":
                self._down()
            elif ch == "\r":
                self.col = 0
            elif ch == "\b":
                self.col = max(0, self.col - 1)
            elif ch == "\t":
                self.col = min(self.cols - 1, (self.col // 8 + 1) * 8)
            elif ch >= " ":
                self._put(ch)

    def _down(self):
        self.row += 1
        while len(self.lines) <= self.row:
            self.lines.append([])

    def _put(self, ch):
        if self.col >= self.cols:  # soft wrap
            self._down()
            self.col = 0
        line = self.lines[self.row]
        while len(line) <= self.col:
            line.append((" ", self.style))
        line[self.col] = (ch, self.style)
        self.col += 1

    def _csi(self, params, final):
        args = [int(p) if p.isdigit() else 0 for p in params.lstrip("?").split(";")]
        n = args[0] or 1
        if final == "m":
            self._sgr(args)
        elif final == "K":
            line = self.lines[self.row]
            if args[0] == 0:
                del line[self.col:]
            elif args[0] == 2:
                line.clear()
        elif final == "G":
            self.col = min(self.cols - 1, n - 1)
        elif final == "C":
            self.col = min(self.cols - 1, self.col + n)
        elif final == "D":
            self.col = max(0, self.col - n)
        elif final == "A":
            self.row = max(0, self.row - n)

    def _sgr(self, args):
        fg, bg, bold = self.style
        i = 0
        while i < len(args):
            a = args[i]
            if a == 0:
                fg, bg, bold = None, None, False
            elif a == 1:
                bold = True
            elif a == 22:
                bold = False
            elif 30 <= a <= 37:
                fg = PALETTE[a - 30]
            elif 90 <= a <= 97:
                fg = PALETTE[a - 90 + 8]
            elif a == 39:
                fg = None
            elif 40 <= a <= 47:
                bg = PALETTE[a - 40]
            elif 100 <= a <= 107:
                bg = PALETTE[a - 100 + 8]
            elif a == 49:
                bg = None
            elif a in (38, 48) and i + 1 < len(args):
                if args[i + 1] == 5 and i + 2 < len(args):
                    color = PALETTE[args[i + 2]] if args[i + 2] < 16 else FG
                    i += 2
                elif args[i + 1] == 2 and i + 4 < len(args):
                    color = tuple(args[i + 2:i + 5])
                    i += 4
                else:
                    color = None
                if a == 38:
                    fg = color
                else:
                    bg = color
            i += 1
        self.style = (fg, bg, bold)

    def screen(self, rows):
        """The visible window: the last `rows` lines, keeping the cursor on screen."""
        top = max(0, self.row - rows + 1)
        return tuple(tuple(line) for line in self.lines[top:top + rows])


def read_session(log_path, timing_path):
    """Return [(seconds, bytes)] chunks from a classic-format `script` recording."""
    with open(log_path, "rb") as f:
        data = f.read()
    data = data[data.index(b"\n") + 1:]  # "Script started on ..." header
    for pattern in REDACT:
        data = pattern.sub(lambda m: b"X" * len(m.group()), data)
    chunks, t, pos = [], 0.0, 0
    with open(timing_path) as f:
        for row in f:
            parts = row.split()
            if len(parts) == 3:  # advanced format: "<type> <delay> <bytes>"
                if parts[0] != "O":
                    continue
                parts = parts[1:]
            delay, size = float(parts[0]), int(parts[1])
            t += min(delay, IDLE_CAP)
            chunks.append((t, data[pos:pos + size]))
            pos += size
    return chunks


def retime(chunks):
    """Map each chunk's (idle-capped) time to playback time. Returns the new
    chunk list, the fast-forward window in playback time, and its speed."""
    total = chunks[-1][0] if chunks else 0.0
    head = min(total, HEAD)
    tail_start = max(head, total - TAIL)
    middle = tail_start - head
    middle_play = min(middle, MIDDLE_MAX)
    speed = middle / middle_play if middle_play else 1.0

    def play(t):
        if t <= head:
            return START_HOLD + t
        if t <= tail_start:
            return START_HOLD + head + (t - head) / speed
        return START_HOLD + head + middle_play + (t - tail_start)

    ff = (START_HOLD + head, START_HOLD + head + middle_play)
    return [(play(t), b) for t, b in chunks], ff, speed


def render(log_path, timing_path, command, out_path):
    chunks, ff, speed = retime(read_session(log_path, timing_path))

    prompt = b"\x1b[32m$\x1b[0m "
    term = Terminal(COLS)
    term.feed(prompt + command.encode() + b"\r\n")

    # Sample the retimed playback on a fixed grid; identical neighbours merge later.
    frames = []  # [(screen, badge, duration)]
    end = (chunks[-1][0] if chunks else START_HOLD) + FRAME_S
    t, i = 0.0, 0
    while t < end:
        t += FRAME_S
        while i < len(chunks) and chunks[i][0] <= t:
            term.feed(chunks[i][1])
            i += 1
        badge = f">> {speed:.0f}x" if speed > 1.5 and ff[0] < t <= ff[1] else ""
        frames.append((term.screen(ROWS), badge, FRAME_S))
    # The shell prompt returns once Terraform exits.
    term.feed((b"\r\n" if term.col else b"") + prompt)
    frames.append((term.screen(ROWS), "", END_HOLD))

    merged = []
    for screen, badge, dur in frames:
        if merged and merged[-1][0] == screen and merged[-1][1] == badge:
            merged[-1][2] += dur
        else:
            merged.append([screen, badge, dur])

    font = ImageFont.truetype(FONT_PATH, FONT_SIZE)
    bold = ImageFont.truetype(BOLD_PATH, FONT_SIZE)
    cw = round(font.getlength("M"))
    ch = round(FONT_SIZE * 1.4)
    size = (COLS * cw + 2 * PAD, ROWS * ch + 2 * PAD)

    images = []
    for screen, badge, _ in merged:
        img = Image.new("RGB", size, BG)
        draw = ImageDraw.Draw(img)
        for r, line in enumerate(screen):
            y = PAD + r * ch
            # Draw runs of identical style in one call.
            c = 0
            while c < len(line):
                style = line[c][1]
                end_c = c
                while end_c < len(line) and line[end_c][1] == style:
                    end_c += 1
                fg, bg, is_bold = style
                x = PAD + c * cw
                if bg:
                    draw.rectangle([x, y, x + (end_c - c) * cw - 1, y + ch - 1], fill=bg)
                text = "".join(cell[0] for cell in line[c:end_c])
                draw.text((x, y), text, font=bold if is_bold else font, fill=fg or FG)
                c = end_c
        if badge:
            w = round(font.getlength(badge))
            draw.text((size[0] - PAD - w, PAD), badge, font=bold, fill=DIM)
        images.append(img)

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    images[0].save(
        out_path,
        save_all=True,
        append_images=images[1:],
        duration=[round(d * 1000) for _, _, d in merged],
        loop=0,
        lossless=True,
        method=4,
    )
    total = sum(d for _, _, d in merged)
    print(f"render: wrote {os.path.relpath(out_path, REPO)} "
          f"({len(images)} frames, {total:.1f}s, middle at {speed:.0f}x)")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--log", required=True, help="script -O output")
    ap.add_argument("--timing", required=True, help="script -T output")
    ap.add_argument("--command", default="terraform apply", help="shown on the prompt line")
    ap.add_argument("--out", default=OUT_PATH)
    args = ap.parse_args()
    render(args.log, args.timing, args.command, args.out)


if __name__ == "__main__":
    main()
