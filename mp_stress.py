# heavier multiplayer PTY stress test — many prompts while streaming,
# threads, monitor, leave/rejoin. mock_llm.py must serve :8787.
import os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from winpty import PTY
from pty_test import Screen, read_all, show, log, EXE, CWD, COLS, ROWS

def send(pty, scr, text, settle=0.35):
    pty.write(text)
    pty.write("\r")
    scr.feed(read_all(pty, settle))

def drain(*pairs):
    for p, s in pairs:
        s.feed(read_all(p, 0.4))

def alive(tag, host, guest):
    h, g = host.isalive(), guest.isalive()
    log(f"[{tag}] host alive={h} guest alive={g}")
    if not h or not g:
        show(host_screen_ref[0], f"HOST LAST ({tag})")
        show(guest_screen_ref[0], f"GUEST LAST ({tag})")
        sys.exit(1)

host_screen_ref = [None]
guest_screen_ref = [None]

def main():
    os.environ.update({
        "XERA_BASE_URL": "http://127.0.0.1:8787/v1",
        "XERA_API_KEY": "mock",
        "XERA_MODEL": "mock-1",
    })
    os.environ["XERA_NAME"] = "host-user"
    host = PTY(COLS, ROWS); host.spawn(EXE, cwd=CWD)
    hs = Screen(); hs.feed(read_all(host, 1.6))
    host_screen_ref[0] = hs

    send(host, hs, "/multiplayer-create", 1.2)
    m = re.search(r"xmp-[\d.]+-\d+-[0-9a-fA-F]+", hs.text())
    assert m, "no session id"
    sid = m.group(0); log(f"[sid] {sid}")

    os.environ["XERA_NAME"] = "guest-user"
    guest = PTY(COLS, ROWS); guest.spawn(EXE, cwd=CWD)
    gs = Screen(); gs.feed(read_all(guest, 1.6))
    guest_screen_ref[0] = gs
    send(guest, gs, "/multiplayer-join " + sid, 2.0)
    drain((host, hs)); alive("join", host, guest)

    # typing indicator: partial text, no enter
    guest.write("typing test draft")
    time.sleep(0.8); hs.feed(read_all(host, 0.5))
    if "typing" not in hs.text().lower() and "guest-user" not in hs.text():
        log("!! no typing indicator on host")
    # clear composer via esc, then rapid-fire prompts while agent may stream
    guest.write("\x1b" * 3)
    for i in range(4):
        send(guest, gs, f"guest rapid {i}", 0.15)
    for i in range(3):
        send(host, hs, f"host rapid {i}", 0.15)
    drain((host, hs), (guest, gs))
    time.sleep(3.0)
    hs.feed(read_all(host, 1.5)); gs.feed(read_all(guest, 1.5))
    alive("rapid prompts", host, guest)
    for i in range(4):
        if f"guest rapid {i}" not in gs.text():
            log(f"!! guest missing own prompt {i}")

    # thread off p-1, guest enters it, prompt into thread
    send(host, hs, "/thread p-1", 1.6)
    drain((guest, gs)); alive("thread create", host, guest)
    send(guest, gs, "/threadmonitor", 0.9)
    if "t-1" not in gs.text(): log("!! monitor missing t-1")
    guest.write("\x1b")
    send(guest, gs, "/thread t-1", 0.8)
    for i in range(3):
        send(guest, gs, f"thread msg {i}", 0.2)
    time.sleep(2.5)
    hs.feed(read_all(host, 1.5)); gs.feed(read_all(guest, 1.5))
    alive("thread prompts", host, guest)
    send(guest, gs, "/main", 0.5)

    # leave + rejoin (snapshot path)
    send(guest, gs, "/leave", 0.8)
    hs.feed(read_all(host, 0.8)); alive("leave", host, guest)
    send(guest, gs, "/multiplayer-join " + sid, 2.0)
    hs.feed(read_all(host, 0.8)); alive("rejoin", host, guest)
    if "guest rapid" not in gs.text(): log("!! rejoin snapshot missing log")
    send(guest, gs, "post-rejoin prompt", 2.0)
    hs.feed(read_all(host, 1.5)); alive("post-rejoin", host, guest)

    show(hs, "HOST END"); show(gs, "GUEST END")
    log(f"alive host: {host.isalive()} guest: {guest.isalive()}")
    log("STRESS PASS")

if __name__ == "__main__":
    main()
