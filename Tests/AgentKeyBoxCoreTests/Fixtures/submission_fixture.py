"""Synthetic HTTPS endpoint; records validation flags and ordinals, never submitted values."""
import base64
import http.server
import json
from pathlib import Path
import socket
import ssl
import sys
import threading
import time
import urllib.parse

ROOT = Path(sys.argv[3])
CODES = [f"fixture-submit-code-{i:03}" for i in range(1, 9)]
CARD = {"pan": "4242424242424242", "holder": "AKB synthetic card fixture", "month": "12", "year": "2099"}
NOTE = "QA order + & 中文"
LOCK = threading.Lock()
LEDGER = []
USED = set()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        (ROOT / "submission-unexpected-request").write_text("unexpected request")
        self.send_response(400)
        self.end_headers()

    def do_POST(self):
        if self.path not in ("/submit/card", "/submit/recovery"):
            self.do_GET()
            return
        config = json.loads((ROOT / "submission-case.json").read_text())
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 65536:
            self.do_GET()
            return
        raw = self.rfile.read(length).decode()
        encoding = "json" if self.headers.get("Content-Type") == "application/json" else "form"
        try:
            if encoding == "json":
                fields = json.loads(raw)
            else:
                pairs = urllib.parse.parse_qs(raw, keep_blank_values=True, strict_parsing=True)
                fields = {key: value[0] if len(value) == 1 else None for key, value in pairs.items()}
        except (ValueError, TypeError):
            fields = None
        kind = self.path.rsplit("/", 1)[1]
        index, durable = None, None
        if kind == "card":
            expected = dict(CARD) if config["selection"] == "all" else {"pan": CARD["pan"], "month": CARD["month"]}
            expected["note"] = NOTE
        else:
            submitted = fields.get("code") if isinstance(fields, dict) else None
            index = CODES.index(submitted) if submitted in CODES else None
            expected = {"code": submitted, "note": NOTE}
            statuses = json.loads((ROOT / "submission-statuses.json").read_text())
            durable = index is not None and statuses == ["issued"] * (index + 1) + ["available"] * (7 - index)
        content_type = "application/json" if encoding == "json" else "application/x-www-form-urlencoded"
        exact = fields == expected and (kind == "card" or index is not None)
        with LOCK:
            duplicate = index in USED if index is not None else False
            entry = {"caseID": config["caseID"], "kind": kind, "encoding": encoding,
                     "exactFields": exact, "expectedContentType": self.headers.get("Content-Type") == content_type,
                     "noCredentialsOrCookies": not self.headers.get("Authorization") and not self.headers.get("Cookie"),
                     "codeIndex": index, "persistedBeforePost": durable, "duplicate": duplicate}
            LEDGER.append(entry)
            path = ROOT / "submission-ledger.json"
            path.with_suffix(".tmp").write_text(json.dumps(LEDGER))
            path.with_suffix(".tmp").replace(path)
            if index is not None:
                USED.add(index)
        valid = (exact and entry["expectedContentType"] and entry["noCredentialsOrCookies"] and not duplicate
                 and encoding == config["encoding"] and kind == config["kind"]
                 and (kind == "card" or durable))
        mode = config["mode"]
        if valid and mode == "hold":
            deadline = time.monotonic() + 40
            while not (ROOT / "submission-release").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
        if valid and mode == "unknown":
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        reflected = CARD["pan"] + " " + CARD["holder"] + " " + (CODES[index] if index is not None else "")
        body = (reflected + " " + base64.b64encode(reflected.encode()).decode()).encode()
        self.send_response(400 if not valid else 422 if mode == "rejected" else 302 if mode == "redirect" else 200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Reflected", CARD["pan"])
        self.send_header("Set-Cookie", "private=fixture-submit-cookie; Secure; HttpOnly")
        self.send_header("Location", f"https://127.0.0.1:{self.server.server_port}/capture/" + CARD["pan"])
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
print(server.server_port, flush=True)
server.serve_forever()
