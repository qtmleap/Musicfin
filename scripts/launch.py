#!/usr/bin/env python3
"""スクリーンショット比較ビューア（docs/screenshots/index.html）をローカルで配信する。"""

from __future__ import annotations

import argparse
import errno
import functools
import http.server
import os
import signal
import socketserver
import subprocess
import sys
import time
import webbrowser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCROOT = ROOT / "docs" / "screenshots"
# .build/ は gitignore 済みなので、pid とログの置き場に間借りする
RUNTIME = ROOT / ".build"
LOG_FILE = RUNTIME / "screenshots-server.log"
DEFAULT_PORT = 18755
# 0.0.0.0 で待つと macOS の受信接続許可ダイアログが出るため、既定はループバックだけ
DEFAULT_HOST = "127.0.0.1"
# 常駐は launchd に任せる。ログイン時の自動起動と、落ちた時の復帰が無料で付く
LABEL = "jp.qleap.musicfin.screenshots"
AGENT_PLIST = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"


def pid_file(port: int) -> Path:
    return RUNTIME / f"screenshots-server-{port}.pid"


class Server(http.server.ThreadingHTTPServer):
    # HTTPServer.server_bind() は socket.getfqdn() で自分のアドレスを逆引きする。
    # DNS の応答が遅い環境ではここで数十秒止まったうえ、getaddrinfo の中なので
    # Ctrl+C も効かない（`python3 -m http.server` が固まって見える原因）。
    # 表示にしか使わない名前なので、逆引きせずアドレスをそのまま使う
    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


class Handler(http.server.SimpleHTTPRequestHandler):
    # ビューアの「更新」は manifest と画像を取り直す。撮り直した直後に
    # 前のスクリーンショットが出ないよう、配信側でもキャッシュを無効にする
    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


