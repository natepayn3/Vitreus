#!/usr/bin/env python3
"""Offline test of the TV Remote helper's LG webOS backend, against a stand-in LG on 127.0.0.1 (no TV needed).

    python3 dev/tvremote-webos-test.py          prints PASS, or FAIL and what went wrong

The stand-in answers on WSS and WS ports like an LG: registration (a prompt first, then a key), requests and subscriptions, and the
pointer-input socket for buttons. Everything the helper sends is kept in LOG for the checks."""
import base64, hashlib, json, os, queue, socket, ssl, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "bin", "vitreus-tvremote")
WSS, WS = 13001, 13000
KEY = "k-123"
LOG = []
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_read(conn):
    """One text message from a client (masked frames)."""
    def exact(n):
        b = b""
        while len(b) < n:
            c = conn.recv(n - len(b))
            if not c:
                raise ConnectionError
            b += c
        return b
    b0, b1 = exact(2)
    n = b1 & 0x7F
    if n == 126:
        n = int.from_bytes(exact(2), "big")
    elif n == 127:
        n = int.from_bytes(exact(8), "big")
    mask = exact(4) if b1 & 0x80 else b"\0\0\0\0"
    data = bytes(x ^ mask[i % 4] for i, x in enumerate(exact(n)))
    if b0 & 0x0F == 8:
        raise ConnectionError
    return b0 & 0x0F, data


def ws_send(conn, text):
    data = text.encode()
    n = len(data)
    head = bytes([0x81]) + (bytes([n]) if n < 126 else bytes([126]) + n.to_bytes(2, "big"))
    conn.sendall(head + data)


REPLIES = {
    "ssap://system/getSystemInfo": {"modelName": "FAKE65CX"},
    "ssap://audio/getVolume": {"volumeStatus": {"volume": 12, "muteStatus": False, "maxVolume": 100}},
    "ssap://com.webos.applicationManager/getForegroundAppInfo": {"appId": "com.webos.app.hdmi2"},
    "ssap://com.webos.service.networkinput/getPointerInputSocket": {"socketPath": "ws://127.0.0.1:%d/resources/fake/netinput.pointer.sock" % WS},
    "ssap://tv/getExternalInputList": {"devices": [{"id": "HDMI_1", "label": "HDMI 1", "appId": "com.webos.app.hdmi1"},
                                                   {"id": "HDMI_2", "label": "onn", "appId": "com.webos.app.hdmi2"}]},
    "ssap://com.webos.applicationManager/listLaunchPoints": {"launchPoints": [{"id": "youtube.leanback.v4", "title": "YouTube"},
                                                                               {"id": "netflix", "title": "Netflix"}]},
}


def serve_client(conn):
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            c = conn.recv(1024)
            if not c:
                return
            req += c
        lines = req.decode().split("\r\n")
        path = lines[0].split(" ")[1]
        key = [l.split(":", 1)[1].strip() for l in lines if l.lower().startswith("sec-websocket-key:")][0]
        acc = base64.b64encode(hashlib.sha1(key.encode() + GUID).digest()).decode()
        conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
        while True:
            op, data = ws_read(conn)
            if op == 9:
                continue
            if path.startswith("/resources/"):
                LOG.append({"button": data.decode()})
                continue
            m = json.loads(data)
            LOG.append(m)
            if m.get("type") == "register":
                if m["payload"].get("client-key") != KEY:
                    ws_send(conn, json.dumps({"type": "response", "id": m["id"], "payload": {"pairingType": "PROMPT"}}))
                    time.sleep(0.3)
                ws_send(conn, json.dumps({"type": "registered", "id": m["id"], "payload": {"client-key": KEY}}))
            else:
                ws_send(conn, json.dumps({"type": "response", "id": m["id"], "payload": REPLIES.get(m.get("uri"), {"returnValue": True})}))
    except (ConnectionError, OSError, ValueError, IndexError):
        pass
    finally:
        conn.close()


