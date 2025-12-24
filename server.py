#!/usr/bin/env python3
# Standard-library HTTP server for System Monitor (no Flask)
# - Serves dashboard from ./web
# - Serves latest metrics from ./out/metrics.json
# - Serves history from ./out/metrics.jsonl (supports real JSONL AND multi-line JSON objects)
# Endpoints:
#   GET /                  -> web/index.html
#   GET /api/latest         -> latest snapshot JSON
#   GET /metrics.json       -> same as /api/latest (compat)
#   GET /api/history?n=50   -> {"count":N,"items":[...]} last N records
#   GET /api/history.jsonl?n=50 -> download last N records as JSONL
#   GET /api/health         -> {"ok":true,...}

import http.server
import socketserver
import json
import os
import urllib.parse
import mimetypes
import threading
from typing import List, Dict, Any, Optional

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.environ.get("OUTPUT_PATH", os.path.join(BASE_DIR, "out"))
WEB_DIR = os.path.join(BASE_DIR, "web")

HOST = "0.0.0.0"
PORT = 5000

LATEST_PATH = os.path.join(OUT_DIR, "metrics.json")
HISTORY_PATH = os.path.join(OUT_DIR, "metrics.jsonl")


# -----------------------------
# File helpers (safe-ish reads)
# -----------------------------
def read_file_bytes(path: str) -> Optional[bytes]:
    if not os.path.exists(path):
        return None
    try:
        with open(path, "rb") as f:
            return f.read()
    except Exception:
        return None


def read_latest_json_bytes() -> Optional[bytes]:
    """
    Try reading latest JSON bytes. If file is mid-write, try a couple times.
    """
    for _ in range(3):
        data = read_file_bytes(LATEST_PATH)
        if not data:
            return None
        # quick sanity: must contain '{' and '}'
        if b"{" in data and b"}" in data:
            return data
    return None


# -----------------------------------------
# History parsing (supports "bad" history)
# -----------------------------------------
def parse_history_objects(path: str, max_items: int = 50) -> List[Dict[str, Any]]:
    """
    Reads up to max_items most recent JSON objects from HISTORY_PATH.

    Supports:
    1) Proper JSONL: 1 JSON object per line
    2) Multi-line JSON objects concatenated (your current broken file case)
       We parse by scanning text and extracting complete JSON objects with JSONDecoder.raw_decode.

    Returns list of dicts in chronological order (old -> new) of the last max_items.
    """
    if not os.path.exists(path):
        return []

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except Exception:
        return []

    text = text.strip()
    if not text:
        return []

    items: List[Dict[str, Any]] = []

    # Fast path: JSONL (try line-by-line)
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    jsonl_ok = True
    tmp: List[Dict[str, Any]] = []
    for ln in lines[-min(len(lines), max_items * 5):]:  # look at recent portion
        if not (ln.startswith("{") and ln.endswith("}")):
            jsonl_ok = False
            break
        try:
            obj = json.loads(ln)
            if isinstance(obj, dict):
                tmp.append(obj)
            else:
                jsonl_ok = False
                break
        except Exception:
            jsonl_ok = False
            break

    if jsonl_ok and tmp:
        # But tmp might be only the last chunk; load whole file JSONL safely:
        items = []
        for ln in lines:
            if not (ln.startswith("{") and ln.endswith("}")):
                continue
            try:
                obj = json.loads(ln)
                if isinstance(obj, dict):
                    items.append(obj)
            except Exception:
                pass
        return items[-max_items:]

    # Slow path: parse concatenated JSON objects (handles multi-line)
    dec = json.JSONDecoder()
    idx = 0
    n = len(text)

    # scan for objects
    while idx < n:
        # find next '{'
        j = text.find("{", idx)
        if j == -1:
            break
        try:
            obj, end = dec.raw_decode(text, j)
            idx = end
            if isinstance(obj, dict):
                items.append(obj)
        except Exception:
            # move forward 1 char and try again
            idx = j + 1

    return items[-max_items:]


def to_jsonl_bytes(items: List[Dict[str, Any]]) -> bytes:
    lines = [json.dumps(it, ensure_ascii=False, separators=(",", ":")) for it in items]
    return ("\n".join(lines) + ("\n" if lines else "")).encode("utf-8")


