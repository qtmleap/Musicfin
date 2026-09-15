#!/usr/bin/env python3
"""生成済み iPad visual report をローカル配信する。"""

from __future__ import annotations

import argparse
import functools
import http.server
import socketserver
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCROOT = ROOT / "docs" / "screenshots"
REPORT = DOCROOT / "ipad-report"


class Server(http.server.ThreadingHTTPServer):
    def server_bind(self) -> None:
        # 表示用途の逆引きで起動が止まらないよう、待受アドレスをそのまま名前に使う。
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self) -> None:
        # 単独起動でもiPhoneへ同一originで移動できるよう、両レポートの共通rootを配信する。
        if self.path == "/" or self.path.startswith("/?") or self.path == "/index.html":
            query = self.path.partition("?")[2]
            # iPhone切替だけはrootをそのまま返し、通常の入口はiPadへ誘導する。
            if "device=iphone" not in query:
                target = "/ipad-report/" + (f"?{query}" if query else "")
                self.send_response(302)
                self.send_header("Location", target)
                self.end_headers()
                return
        super().do_GET()

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18756)
    args = parser.parse_args()
    if not (REPORT / "index.html").is_file():
        raise SystemExit("先に scripts/compare-ipad-screens.py を実行してください")
    handler = functools.partial(Handler, directory=str(DOCROOT))
    print(f"http://{args.host}:{args.port}/")
    Server((args.host, args.port), handler).serve_forever()


if __name__ == "__main__":
    main()