def listen(port, tls_ctx=None):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(8)

    def loop():
        while True:
            c, _ = srv.accept()
            if tls_ctx:
                try:
                    c = tls_ctx.wrap_socket(c, server_side=True)
                except ssl.SSLError:
                    c.close()
                    continue
            threading.Thread(target=serve_client, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()
    return srv


class Helper:
    def __init__(self, data, ports, idle="20"):
        env = dict(os.environ, VITREUS_TVREMOTE_WEBOS_PORTS=ports, VITREUS_TVREMOTE_WEBOS_IDLE=idle)
        self.p = subprocess.Popen([sys.executable, HELPER, data], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        self.q = queue.Queue()
        threading.Thread(target=lambda: [self.q.put(json.loads(l)) for l in self.p.stdout], daemon=True).start()

    def send(self, **c):
        self.p.stdin.write(json.dumps(c) + "\n")
        self.p.stdin.flush()

    def wait(self, pred, what, t=6):
        end = time.time() + t
        seen = []
        while time.time() < end:
            try:
                ev = self.q.get(timeout=0.2)
            except queue.Empty:
                continue
            seen.append(ev)
            if pred(ev):
                return ev
        fail("no %s; saw %s" % (what, seen[-6:]))

    def stop(self):
        self.send(cmd="stop")
        self.p.wait(timeout=5)


def fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


def sent(pred, what, t=3):
    end = time.time() + t
    while time.time() < end:
        if any(pred(m) for m in list(LOG)):
            return
        time.sleep(0.05)
    fail("the TV never got %s; it got %s" % (what, [m.get("uri", m) for m in LOG[-8:]]))


def stage(s):
    return lambda e: e.get("ev") == "state" and e.get("stage") == s


def check_scan_parse():
    """The LG's real mDNS answer (dev/fixtures, captured from an OLED65CX) is read as an LG with its MAC."""
    import importlib.machinery, importlib.util
    ld = importlib.machinery.SourceFileLoader("tvr", HELPER)
    tvr = importlib.util.module_from_spec(importlib.util.spec_from_loader("tvr", ld))
    ld.exec_module(tvr)
    found = {}
    tvr.parse_mdns(open(os.path.join(HERE, "fixtures", "lg-display-mdns.bin"), "rb").read(), "10.0.0.4", found)
    got = list(found.values())
    if not got or got[0]["kind"] != "webos" or len(got[0].get("mac", "")) != 17 or "OLED" not in got[0]["name"]:
        fail("the LG's mDNS answer parsed as %s" % got)


def main():
    check_scan_parse()
    tmp = tempfile.mkdtemp()
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=fake",
                    "-keyout", tmp + "/k.pem", "-out", tmp + "/c.pem"], check=True, capture_output=True)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(tmp + "/c.pem", tmp + "/k.pem")
    listen(WSS, ctx)
    listen(WS)
    data = tmp + "/data"
    os.makedirs(data)
    h = Helper(data, "%d,%d" % (WSS, WS))
    h.wait(lambda e: e.get("ev") == "hello", "hello")
    # 1. no key yet: asks to pair, connects nowhere
    h.send(cmd="connect", host="127.0.0.1", kind="webos")
    h.wait(stage("needs_pairing"), "needs_pairing")
    # 2. pairing: the prompt, the key saved (600), then ready with what the TV said
    h.send(cmd="pair", host="127.0.0.1", kind="webos")
    h.wait(stage("pair_wait_accept"), "pair_wait_accept")
    h.wait(stage("paired"), "paired")
    ev = h.wait(lambda e: stage("ready")(e) and e.get("model") == "FAKE65CX" and e.get("vol") == 12, "ready with model and volume")
    kf = os.path.join(data, "webos-127.0.0.1.key")
    if open(kf).read().strip() != KEY or os.stat(kf).st_mode & 0o077:
        fail("key file wrong or readable by others")
    # 3. keys: buttons through the pointer socket, volume / mute / play through requests
    h.send(cmd="key", key="UP")
    sent(lambda m: m.get("button") == "type:button\nname:UP\n\n", "button UP")
    h.send(cmd="key", key="OK")
    sent(lambda m: m.get("button") == "type:button\nname:ENTER\n\n", "button ENTER for OK")
    h.send(cmd="key", key="VOL_UP")
    sent(lambda m: m.get("uri") == "ssap://audio/volumeUp", "volumeUp")
    h.send(cmd="key", key="MUTE")
    sent(lambda m: m.get("uri") == "ssap://audio/setMute" and m.get("payload") == {"mute": True}, "setMute true")
    h.send(cmd="key", key="PLAY_PAUSE")
    sent(lambda m: m.get("uri") == "ssap://media.controls/play", "play")
    h.send(cmd="key", key="PLAY_PAUSE")
    sent(lambda m: m.get("uri") == "ssap://media.controls/pause", "pause")
    # 4. inputs and apps
    h.send(cmd="inputs")
    ev = h.wait(lambda e: e.get("ev") == "inputs", "inputs")
    if [(i["id"], i["label"], i["on"]) for i in ev["list"]] != [("HDMI_1", "HDMI 1", False), ("HDMI_2", "onn", True)]:
        fail("inputs: %s" % ev["list"])
    h.send(cmd="input", id="HDMI_1")
    sent(lambda m: m.get("uri") == "ssap://tv/switchInput" and m.get("payload") == {"inputId": "HDMI_1"}, "switchInput HDMI_1")
    h.send(cmd="apps")
    ev = h.wait(lambda e: e.get("ev") == "apps", "apps")
    if [a["label"] for a in ev["list"]] != ["Netflix", "YouTube"]:
        fail("apps not sorted by title: %s" % ev["list"])
    h.send(cmd="launch", id="netflix")
    sent(lambda m: m.get("uri") == "ssap://system.launcher/launch" and m.get("payload") == {"id": "netflix"}, "launch netflix")
    # 4b. the app in front, by title, and closing it
    h.send(cmd="running")
    ev = h.wait(lambda e: e.get("ev") == "running", "running")
    if [(a["id"], a["on"]) for a in ev["list"]] != [("com.webos.app.hdmi2", True)] or not ev["list"][0]["label"].startswith("hdmi2"):
        fail("running: %s" % ev["list"])
    h.send(cmd="close", id="com.webos.app.hdmi2")
    sent(lambda m: m.get("uri") == "ssap://system.launcher/close" and m.get("payload") == {"id": "com.webos.app.hdmi2"}, "close hdmi2")
    # 5. typing, power
    h.send(cmd="text", text="hi")
    sent(lambda m: m.get("uri") == "ssap://com.webos.service.ime/insertText" and m.get("payload") == {"text": "hi", "replace": 0}, "insertText")
    sent(lambda m: m.get("uri") == "ssap://com.webos.service.ime/sendEnterKey", "sendEnterKey")
    h.send(cmd="key", key="POWER")
    sent(lambda m: m.get("uri") == "ssap://system/turnOff", "turnOff")
    # 6. a reconnect with the saved key: no prompt this time
    n = len(LOG)
    h.send(cmd="reconnect", host="127.0.0.1", kind="webos")
    h.wait(stage("ready"), "ready after reconnect")
    regs = [m for m in LOG[n:] if m.get("type") == "register"]
    if not regs or regs[-1]["payload"].get("client-key") != KEY:
        fail("reconnect did not register with the saved key")
    h.stop()
    # 7. a quiet TV stays connected: the stand-in, like an LG, never answers a ping, so the helper must check with a request
    h = Helper(data, "%d,%d" % (WSS, WS), idle="0.5")
    h.wait(lambda e: e.get("ev") == "hello", "hello")
    h.send(cmd="connect", host="127.0.0.1", kind="webos")
    h.wait(stage("ready"), "ready")
    end = time.time() + 3
    while time.time() < end:
        try:
            ev = h.q.get(timeout=0.2)
        except queue.Empty:
            continue
        if ev.get("ev") == "state" and ev.get("stage") in ("error", "connecting"):
            fail("a quiet TV was dropped: %s" % ev)
    h.stop()
    # 8. a TV with only the plain port (old firmware): falls back to it
    h = Helper(data, "%d,%d" % (WSS + 10, WS))
    h.wait(lambda e: e.get("ev") == "hello", "hello")
    h.send(cmd="connect", host="127.0.0.1", kind="webos")
    h.wait(stage("ready"), "ready over the plain port")
    h.stop()
    print("PASS")


if __name__ == "__main__":
    main()
