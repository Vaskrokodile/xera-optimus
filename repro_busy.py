"""Repro the reported symptom: junk spawning in the composer WHILE the AI is busy.

Sends a prompt, then — without typing — injects the escape traffic a terminal
generates during streaming (mouse reports from hover/scroll, focus events,
window reports), and checks the composer stays clean.

Usage: python -u repro_busy.py
"""
import os
import re
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pty_test import PTY, EXE, CWD, COLS, ROWS, Screen, read_all

# kick off streaming: the mock streams this back in 20-char pieces
PROMPT = "please create the hello_xera file"

# chatter a terminal emits while the screen is repainting during streaming
CHATTER = [
    "\x1b[<35;50;12M",   # hover motion
    "\x1b[<35;51;12M",
    "\x1b[<0;20;8M",     # click
    "\x1b[<0;20;8m",     # release
    "\x1b[<64;50;12M",   # wheel up
    "\x1b[<65;50;12M",   # wheel down
    "\x1b[I",            # focus in
    "\x1b[O",            # focus out
    "\x1b[?1;2$y",       # DECRPM report
    "\x1b[>0;276;0c",    # device attributes report
    "\x1b[12;40R",       # cursor position report
]


def composer(scr):
    """The live composer line is the LAST ❯ row (scrollback has user blocks too)."""
    rows = scr.text().split("\n")
    hits = [ln for ln in rows if "❯" in ln]
    if not hits:
        return "<none>"
    return hits[-1].split("❯", 1)[1].replace("│", "").strip()


def junk_in(s):
    """Any literal escape-sequence residue showing as text."""
    return re.findall(r"\[\??<?[0-9;]*[A-Za-z~$]|\x1b", s)


def main():
    os.environ.update({
        "XERA_BASE_URL": os.environ.get("XERA_BASE_URL", "http://127.0.0.1:8787/v1"),
        "XERA_API_KEY": "mock",
        "XERA_MODEL": "mock-1",
    })
    pty = PTY(COLS, ROWS)
    pty.spawn(EXE, cwd=CWD)
    scr = Screen()
    scr.feed(read_all(pty, 3.0))

    pty.write(PROMPT)
    scr.feed(read_all(pty, 0.5))
    pty.write("\r")
    scr.feed(read_all(pty, 1.5))  # streaming starts, approval prompt appears

    for c in CHATTER:
        pty.write(c)
        scr.feed(read_all(pty, 0.18))

    # approve, let it stream to completion while the terminal keeps chattering
    pty.write("y")
    for c in CHATTER:
        pty.write(c)
        scr.feed(read_all(pty, 0.15))

    scr.feed(read_all(pty, 2.0))

    box = composer(scr)
    print(f"composer after busy-phase chatter: {box!r}")
    bad = junk_in(box)
    print(f"escape residue in composer: {bad}")

    screen = scr.text()
    stray = [ln for ln in screen.split("\n") if re.search(r"\[\??<?\d+;\d+", ln)]
    print(f"lines with sequence-like text: {stray[:5]}")

    # empty composer means the placeholder hint is showing again
    empty = "ask xera anything" in box
    ok = not bad and not stray and empty
    print("\nVERDICT:", "CLEAN" if ok else "STILL LEAKING")
    if not ok:
        print("---- screen ----")
        print(screen)

    pty.write("\x03")
    time.sleep(0.4)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
