#!/usr/bin/env python3
# Dev server for the wasm build with caching disabled, so a plain browser reload
# always fetches the freshly staged style.css / ruby / js (no hard-reload dance).
# Python's stock http.server sends Last-Modified but no Cache-Control, so browsers
# serve stale dev assets on a normal reload; this adds no-store.
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
directory = sys.argv[2] if len(sys.argv) > 2 else "."


class NoCacheHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        super().end_headers()


with ThreadingHTTPServer(("127.0.0.1", port), NoCacheHandler) as httpd:
    httpd.serve_forever()
