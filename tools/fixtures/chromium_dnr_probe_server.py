#!/usr/bin/env python3
"""Minimal localhost-only HTTP fixture for Chromium iOS DNR blocking verification."""

from __future__ import annotations

import argparse
from collections import Counter
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import signal
import sys
import threading
from urllib.parse import parse_qs, urlparse

ALLOWED_PATH = "/dnr-probe-allowed.js"
BLOCKED_PATH = "/dnr-probe-blocked.js"
UBOL_EASYLIST_PATH = "/xpopup/xpopup.js"
UBOL_EASYPRIVACY_PATH = "/analytics/rakuten.js"
UBOL_FILTERS_PATH = "/media/player/videojs/videojs.ads.min.js"
COUNTS_PATH = "/__counts"
RESET_PATH = "/__reset"

HTML_PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Chromium iOS DNR Probe</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      margin: 20px;
      line-height: 1.45;
      color: #111827;
      background: #f9fafb;
    }
    main { max-width: 680px; margin: 0 auto; }
    h1 { font-size: 18px; margin: 0 0 8px; }
    p { margin: 0 0 12px; font-size: 14px; color: #374151; }
    .controls { display: flex; gap: 10px; margin: 14px 0; flex-wrap: wrap; }
    button {
      font: 600 14px/1.2 -apple-system, sans-serif;
      padding: 10px 14px;
      border-radius: 8px;
      border: 1px solid #d1d5db;
      background: #ffffff;
      color: #111827;
      cursor: pointer;
    }
    button#run-test {
      background: #111827;
      color: #ffffff;
      border-color: #111827;
    }
    button:disabled { opacity: 0.55; cursor: default; }
    pre {
      background: #ffffff;
      border: 1px solid #e5e7eb;
      border-radius: 8px;
      padding: 12px;
      font-size: 12px;
      overflow-x: auto;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .status {
      font-weight: 600;
      padding: 10px 12px;
      border-radius: 8px;
      border: 1px solid #d1d5db;
      background: #ffffff;
      margin-bottom: 12px;
      font-size: 13px;
    }
    .status[data-state="pass-candidate"] { border-color: #059669; background: #ecfdf5; color: #065f46; }
    .status[data-state="unblocked"] { border-color: #d97706; background: #fffbeb; color: #92400e; }
    .status[data-state="inconclusive"] { border-color: #dc2626; background: #fef2f2; color: #991b1b; }
  </style>
</head>
<body>
  <main>
    <h1>Chromium iOS DNR Probe</h1>
    <p>
      Tests single-shot <code>fetch()</code> (<code>xmlhttprequest</code>) requests to
      <code>/dnr-probe-allowed.js</code> and <code>/dnr-probe-blocked.js</code> on
      <code id="origin-label"></code>.
    </p>
    <div class="controls">
      <button id="run-test" type="button">Run test</button>
      <button id="reset-counts" type="button">Reset counts</button>
    </div>
    <div id="verdict" class="status" data-state="idle">Idle. Tap "Run test" to execute one probe.</div>
    <pre id="report">No run yet.</pre>
  </main>
  <script>
    const originLabel = document.getElementById('origin-label');
    const runButton = document.getElementById('run-test');
    const resetButton = document.getElementById('reset-counts');
    const verdictEl = document.getElementById('verdict');
    const reportEl = document.getElementById('report');
    originLabel.textContent = window.location.origin;

    let runSeq = 0;

    function makeNonce() {
      runSeq += 1;
      const rand = Math.random().toString(36).slice(2, 8);
      return `r${runSeq}-${Date.now()}-${rand}`;
    }

    async function fetchCounts() {
      const resp = await fetch('/__counts', { cache: 'no-store' });
      if (!resp.ok) {
        throw new Error(`/__counts returned HTTP ${resp.status}`);
      }
      return resp.json();
    }

    async function probeFetch(url) {
      try {
        const resp = await fetch(url, { cache: 'no-store' });
        const body = await resp.text();
        return {
          url,
          ok: resp.ok,
          status: resp.status,
          bytes: body.length,
          error: null,
        };
      } catch (err) {
        return {
          url,
          ok: false,
          status: null,
          bytes: 0,
          error: `${err && err.name ? err.name : 'Error'}: ${err && err.message ? err.message : String(err)}`,
        };
      }
    }

    function setVerdict(state, text) {
      verdictEl.dataset.state = state;
      verdictEl.textContent = text;
    }

    async function runProbe() {
      runButton.disabled = true;
      resetButton.disabled = true;
      try {
        const nonce = makeNonce();
        const allowedUrl = `${window.location.origin}/dnr-probe-allowed.js?run=${encodeURIComponent(nonce)}`;
        const blockedUrl = `${window.location.origin}/dnr-probe-blocked.js?run=${encodeURIComponent(nonce)}`;

        const beforeCounts = await fetchCounts();
        const allowedResult = await probeFetch(allowedUrl);
        const blockedResult = await probeFetch(blockedUrl);
        const afterCounts = await fetchCounts();

        const beforePaths = beforeCounts.paths || {};
        const afterPaths = afterCounts.paths || {};
        const allowedDelta = (afterPaths['/dnr-probe-allowed.js'] || 0) - (beforePaths['/dnr-probe-allowed.js'] || 0);
        const blockedDelta = (afterPaths['/dnr-probe-blocked.js'] || 0) - (beforePaths['/dnr-probe-blocked.js'] || 0);

        if (allowedResult.ok && allowedDelta === 1 && !blockedResult.ok && blockedResult.status === null && blockedDelta === 0) {
          setVerdict(
            'pass-candidate',
            'DNR BLOCK OBSERVED: allowed=200 (server +1), blocked rejected client-side (server +0). Confirm ERR_BLOCKED_BY_CLIENT in Chromium stderr/console.'
          );
        } else if (allowedResult.ok && allowedDelta === 1 && blockedResult.ok && blockedDelta === 1) {
          setVerdict(
            'unblocked',
            'UNBLOCKED (extension disabled or DNR inactive): allowed=200 (+1), blocked=200 (+1).'
          );
        } else {
          setVerdict(
            'inconclusive',
            'INCONCLUSIVE: inspect client errors and server request deltas below (do not assume all fetch errors are DNR blocks).'
          );
        }

        reportEl.textContent = JSON.stringify({
          nonce,
          origin: window.location.origin,
          client: {
            allowed: allowedResult,
            blocked: blockedResult,
          },
          serverDelta: {
            '/dnr-probe-allowed.js': allowedDelta,
            '/dnr-probe-blocked.js': blockedDelta,
          },
          serverCountsAfter: afterCounts,
        }, null, 2);
      } catch (err) {
        setVerdict('inconclusive', `Probe error: ${err && err.message ? err.message : String(err)}`);
        reportEl.textContent = String(err);
      } finally {
        runButton.disabled = false;
        resetButton.disabled = false;
      }
    }

    async function resetCounts() {
      runButton.disabled = true;
      resetButton.disabled = true;
      try {
        const resp = await fetch('/__reset', { method: 'POST', cache: 'no-store' });
        const data = await resp.json();
        setVerdict('idle', 'Server request counters reset.');
        reportEl.textContent = JSON.stringify(data, null, 2);
      } catch (err) {
        setVerdict('inconclusive', `Reset error: ${err && err.message ? err.message : String(err)}`);
      } finally {
        runButton.disabled = false;
        resetButton.disabled = false;
      }
    }

    runButton.addEventListener('click', runProbe);
    resetButton.addEventListener('click', resetCounts);
  </script>
</body>
</html>
"""

UBOL_HTML_PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>uBO Lite Default Static DNR Probe</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      margin: 18px;
      line-height: 1.4;
      color: #111827;
      background: #f9fafb;
    }
    main { max-width: 720px; margin: 0 auto; }
    h1 { font-size: 18px; margin: 0 0 8px; }
    p { margin: 0 0 10px; font-size: 13px; color: #374151; }
    .controls { display: flex; gap: 10px; margin: 12px 0; flex-wrap: wrap; }
    button {
      font: 600 14px/1.2 -apple-system, sans-serif;
      padding: 10px 14px;
      border-radius: 8px;
      border: 1px solid #d1d5db;
      background: #ffffff;
      color: #111827;
      cursor: pointer;
    }
    button#run-ubol-test {
      background: #111827;
      color: #ffffff;
      border-color: #111827;
    }
    button:disabled { opacity: 0.55; cursor: default; }
    pre {
      background: #ffffff;
      border: 1px solid #e5e7eb;
      border-radius: 8px;
      padding: 10px;
      font-size: 11px;
      overflow-x: auto;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .status {
      font-weight: 600;
      padding: 10px 12px;
      border-radius: 8px;
      border: 1px solid #d1d5db;
      background: #ffffff;
      margin-bottom: 10px;
      font-size: 13px;
    }
    .status[data-state="pass-candidate"] { border-color: #059669; background: #ecfdf5; color: #065f46; }
    .status[data-state="unblocked"] { border-color: #d97706; background: #fffbeb; color: #92400e; }
    .status[data-state="inconclusive"] { border-color: #dc2626; background: #fef2f2; color: #991b1b; }
  </style>
</head>
<body>
  <main>
    <h1>uBO Lite Default Static DNR Probe</h1>
    <p>
      Tests official uBOL default rulesets (<code>easylist</code>, <code>easyprivacy</code>,
      <code>ublock-filters</code>) plus allowed control via both <code>fetch()</code> and
      <code>&lt;script&gt;</code> on <code id="origin-label"></code>.
    </p>
    <div class="controls">
      <button id="run-ubol-test" type="button">Run uBOL test</button>
      <button id="reset-counts" type="button">Reset counts</button>
    </div>
    <div id="verdict" class="status" data-state="idle">Idle. Tap "Run uBOL test" to execute.</div>
    <pre id="report">No run yet.</pre>
  </main>
  <script>
    const originLabel = document.getElementById('origin-label');
    const runButton = document.getElementById('run-ubol-test');
    const resetButton = document.getElementById('reset-counts');
    const verdictEl = document.getElementById('verdict');
    const reportEl = document.getElementById('report');
    originLabel.textContent = window.location.origin;

    const TARGETS = [
      { key: 'allowed', path: '/dnr-probe-allowed.js', expectBlocked: false, ruleset: 'control' },
      { key: 'easylist', path: '/xpopup/xpopup.js', expectBlocked: true, ruleset: 'easylist#19' },
      { key: 'easyprivacy', path: '/analytics/rakuten.js', expectBlocked: true, ruleset: 'easyprivacy#176' },
      { key: 'ublock_filters', path: '/media/player/videojs/videojs.ads.min.js', expectBlocked: true, ruleset: 'ublock-filters#526' },
    ];

    let runSeq = 0;

    function makeNonce(tag) {
      runSeq += 1;
      const rand = Math.random().toString(36).slice(2, 8);
      return `ubol-${tag}-r${runSeq}-${Date.now()}-${rand}`;
    }

    async function fetchCounts() {
      const resp = await fetch('/__counts', { cache: 'no-store' });
      if (!resp.ok) throw new Error(`/__counts returned HTTP ${resp.status}`);
      return resp.json();
    }

    async function probeFetch(url) {
      try {
        const resp = await fetch(url, { cache: 'no-store' });
        const body = await resp.text();
        return { ok: resp.ok, status: resp.status, bytes: body.length, error: null };
      } catch (err) {
        return {
          ok: false,
          status: null,
          bytes: 0,
          error: `${err && err.name ? err.name : 'Error'}: ${err && err.message ? err.message : String(err)}`,
        };
      }
    }

    function probeScript(url) {
      return new Promise((resolve) => {
        const s = document.createElement('script');
        let done = false;
        const finish = (loaded, errName) => {
          if (done) return;
          done = true;
          s.remove();
          resolve({ loaded, error: errName });
        };
        const timer = setTimeout(() => finish(false, 'timeout'), 4000);
        s.onload = () => { clearTimeout(timer); finish(true, null); };
        s.onerror = () => { clearTimeout(timer); finish(false, 'script_onerror'); };
        s.src = url;
        document.head.appendChild(s);
      });
    }

    function setVerdict(state, text) {
      verdictEl.dataset.state = state;
      verdictEl.textContent = text;
    }

    async function runUbolProbe() {
      runButton.disabled = true;
      resetButton.disabled = true;
      try {
        const beforeCounts = await fetchCounts();
        const beforePaths = beforeCounts.paths || {};
        const fetchResults = {};
        const scriptResults = {};

        for (const t of TARGETS) {
          const fUrl = `${window.location.origin}${t.path}?run=${encodeURIComponent(makeNonce('xhr'))}`;
          fetchResults[t.key] = await probeFetch(fUrl);
          const sUrl = `${window.location.origin}${t.path}?run=${encodeURIComponent(makeNonce('scr'))}`;
          scriptResults[t.key] = await probeScript(sUrl);
        }

        const afterCounts = await fetchCounts();
        const afterPaths = afterCounts.paths || {};
        const deltas = {};
        for (const t of TARGETS) {
          deltas[t.key] = (afterPaths[t.path] || 0) - (beforePaths[t.path] || 0);
        }

        const allowedOk =
          fetchResults.allowed.ok &&
          scriptResults.allowed.loaded &&
          deltas.allowed === 2;

        const allBlockedClientAndServer = TARGETS.filter((t) => t.expectBlocked).every(
          (t) =>
            !fetchResults[t.key].ok &&
            fetchResults[t.key].status === null &&
            !scriptResults[t.key].loaded &&
            deltas[t.key] === 0
        );

        const allUnblocked = TARGETS.filter((t) => t.expectBlocked).every(
          (t) =>
            fetchResults[t.key].ok &&
            scriptResults[t.key].loaded &&
            deltas[t.key] === 2
        );

        if (allowedOk && allBlockedClientAndServer) {
          setVerdict(
            'pass-candidate',
            'UBOL DNR BLOCK OBSERVED: allowed=200 (+2), all 3 uBOL default ruleset targets blocked (+0).'
          );
        } else if (allowedOk && allUnblocked) {
          setVerdict(
            'unblocked',
            'UBOL UNBLOCKED: allowed=200 (+2), all 3 uBOL targets served 200 (+2 each).'
          );
        } else {
          setVerdict(
            'inconclusive',
            'INCONCLUSIVE: inspect per-target fetch/script results and server deltas.'
          );
        }

        reportEl.textContent = JSON.stringify({
          origin: window.location.origin,
          deltas,
          fetchResults,
          scriptResults,
          serverCountsAfter: afterCounts,
        }, null, 2);
      } catch (err) {
        setVerdict('inconclusive', `Probe error: ${err && err.message ? err.message : String(err)}`);
        reportEl.textContent = String(err);
      } finally {
        runButton.disabled = false;
        resetButton.disabled = false;
      }
    }

    async function resetCounts() {
      runButton.disabled = true;
      resetButton.disabled = true;
      try {
        const resp = await fetch('/__reset', { method: 'POST', cache: 'no-store' });
        const data = await resp.json();
        setVerdict('idle', 'Server request counters reset.');
        reportEl.textContent = JSON.stringify(data, null, 2);
      } catch (err) {
        setVerdict('inconclusive', `Reset error: ${err && err.message ? err.message : String(err)}`);
      } finally {
        runButton.disabled = false;
        resetButton.disabled = false;
      }
    }

    runButton.addEventListener('click', runUbolProbe);
    resetButton.addEventListener('click', resetCounts);
  </script>
</body>
</html>
"""


class ProbeState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._paths: Counter[str] = Counter()
        self._nonces: dict[str, list[str]] = {}

    def record(self, path: str, nonce: str | None) -> None:
        with self._lock:
            self._paths[path] += 1
            if nonce:
                seen = self._nonces.setdefault(path, [])
                seen.append(nonce)
                if len(seen) > 32:
                    del seen[:-32]

    def snapshot(self) -> dict[str, object]:
        with self._lock:
            return {
                "allowed_path": ALLOWED_PATH,
                "blocked_path": BLOCKED_PATH,
                "paths": {
                    ALLOWED_PATH: self._paths.get(ALLOWED_PATH, 0),
                    BLOCKED_PATH: self._paths.get(BLOCKED_PATH, 0),
                    **{
                        k: v
                        for k, v in sorted(self._paths.items())
                        if k not in (ALLOWED_PATH, BLOCKED_PATH)
                    },
                },
                "total_probe_requests": sum(self._paths.values()),
                "recent_nonces": {k: list(v) for k, v in sorted(self._nonces.items())},
            }

    def reset(self) -> dict[str, object]:
        with self._lock:
            self._paths.clear()
            self._nonces.clear()
        return self.snapshot()


def make_handler(state: ProbeState) -> type[BaseHTTPRequestHandler]:
    class DnrProbeHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: object) -> None:
            sys.stderr.write(f"[dnr-probe] {self.address_string()} - {format % args}\n")
            sys.stderr.flush()

        def _is_loopback(self) -> bool:
            return self.client_address[0] in ("127.0.0.1", "::1")

        def _send_bytes(
            self,
            status: HTTPStatus,
            content_type: str,
            body: bytes,
        ) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            if body:
                self.wfile.write(body)

        def _send_json(self, status: HTTPStatus, payload: object) -> None:
            body = (json.dumps(payload, indent=2) + "\n").encode("utf-8")
            self._send_bytes(status, "application/json; charset=utf-8", body)

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            path = parsed.path
            query = parse_qs(parsed.query)
            nonce = query.get("run", [None])[0]

            if path in ("/", "/index.html"):
                self._send_bytes(
                    HTTPStatus.OK,
                    "text/html; charset=utf-8",
                    HTML_PAGE.encode("utf-8"),
                )
                return

            if path in ("/ubol", "/ubol.html"):
                self._send_bytes(
                    HTTPStatus.OK,
                    "text/html; charset=utf-8",
                    UBOL_HTML_PAGE.encode("utf-8"),
                )
                return

            if path == COUNTS_PATH:
                if not self._is_loopback():
                    self._send_json(HTTPStatus.FORBIDDEN, {"error": "loopback only"})
                    return
                self._send_json(HTTPStatus.OK, state.snapshot())
                return

            if path == RESET_PATH:
                self._send_json(
                    HTTPStatus.METHOD_NOT_ALLOWED,
                    {"error": "use POST /__reset"},
                )
                return

            if path in (
                ALLOWED_PATH,
                BLOCKED_PATH,
                UBOL_EASYLIST_PATH,
                UBOL_EASYPRIVACY_PATH,
                UBOL_FILTERS_PATH,
            ):
                state.record(path, nonce)
                js = f"/* dnr-probe path={path} run={nonce or ''} */\n".encode("utf-8")
                self._send_bytes(HTTPStatus.OK, "application/javascript; charset=utf-8", js)
                return

            if path == "/favicon.ico":
                self._send_bytes(HTTPStatus.NO_CONTENT, "image/x-icon", b"")
                return

            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found", "path": path})

        def do_POST(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path != RESET_PATH:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found", "path": parsed.path})
                return
            if not self._is_loopback():
                self._send_json(HTTPStatus.FORBIDDEN, {"error": "loopback only"})
                return
            self._send_json(HTTPStatus.OK, {"reset": True, **state.reset()})

    return DnrProbeHandler


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Controlled localhost HTTP fixture for Chromium iOS DNR blocking proof."
    )
    parser.add_argument(
        "--port",
        type=int,
        default=0,
        help="TCP port on 127.0.0.1 (default: 0 for ephemeral port).",
    )
    args = parser.parse_args()

    state = ProbeState()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(state))
    host, port = server.server_address[:2]

    def _stop(_signum: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    print(f"READY http://{host}:{port}/", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
