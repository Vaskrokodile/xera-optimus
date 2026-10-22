"""Repro: do VT escape bytes leak into the composer as literal text?

Feeds sequences a terminal emits when mouse tracking is on (-?1003h / ?1006h)
and renders the screen with the VT emulator from pty_test.py.

Usage: python -u repro_mouse.py [sequence-name]
"""
import os
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pty_test import PTY, EXE, CWD, COLS, ROWS, Screen, read_all

# Everything a terminal may emit while the app is idle-but-tracked.
SAMPLES = {
    "motion": "\x1b[<35;40;10M",
    "press": "\x1b[<0;40;10M",
    "release": "\x1b[<0;40;10m",
    "wheel_up": "\x1b[<64;40;10M",
    "focus_in": "\x1b[I",
    "focus_out": "\x1b[O",
}


def composer_lines(scr):
    """Return screen rows, with a marker for the composer box."""
    return [ln for ln in scr.text().split("\n")]


def run(seq, label):
    os.environ.update({
        "XERA_BASE_URL": os.environ.get("XERA_BASE_URL", "http://127.0.0.1:8787/v1"),
        "XERA_API_KEY": "mock",
        "XERA_MODEL": "mock-1",
    })
    pty = PTY(COLS, ROWS)
    pty.spawn(EXE, cwd=CWD)
    scr = Screen()
    scr.feed(read_all(pty, 2.2))  # banner reveal

    before = scr.text()

    # send the sequence exactly as a terminal would
    pty.write(seq)
    scr.feed(read_all(pty, 0.8))
    after = scr.text()

    # compare: what changed on screen from a non-typing escape sequence?
    bl, al = before.split("\n"), after.split("\n")
    diffs = [(i, b, a) for i, (b, a) in enumerate(zip(bl, al)) if b != a]

    print(f"\n===== {label}: sent {seq!r} =====")
    if not diffs:
        print("  screen unchanged")
    for i, b, a in diffs:
        print(f"  row {i}:")
        print(f"    before: {b!r}")
        print(f"    after : {a!r}")

    pty.write("\x03")
    time.sleep(0.4)
    return diffs


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    total = 0
    for name, seq in SAMPLES.items():
        if only and name != only:
            continue
        total += len(run(seq, name))
    print(f"\nTOTAL differing rows across sequences: {total}")


if __name__ == "__main__":
    main()
