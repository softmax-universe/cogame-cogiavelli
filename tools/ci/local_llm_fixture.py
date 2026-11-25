#!/usr/bin/env python3
"""Deterministic local Anthropic-Messages HTTP fixture for Cogiavelli smoke and certification."""

import json
import os
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def make_handler(log_path: Path | None):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_GET(self):
            if self.path.startswith("/healthz"):
                body = b'{"ok":true}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(404)
            self.end_headers()

        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            body = json.loads(raw)
            user = body["messages"][0]["content"]
            slot = self.headers.get("X-Coworld-Player-Slot", "0")
            match = re.match(r"(SPRING|SUMMER|AUTUMN) (\d+)", user)
            season, year = match.groups() if match else ("SPRING", "1499")
            is_press = " — LETTERS." in user
            if is_press:
                action = {
                    "broadcast": f"FIXTURE_{year}_{season.lower()}_slot{slot}",
                    "letters": [],
                    "pledges": [],
                    "notes": f"fixture-slot-{slot}",
                }
            else:
                legal = user.split("YOUR UNITS AND EVERY LEGAL ORDER:\n")[1].split("\n\n")[0]
                orders = re.findall(r"^  [AF] [A-Z]+ \([^\n]*?\): ([^|\n]+)", legal, re.M)
                action = {
                    "orders": [o.strip() for o in orders],
                    "spend": [],
                    "notes": f"fixture-slot-{slot}",
                }
                if season == "AUTUMN":
                    action["builds"] = []
            text = json.dumps(action)
            if log_path is not None:
                with log_path.open("a", encoding="utf-8") as fh:
                    fh.write(json.dumps({
                        "slot": slot,
                        "year": year,
                        "season": season,
                        "phase": "press" if is_press else "orders",
                        "action": action,
                    }) + "\n")
            response = json.dumps({
                "model": body.get("model", "cogiavelli-local-fixture"),
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": text}],
                "usage": {"input_tokens": 120, "output_tokens": 24},
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid5(uuid.NAMESPACE_URL, raw.decode("utf-8"))))
            self.end_headers()
            self.wfile.write(response)

    return Handler


def main():
    host = os.environ.get("FIXTURE_HOST", "0.0.0.0")
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    port_file = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
    log_path = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None
    server = ThreadingHTTPServer((host, port), make_handler(log_path))
    actual_port = server.server_port
    if port_file is not None:
        port_file.write_text(str(actual_port), encoding="utf-8")
    print(f"cogiavelli local LLM fixture listening on {host}:{actual_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