# -----------------------------
# HTTP handler
# -----------------------------
class RequestHandler(http.server.BaseHTTPRequestHandler):
    server_version = "SystemMonitorHTTP/1.1"

    def log_message(self, fmt, *args):
        print("%s - - [%s] %s" % (self.client_address[0], self.log_date_time_string(), fmt % args))

    def _send_response(self, code: int, body: bytes = b"", content_type: str = "application/json",
                       extra_headers: Optional[Dict[str, str]] = None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))

        # prevent caching (important for live dashboards)
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")

        # CORS (local safe)
        self.send_header("Access-Control-Allow-Origin", "*")

        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)

        self.end_headers()
        if body:
            self.wfile.write(body)

    def _serve_file(self, filepath: str) -> bool:
        if not os.path.exists(filepath) or not os.path.isfile(filepath):
            return False
        ctype, _ = mimetypes.guess_type(filepath)
        ctype = ctype or "application/octet-stream"
        data = read_file_bytes(filepath)
        if data is None:
            return False
        self._send_response(200, data, content_type=ctype)
        return True

    def _serve_latest(self):
        data = read_latest_json_bytes()
        if data is None:
            body = json.dumps({
                "error": "out/metrics.json not found (or not ready). Run monitor.sh first.",
                "expected_path": LATEST_PATH
            }).encode("utf-8")
            return self._send_response(404, body, content_type="application/json")
        return self._send_response(200, data, content_type="application/json")

    def _serve_history_json(self, n: int):
        items = parse_history_objects(HISTORY_PATH, max_items=n)
        body = json.dumps({"count": len(items), "items": items}, ensure_ascii=False).encode("utf-8")
        return self._send_response(200, body, content_type="application/json")

    def _serve_history_jsonl(self, n: int):
        items = parse_history_objects(HISTORY_PATH, max_items=n)
        data = to_jsonl_bytes(items)
        headers = {"Content-Disposition": 'attachment; filename="metrics.jsonl"'}
        return self._send_response(200, data, content_type="application/x-ndjson", extra_headers=headers)

    def do_OPTIONS(self):
        self._send_response(204, b"", content_type="text/plain", extra_headers={
            "Access-Control-Allow-Methods": "GET, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        })

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        # API
        if path in ("/api/latest", "/metrics.json"):
            return self._serve_latest()

        if path == "/api/health":
            body = json.dumps({
                "ok": True,
                "latest_exists": os.path.exists(LATEST_PATH),
                "history_exists": os.path.exists(HISTORY_PATH),
                "latest_path": LATEST_PATH,
                "history_path": HISTORY_PATH,
            }).encode("utf-8")
            return self._send_response(200, body, content_type="application/json")

        if path == "/api/history":
            try:
                n = int(qs.get("n", ["50"])[0])
            except Exception:
                n = 50
            n = max(1, min(n, 500))
            return self._serve_history_json(n)

        if path == "/api/history.jsonl":
            try:
                n = int(qs.get("n", ["50"])[0])
            except Exception:
                n = 50
            n = max(1, min(n, 500))
            return self._serve_history_jsonl(n)

        # Dashboard
        if path in ("/", "/index.html"):
            index_path = os.path.join(WEB_DIR, "index.html")
            if self._serve_file(index_path):
                return
            return self._send_response(404, b"index.html not found", content_type="text/plain")

        # Static folders
        if path.startswith("/css/"):
            rel = path[len("/css/"):]
            file_path = os.path.join(WEB_DIR, "css", rel)
            if self._serve_file(file_path):
                return
            return self._send_response(404, b"Not Found", content_type="text/plain")

        if path.startswith("/js/"):
            rel = path[len("/js/"):]
            file_path = os.path.join(WEB_DIR, "js", rel)
            if self._serve_file(file_path):
                return
            return self._send_response(404, b"Not Found", content_type="text/plain")

        if path == "/favicon.ico":
            return self._send_response(204, b"", content_type="text/plain")

        # Fallback: serve any file inside WEB_DIR
        candidate = os.path.join(WEB_DIR, path.lstrip("/"))
        if self._serve_file(candidate):
            return

        # SPA fallback
        index_path = os.path.join(WEB_DIR, "index.html")
        if os.path.exists(index_path) and self._serve_file(index_path):
            return

        self._send_response(404, b"Not Found", content_type="text/plain")


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


def run():
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(WEB_DIR, exist_ok=True)

    with ThreadingTCPServer((HOST, PORT), RequestHandler) as httpd:
        print(f"Serving on http://{HOST}:{PORT}")
        print(f"- Web:    {WEB_DIR}")
        print(f"- Out:    {OUT_DIR}")
        print(f"- Latest: {LATEST_PATH}")
        print(f"- Hist:   {HISTORY_PATH}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("Shutting down")


if __name__ == "__main__":
    run()
# -----------------------------