import http.server
import json
import os
import random
import threading
import time
from datetime import datetime, timezone

MODE = os.environ.get("MODE", "stable")
APP_VERSION = os.environ.get("APP_VERSION", "1.0.0")
APP_PORT = int(os.environ.get("APP_PORT", "3000"))

START_TIME = time.time()

chaos_state = {"mode": "normal", "duration": 0, "rate": 0.0, "lock": threading.Lock()}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _set_headers(self, status=200, extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if MODE == "canary":
            self.send_header("X-Mode", "canary")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()

    def _apply_chaos(self):
        with chaos_state["lock"]:
            m = chaos_state["mode"]
            dur = chaos_state["duration"]
            rate = chaos_state["rate"]
        if m == "slow":
            time.sleep(dur)
            return None
        if m == "error":
            if random.random() < rate:
                return 500
        return None

    def _send_json(self, status, body, extra_headers=None):
        self._set_headers(status, extra_headers)
        self.wfile.write(json.dumps(body).encode())

    def do_HEAD(self):
        self._apply_chaos()
        if self.path in ("/", "/healthz"):
            self._set_headers(200)
        else:
            self._set_headers(404)

    def do_GET(self):
        chaos_result = self._apply_chaos()
        if chaos_result == 500:
            self._send_json(500, {"error": "chaos-induced failure"})
            return

        if self.path == "/":
            self._send_json(200, {
                "message": f"Welcome to SwiftDeploy API ({MODE} mode)",
                "mode": MODE,
                "version": APP_VERSION,
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
        elif self.path == "/healthz":
            self._send_json(200, {
                "status": "healthy",
                "mode": MODE,
                "uptime_seconds": round(time.time() - START_TIME, 2)
            })
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/chaos":
            if MODE != "canary":
                self._send_json(403, {"error": "chaos endpoint only available in canary mode"})
                return

            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            cmd = body.get("mode", "")

            with chaos_state["lock"]:
                if cmd == "slow":
                    chaos_state["mode"] = "slow"
                    chaos_state["duration"] = body.get("duration", 5)
                    self._send_json(200, {"status": "chaos active", "mode": "slow", "duration": chaos_state["duration"]})
                elif cmd == "error":
                    chaos_state["mode"] = "error"
                    chaos_state["rate"] = body.get("rate", 0.5)
                    self._send_json(200, {"status": "chaos active", "mode": "error", "rate": chaos_state["rate"]})
                elif cmd == "recover":
                    chaos_state["mode"] = "normal"
                    chaos_state["duration"] = 0
                    chaos_state["rate"] = 0.0
                    self._send_json(200, {"status": "recovered"})
                else:
                    self._send_json(400, {"error": "invalid chaos mode"})
        else:
            self._send_json(404, {"error": "not found"})


if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", APP_PORT), Handler)
    print(f"SwiftDeploy API running on port {APP_PORT} in {MODE} mode (v{APP_VERSION})")
    server.serve_forever()
