# two-process multiplayer PTY test for xera-optimus (Windows, winpty).
#   python mp_test.py        (mock_llm.py must be serving on :8787)
# host: /multiplayer-create → client joins → both send prompts →
# shared blocks on both sides → typing indicator → /thread → /threadmonitor
import os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from winpty import PTY
from pty_test import Screen, read_all, show, log, EXE, CWD, COLS, ROWS

def main():
    os.environ.update({
        "XERA_BASE_URL": "http://127.0.0.1:8787/v1",
        "XERA_API_KEY": "mock",
        "XERA_MODEL": "mock-1",
    })
    os.environ["XERA_NAME"] = "host-user"
    host = PTY(COLS, ROWS)
    host.spawn(EXE, cwd=CWD)
    hscr = Screen()
    hscr.feed(read_all(host, 1.6))
    host.write("/multiplayer-create")
    hscr.feed(read_all(host, 0.6))
    host.write("\r")
    hscr.feed(read_all(host, 1.4))
    show(hscr, "host — session created")
    flat = hscr.text()
    m = re.search(r"xmp-[\d.]+-\d+-[0-9a-fA-F]+", flat)
    if not m:
        print("!! no session id on host screen"); return
    sid = m.group(0)
    log(f"[session id] {sid}")

    os.environ["XERA_NAME"] = "guest-user"
    guest = PTY(COLS, ROWS)
    guest.spawn(EXE, cwd=CWD)
    gscr = Screen()
    gscr.feed(read_all(guest, 1.6))
    guest.write("/multiplayer-join " + sid)
    gscr.feed(read_all(guest, 0.5))
    guest.write("\r")
    gscr.feed(read_all(guest, 2.2))
    show(gscr, "guest — joined (snapshot)")
    hscr.feed(read_all(host, 0.6))
    show(hscr, "host — after join")

    # guest types (draft visible to host) then sends
    guest.write("hello from guest")
    time.sleep(1.0)
    hscr.feed(read_all(host, 0.6))
    show(hscr, "host — sees guest typing")
    guest.write("\r")
    gscr.feed(read_all(guest, 1.2))
    hscr.feed(read_all(host, 2.5))
    show(hscr, "host — guest prompt + agent")
    gscr.feed(read_all(guest, 1.2))
    show(gscr, "guest — own prompt echoed")

    # host sends a prompt
    host.write("hello from host")
    host.write("\r")
    hscr.feed(read_all(host, 1.0))
    gscr.feed(read_all(guest, 2.5))
    show(gscr, "guest — sees host prompt")

    # host opens a thread on p-1
    host.write("/thread p-1")
    host.write("\r")
    hscr.feed(read_all(host, 1.8))
    gscr.feed(read_all(guest, 1.2))
    show(hscr, "host — thread opened")
    show(gscr, "guest — sees thread")

    # guest opens the thread monitor
    guest.write("/threadmonitor")
    guest.write("\r")
    gscr.feed(read_all(guest, 1.0))
    show(gscr, "guest — thread monitor")

    # guest enters the thread and sends into it
    guest.write("\x1b")  # esc closes overlay
    guest.write("/thread t-1")
    guest.write("\r")
    gscr.feed(read_all(guest, 0.8))
    guest.write("thread message from guest")
    guest.write("\r")
    gscr.feed(read_all(guest, 1.5))
    hscr.feed(read_all(host, 2.5))
    show(hscr, "host — thread prompt")

    guest.write("\x03")
    host.write("\x03")
    gscr.feed(read_all(guest, 0.6))
    hscr.feed(read_all(host, 0.6))
    show(hscr, "host — end")
    log(f"alive host: {host.isalive()} guest: {guest.isalive()}")

if __name__ == "__main__":
    main()