# lsof は数秒かかることがある。ポートが塞がっている時の犯人特定にだけ使う
def listeners(port: int) -> list[int]:
    result = subprocess.run(
        ["lsof", "-w", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
        text=True,
        capture_output=True,
    )
    return sorted({int(pid) for pid in result.stdout.split()})


def command_of(pid: int) -> str:
    result = subprocess.run(
        ["ps", "-o", "command=", "-p", str(pid)], text=True, capture_output=True
    )
    return " ".join(result.stdout.split())


def short_command(pid: int) -> str:
    """エラー表示用。長いコマンドラインをそのまま出すと読めない"""
    command = command_of(pid)
    return command if len(command) <= 120 else command[:117] + "..."


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def running_pid(port: int) -> int | None:
    """そのポートで動いているビューアの pid。配信を始めた本人が pid を書く"""
    path = pid_file(port)
    if not path.exists():
        return None
    try:
        pid = int(path.read_text())
    except ValueError:
        return None
    # pid が使い回されていた場合に無関係なプロセスを掴まないよう、中身も見る
    return pid if alive(pid) and "launch.py" in command_of(pid) else None


def launchctl(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["launchctl", *args], text=True, capture_output=True)


def domain() -> str:
    return f"gui/{os.getuid()}"


def installed() -> bool:
    return AGENT_PLIST.is_file()


def plist_xml(program: list[str]) -> str:
    # plistlib は pyexpat を引きずり込む。Homebrew python の pyexpat が壊れている
    # 環境でも動くよう、内容が固定のこの plist は手で組み立てる
    def esc(value: str) -> str:
        return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    args = "\n".join(f"    <string>{esc(a)}</string>" for a in program)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{LABEL}</string>
  <key>ProgramArguments</key>
  <array>
{args}
  </array>
  <key>WorkingDirectory</key>
  <string>{esc(str(DOCROOT))}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>{esc(str(LOG_FILE))}</string>
  <key>StandardErrorPath</key>
  <string>{esc(str(LOG_FILE))}</string>
</dict>
</plist>
"""


def install(host: str, port: int) -> int:
    RUNTIME.mkdir(parents=True, exist_ok=True)
    AGENT_PLIST.parent.mkdir(parents=True, exist_ok=True)
    # sys.executable を焼き込む。python を入れ替えたら --install をやり直すこと
    program = [
        sys.executable, str(Path(__file__).resolve()),
        "--foreground", "--host", host, "--port", str(port),
    ]
    # 手動起動と二重に待ち受けないよう、先に退かす
    stop(port, quiet=True)
    launchctl("bootout", f"{domain()}/{LABEL}")
    AGENT_PLIST.write_text(plist_xml(program))
    result = launchctl("bootstrap", domain(), str(AGENT_PLIST))
    if result.returncode != 0:
        print(f"launchctl bootstrap に失敗した: {result.stderr.strip()}", file=sys.stderr)
        return 1
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and running_pid(port) is None:
        time.sleep(0.1)
    pid = running_pid(port)
    if pid is None:
        print(f"常駐は登録したが起動を確認できない。ログ: {LOG_FILE}", file=sys.stderr)
        return 1
    print(f"常駐にした pid {pid}: http://{host}:{port}/")
    print("ログイン時に自動起動し、落ちても launchd が起こし直す")
    print(f"解除: ./{Path(__file__).relative_to(ROOT)} --uninstall")
    return 0


def uninstall(port: int) -> int:
    if not installed():
        print("常駐していない")
        return stop(port)
    launchctl("bootout", f"{domain()}/{LABEL}")
    AGENT_PLIST.unlink(missing_ok=True)
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and running_pid(port) is not None:
        time.sleep(0.1)
    print("常駐を解除した")
    return stop(port) if running_pid(port) else 0


def stop(port: int, quiet: bool = False) -> int:
    pid = running_pid(port)
    pid_file(port).unlink(missing_ok=True)
    if pid is None:
        if not quiet:
            print(f"起動していない（port {port}）")
        return 0
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return 0
    print(f"停止した pid {pid}")
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and alive(pid):
        time.sleep(0.1)
    # SIGTERM を握り潰した残骸は待たずに落とす
    if alive(pid):
        os.kill(pid, signal.SIGKILL)
        print(f"強制停止した pid {pid}")
    return 0


def status(host: str, port: int) -> int:
    if installed():
        print(f"常駐あり（launchd: {LABEL}）")
    pid = running_pid(port)
    if pid:
        print(f"起動中 pid {pid}: http://{host}:{port}/")
        return 0
    for other in listeners(port):
        print(f"別プロセスが port {port} を使用中 pid {other}: {short_command(other)}")
        return 1
    print(f"起動していない（port {port}）")
    return 1


def _raise_interrupt(signum: int, frame: object) -> None:
    raise KeyboardInterrupt


def serve(host: str, port: int, open_browser: bool = False) -> int:
    # cwd を合わせておくと、ps や lsof だけで「これは何を配信中か」が分かる
    os.chdir(DOCROOT)
    handler = functools.partial(Handler, directory=str(DOCROOT))
    try:
        server = Server((host, port), handler)
    except OSError as error:
        if error.errno == errno.EADDRINUSE:
            print(f"port {port} は使用中", file=sys.stderr)
            return 1
        raise
    # --stop（SIGTERM）でも後始末したいので、Ctrl+C と同じ経路に落とす
    signal.signal(signal.SIGTERM, _raise_interrupt)
    # 待ち受けに成功してから pid を書く。親はこれを見て起動完了を判断する
    RUNTIME.mkdir(parents=True, exist_ok=True)
    pid_file(port).write_text(str(os.getpid()))
    print(f"http://{host}:{port}/ で配信中（Ctrl+C で停止）", flush=True)
    if open_browser:
        webbrowser.open(f"http://{host}:{port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("停止する", flush=True)
    finally:
        server.server_close()
        path = pid_file(port)
        if path.exists() and path.read_text() == str(os.getpid()):
            path.unlink()
    return 0


def start(host: str, port: int, open_browser: bool) -> int:
    RUNTIME.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a") as log:
        # start_new_session で端末から切り離す。前面に居座らないので、
        # 起動した端末をそのまま使い続けられる
        child = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()),
             "--foreground", "--host", host, "--port", str(port)],
            cwd=str(DOCROOT),
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if running_pid(port) == child.pid:
            url = f"http://{host}:{port}/"
            print(f"起動した: {url}")
            print(f"停止: ./{Path(__file__).relative_to(ROOT)} --stop"
                  + ("" if port == DEFAULT_PORT else f" --port {port}"))
            if open_browser:
                webbrowser.open(url)
            return 0
        if child.poll() is not None:
            break
        time.sleep(0.1)
    if child.poll() is None:
        child.terminate()
    occupant = [pid for pid in listeners(port) if pid != child.pid]
    if occupant:
        print(f"port {port} を別プロセスが使っている: {short_command(occupant[0])}", file=sys.stderr)
        print("--port で別のポートを使うこと", file=sys.stderr)
    else:
        print(f"起動に失敗した。ログ: {LOG_FILE}", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--detach", "-d", action="store_true",
                        help="背面で動かして端末を返す（既定は前面）")
    # 背面起動した子プロセスと launchd の plist が使う。既定と同じ動作
    parser.add_argument("--foreground", "-f", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--stop", action="store_true", help="停止する")
    parser.add_argument("--restart", action="store_true", help="止めてから起動する")
    parser.add_argument("--status", action="store_true", help="状態を出す")
    parser.add_argument("--install", action="store_true",
                        help="常駐させる（ログイン時に自動起動、落ちても復帰）")
    parser.add_argument("--uninstall", action="store_true", help="常駐を解除して停止する")
    parser.add_argument("--no-open", action="store_true", help="ブラウザを開かない")
    args = parser.parse_args()

    if not (DOCROOT / "index.html").is_file():
        print(f"{DOCROOT}/index.html が無い", file=sys.stderr)
        return 1
    if args.install:
        return install(args.host, args.port)
    if args.uninstall:
        return uninstall(args.port)
    if args.status:
        return status(args.host, args.port)
    if args.stop:
        if installed():
            # plist は残す。次のログインではまた起動する
            launchctl("bootout", f"{domain()}/{LABEL}")
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and running_pid(args.port):
                time.sleep(0.1)
            print("停止した（次のログインでまた起動する。完全に外すなら --uninstall）")
            return stop(args.port) if running_pid(args.port) else 0
        return stop(args.port)
    if args.restart:
        if installed():
            if launchctl("kickstart", "-k", f"{domain()}/{LABEL}").returncode != 0:
                launchctl("bootstrap", domain(), str(AGENT_PLIST))
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and running_pid(args.port) is None:
                time.sleep(0.1)
            pid = running_pid(args.port)
            print(f"起こし直した pid {pid}: http://{args.host}:{args.port}/" if pid
                  else f"起動を確認できない。ログ: {LOG_FILE}")
            return 0 if pid else 1
        stop(args.port)
    # 背面起動した子プロセスが通る経路。ここに重い処理を挟むと親の起動待ちを
    # 取りこぼすので、そのまま配信に入る
    if args.foreground:
        return serve(args.host, args.port)

    url = f"http://{args.host}:{args.port}/"
    if running_pid(args.port):
        note = "常駐中" if installed() else "別のところで起動している"
        print(f"{note}: {url}（入れ替えるなら --restart、止めるなら --stop）")
        if not args.no_open:
            webbrowser.open(url)
        return 0
    if installed():
        # --stop で降ろしたあと。launchd に戻す
        launchctl("bootstrap", domain(), str(AGENT_PLIST))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and running_pid(args.port) is None:
            time.sleep(0.1)
        if running_pid(args.port):
            print(f"常駐を再開した: {url}")
            if not args.no_open:
                webbrowser.open(url)
            return 0
        print(f"起動に失敗した。ログ: {LOG_FILE}", file=sys.stderr)
        return 1
    if args.detach:
        return start(args.host, args.port, not args.no_open)
    return serve(args.host, args.port, not args.no_open)


if __name__ == "__main__":
    raise SystemExit(main())
