"""Synthetic HTTPS-only loopback website; never uses real accounts or secrets."""
import base64
import html
import http.server
import json
from pathlib import Path
import time
import ssl
import sys
import threading
import urllib.parse

RECOVERY_CODE = "fixture-recovery-001"
RECOVERY_CODES = [f"fixture-recovery-{i:03}" for i in range(1, 5)]
USERNAME = "fixture-user"
PASSWORD = "synthetic-password-42!"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_html(self, body, status=200):
        data = ("<!doctype html><html><title>Fixture</title><body>" + body + "</body></html>").encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def form(self, action="/session", method="post", extra=""):
        return (f'<form method="{method}" action="{action}">'
                '<input name="csrf" type="hidden" value="fixture-csrf">'
                '<input name="user" autocomplete="username">'
                '<input type="password" name="password" autocomplete="current-password">'
                + extra + '<button>Sign in</button></form>')

    def do_GET(self):
        if self.path.startswith("/login"):
            action = {"/login-cross": "https://elsewhere.invalid/session",
                      "/login-fail": "/fail", "/login-redirect": "/redirect",
                      "/login-reflect": "/reflect", "/login-slow": "/slow",
                      "/login-slow-follow": "/session-slow-follow"}.get(self.path, "/session")
            if self.path.startswith("/login-recovery"):
                action = self.path.replace("/login-recovery", "/session-recovery", 1)
            extra = '<input autocomplete="one-time-code" name="otp">' if self.path == "/login-otp" else ""
            self.send_html(self.form(action, "get" if self.path == "/login-get" else "post", extra))
        elif "session=fixture-session-cookie" not in self.headers.get("Cookie", ""):
            self.send_html(self.form())
        elif self.path.startswith("/challenge"):
            suffix = self.path.removeprefix("/challenge")
            action = "https://elsewhere.invalid/recover" if suffix == "-cross" else "/recover" + suffix
            extra = '<input name="otp">' if suffix == "-extra" else ""
            self.send_html('<p>CHALLENGE_PRIVATE_TEXT ' + html.escape(USERNAME + " " + PASSWORD)
                + '</p><form method="post" action="' + action + '">'
                '<input type="hidden" name="csrf" value="private-recovery-csrf">'
                '<input name="recovery_code" autocomplete="one-time-code">'
                + extra + '<button>Verify</button></form>')
        elif self.path == "/recovered":
            if "verified=verified-cookie" not in self.headers.get("Cookie", ""):
                self.send_html("Missing verification cookie", 403)
            else:
                reflected = getattr(self.server, "last_recovery_code", RECOVERY_CODE)
                self.send_html('<p>Recovery verified. Task result: 7 open issues.</p><p>'
                    + html.escape(reflected + " " + base64.b64encode(reflected.encode()).decode()
                    + " verified-cookie " + USERNAME + " " + PASSWORD) + '</p><a href="/details">Details</a>')
        elif self.path == "/reflect":
            self.send_html("<p>" + html.escape(USERNAME + " " + PASSWORD + " "
                + base64.b64encode(PASSWORD.encode()).decode()
                + " fixture-session-cookie") + "</p>")
        else:
            if self.path == "/slow-details":
                with open(sys.argv[3] + ".follow", "w") as output:
                    output.write("GET received")
                time.sleep(2)
            details = "/slow-details" if self.path == "/account-slow-follow" else "/details"
            self.send_html('<p>Signed in. Task result: 7 open issues.</p>'
                f'<a href="{details}">Read details</a><a href="https://elsewhere.invalid/">Outside</a>'
                '<a href="javascript:alert(1)">Script</a>'
                '<input type="hidden" value="hidden-private-value">'
                '<textarea>textarea-private-value</textarea>'
                '<script>document.body.textContent="PAGE_SCRIPT_EXECUTED";</script>')

    def do_POST(self):
        if self.path.startswith("/recover"):
            self.server.recovery_posts = getattr(self.server, "recovery_posts", 0) + 1
            with open(sys.argv[3] + ".recovery", "w") as output:
                output.write(str(self.server.recovery_posts))
            fields = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
            submitted = fields.get("recovery_code", [None])[0]
            valid = submitted in RECOVERY_CODES and fields == {
                "recovery_code": [submitted], "csrf": ["private-recovery-csrf"]}
            if len(sys.argv) == 5:
                # Native evidence contains ordinal/status/count only, never the submitted value.
                try:
                    statuses = json.loads(Path(sys.argv[4]).read_text())
                except (OSError, ValueError):
                    statuses = None
                index = RECOVERY_CODES.index(submitted) if valid else None
                durable = (index is not None and statuses ==
                           ["issued"] * (index + 1) + ["available"] * (len(RECOVERY_CODES) - index - 1))
                entry = {"codeIndex": index, "persistedBeforePost": durable,
                         "duplicate": index in self.server.used_recovery_indices}
                self.server.recovery_ledger.append(entry)
                ledger = Path(sys.argv[3] + ".ledger")
                ledger.with_suffix(".ledger.tmp").write_text(json.dumps(self.server.recovery_ledger))
                ledger.with_suffix(".ledger.tmp").replace(ledger)
                Path(sys.argv[3] + ".reservation").write_text(json.dumps({"persistedBeforePost": durable}))
                valid = valid and durable and not entry["duplicate"]
                if valid:
                    self.server.used_recovery_indices.add(index)
                mode = Path(sys.argv[3] + ".mode")
                if valid and mode.exists() and mode.read_text().strip() == "hold":
                    deadline = time.monotonic() + 40
                    while not Path(sys.argv[3] + ".release").exists() and time.monotonic() < deadline:
                        time.sleep(0.05)
            if not valid:
                self.send_html("Unexpected fields or duplicate code", 400)
                return
            self.server.last_recovery_code = submitted
            if self.path == "/recover-slow":
                time.sleep(2)
            self.send_response(307 if self.path == "/recover-redirect" else 303)
            self.send_header("Location", f"https://127.0.0.1:{sink.server_port}/capture"
                             if self.path == "/recover-redirect" else "/challenge-fail"
                             if self.path == "/recover-fail" else "/recovered")
            self.send_header("Set-Cookie", "verified=verified-cookie; Secure; HttpOnly; Path=/; SameSite=Strict")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with open(sys.argv[3] + ".post", "w") as output:
            output.write("POST received")
        fields = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        if fields != {"user": [USERNAME], "password": [PASSWORD], "csrf": ["fixture-csrf"]}:
            self.send_html(self.form(), 400)
            return
        if self.path == "/fail":
            self.send_html(self.form())
            return
        if self.path == "/slow":
            time.sleep(2)
        self.send_response(307 if self.path == "/redirect" else 303)
        self.send_header("Location", f"https://127.0.0.1:{sink.server_port}/capture" if self.path == "/redirect"
                         else self.path.replace("/session-recovery", "/challenge", 1)
                         if self.path.startswith("/session-recovery")
                         else "/reflect" if self.path == "/reflect"
                         else "/account-slow-follow" if self.path == "/session-slow-follow"
                         else "/account")
        self.send_header("Set-Cookie", "session=fixture-session-cookie; Secure; HttpOnly; Path=/; SameSite=Strict")
        self.send_header("Content-Length", "0")
        self.end_headers()


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])


class Sink(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        # Record only whether a request arrived, not its body or any submitted values.
        with open(sys.argv[3], "w") as output:
            output.write("unexpected cross-origin request")
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_POST = do_GET


sink = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sink)
sink.socket = context.wrap_socket(sink.socket, server_side=True)
threading.Thread(target=sink.serve_forever, daemon=True).start()
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.recovery_ledger = []
server.used_recovery_indices = set()
print(server.server_port, flush=True)
server.serve_forever()
