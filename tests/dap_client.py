"""Minimaler DAP-Client für die ljdap-Szenariotests.

Nur Standardbibliothek. Synchron: Nachrichten werden beim Warten gelesen und
gepuffert, sodass Events und Responses in beliebiger Reihenfolge ankommen
dürfen.

    c = DapClient.connect("127.0.0.1", 4711, timeout=10)
    seq = c.send("initialize", {"adapterID": "ljdap"})
    resp = c.response(seq)
    ev = c.event("initialized")

null_fields=True bildet den Sublime-Debugger nach: optionale Felder werden
als JSON-null mitgeschickt statt weggelassen.
"""

import json
import socket
import time


class DapError(Exception):
    pass


class DapClient:
    def __init__(self, sock, null_fields=False, log=None):
        self.sock = sock
        self.buf = b""
        self.seq = 0
        self.inbox = []
        self.null_fields = null_fields
        self.log = log

    @classmethod
    def connect(cls, host, port, timeout=10.0, **kw):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            try:
                s = socket.create_connection((host, port), timeout=1.0)
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                return cls(s, **kw)
            except OSError as e:
                last = e
                time.sleep(0.1)
        raise DapError(f"keine Verbindung zu {host}:{port}: {last}")

    # -- Senden -------------------------------------------------------
    def send_raw(self, data: bytes):
        self.sock.sendall(data)

    def send_obj(self, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        if self.log:
            self.log(f"-> {body.decode('utf-8')}")
        self.send_raw(b"Content-Length: %d\r\n\r\n" % len(body) + body)

    def send(self, command, arguments=None, nulls=None):
        """Sendet einen Request und liefert seine seq.

        nulls: Liste von Feldnamen, die (bei null_fields) als null in
        arguments ergänzt werden.
        """
        self.seq += 1
        msg = {"seq": self.seq, "type": "request", "command": command}
        args = dict(arguments or {})
        if self.null_fields:
            for k in nulls or []:
                args.setdefault(k, None)
        if arguments is not None or args:
            msg["arguments"] = args
        self.send_obj(msg)
        return self.seq

    # -- Empfangen ----------------------------------------------------
    def _read_one(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            hend = self.buf.find(b"\r\n\r\n")
            if hend >= 0:
                head = self.buf[:hend].decode("ascii")
                length = None
                for line in head.split("\r\n"):
                    k, _, v = line.partition(":")
                    if k.strip().lower() == "content-length":
                        length = int(v.strip())
                if length is None:
                    raise DapError(f"Kopf ohne Content-Length: {head!r}")
                if len(self.buf) >= hend + 4 + length:
                    body = self.buf[hend + 4:hend + 4 + length]
                    self.buf = self.buf[hend + 4 + length:]
                    text = body.decode("utf-8")
                    if self.log:
                        self.log(f"<- {text}")
                    return json.loads(text)
            rest = deadline - time.monotonic()
            if rest <= 0:
                return None
            self.sock.settimeout(rest)
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                return None
            if not data:
                raise DapError("Verbindung vom Server geschlossen")
            self.buf += data

    def wait_for(self, pred, timeout=10.0, what="Nachricht"):
        for i, m in enumerate(self.inbox):
            if pred(m):
                return self.inbox.pop(i)
        deadline = time.monotonic() + timeout
        while True:
            rest = deadline - time.monotonic()
            if rest <= 0:
                raise DapError(f"Zeitüberschreitung beim Warten auf {what}; gepuffert: {self.inbox}")
            m = self._read_one(rest)
            if m is None:
                continue
            if pred(m):
                return m
            self.inbox.append(m)

    def response(self, seq, timeout=10.0, ok=True):
        r = self.wait_for(lambda m: m.get("type") == "response" and m.get("request_seq") == seq,
                          timeout, f"Response auf {seq}")
        if ok and not r.get("success"):
            raise DapError(f"Request {seq} fehlgeschlagen: {r}")
        return r

    def request(self, command, arguments=None, timeout=10.0, ok=True, nulls=None):
        return self.response(self.send(command, arguments, nulls), timeout, ok)

    def event(self, name, timeout=10.0):
        return self.wait_for(lambda m: m.get("type") == "event" and m.get("event") == name,
                             timeout, f"Event {name}")

    def closed_by_server(self, timeout=5.0):
        """True, wenn der Server die Verbindung innerhalb timeout schließt."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                self.sock.settimeout(max(0.01, deadline - time.monotonic()))
                data = self.sock.recv(65536)
            except socket.timeout:
                return False
            except OSError:
                return True
            if not data:
                return True
            self.buf += data
        return False

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p
