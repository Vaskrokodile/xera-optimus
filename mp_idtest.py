# regression test: joining with a chat-app-mangled session id, and typing
# non-ASCII text into the composer (previously @intCast panic / mojibake).
# mock_llm.py must serve :8787.
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
    host = PTY(COLS, ROWS); host.spawn(EXE, cwd=CWD)
    hs = Screen(); hs.feed(read_all(host, 1.6))
    host.write("/multiplayer-create"); host.write("\r")
    hs.feed(read_all(host, 1.2))
    m = re.search(r"xmp-[\d.]+-\d+-[0-9a-fA-F]+", hs.text())
    assert m, "no session id"
    sid = m.group(0); log(f"[sid] {sid}")

    # mangle like a chat-app copy: en dash separators, NBSP inside, spaces
    body = sid[4:].replace('-', '\u2013')
    body = body.replace('7777', '\u00a07777', 1)
    mangled = '  xmp-' + body
    log(f"[mangled] {mangled.encode('unicode_escape')}")

    os.environ["XERA_NAME"] = "guest-user"
    guest = PTY(COLS, ROWS); guest.spawn(EXE, cwd=CWD)
    gs = Screen(); gs.feed(read_all(guest, 1.6))

    # 1) unicode in the composer must not crash (was: @intCast panic >0xFF)
    guest.write("héllo wörld → test")
    time.sleep(0.7)
    gs.feed(read_all(guest, 0.6))
    if not guest.isalive():
        show(gs, "guest — CRASHED on unicode input"); sys.exit(1)
    guest.write("\x1b" * 3)  # clear composer
    guest.write("\x15")      # ctrl-u-ish fallback
    time.sleep(0.3)

    # 2) join with the mangled id — should still connect
    guest.write("/multiplayer-join " + mangled)
    guest.write("\r")
    gs.feed(read_all(guest, 2.5))
    if not guest.isalive():
        show(gs, "guest — CRASHED on join"); sys.exit(1)
    hs.feed(read_all(host, 0.8))
    show(gs, "guest — after mangled join")
    show(hs, "host — after mangled join")
    flat = hs.text()
    if "guest-user joined the session" not in flat:
        log("!! join did not reach host")
        sys.exit(1)

    # 3) prompt still works after the join path
    guest.write("post-mangle prompt")
    guest.write("\r")
    gs.feed(read_all(guest, 1.5)); hs.feed(read_all(host, 1.5))
    ok = guest.isalive() and host.isalive()
    log(f"host alive={host.isalive()} guest alive={guest.isalive()}")
    log("ID-TEST PASS" if ok else "ID-TEST FAIL")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
