#!/usr/bin/env python3
"""音源を変更せず、トラック番号の欠落とファイル名の規則を標準出力へ報告する。"""

import argparse
import json
from collections import Counter, defaultdict
from dataclasses import dataclass
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import unicodedata

# 初回起動時も依存モジュールのキャッシュを新しく書き出さない。
sys.dont_write_bytecode = True
import mutagen
from mutagen.id3 import ID3
from mutagen.mp4 import MP4


EXTENSIONS = {".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".aiff", ".aif"}
EXAMPLE_LIMIT = 3

# NAS には依存も一時ファイルも置かず、このソースを Python の標準入力へ渡す。
# ここでは収集だけを行い、タグ名の解釈や欠落・矛盾の判定はローカルへ残す。
COLLECTOR = r'''
import sys
sys.dont_write_bytecode = True
import concurrent.futures as futures
import json
import os
import stat
import subprocess
import time

def emit(record):
    print(json.dumps(record, ensure_ascii=True), flush=True)

def probe(path):
    try:
        # FFREPORT がログファイルを作る設定でも、収集では有効にしない。
        environment = dict(os.environ)
        environment.pop("FFREPORT", None)
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a",
             "-show_entries", "format_tags:stream_tags", "-of", "json", path],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, encoding="utf-8", errors="replace", timeout=30,
            env=environment,
        )
        if result.returncode:
            return {"event": "track", "path": path, "error": result.stderr.strip()}
        metadata = json.loads(result.stdout)
        # 拡張子だけ音声の画像などを、タグ未設定の曲として数えない。
        if not metadata.get("streams"):
            raise ValueError("音声ストリームがありません")
        return {"event": "track", "path": path, "metadata": metadata}
    except Exception as error:
        return {"event": "track", "path": path, "error": str(error)}

def paths():
    def walk_error(error):
        emit({"event": "error", "message": str(error)})
    for directory, directories, files in os.walk(ROOT, onerror=walk_error, followlinks=False):
        emit({"event": "directory", "path": directory})
        for name in list(directories):
            if os.path.islink(os.path.join(directory, name)):
                directories.remove(name)
                emit({"event": "skip"})
        directories.sort()
        for name in sorted(files):
            if os.path.splitext(name)[1].lower() not in EXTENSIONS:
                continue
            path = os.path.join(directory, name)
            try:
                if not stat.S_ISREG(os.lstat(path).st_mode):
                    emit({"event": "skip"})
                    continue
            except OSError as error:
                walk_error(error)
                continue
            yield path

if not os.path.isabs(ROOT) or not os.path.isdir(ROOT):
    emit({"event": "error", "message": "リモートルートがディレクトリではありません: " + ROOT})
    sys.exit(1)

emit({"event": "begin", "root": ROOT})
completed = 0
last_progress = time.monotonic()
iterator = iter(paths())
exhausted = False
with futures.ThreadPoolExecutor(max_workers=4) as pool:
    pending = set()
    while pending or not exhausted:
        while not exhausted and len(pending) < 4:
            try:
                path = next(iterator)
            except StopIteration:
                exhausted = True
                emit({"event": "walk_done"})
                break
            emit({"event": "queued", "path": path})
            pending.add(pool.submit(probe, path))
        if not pending:
            break
        finished, pending = futures.wait(pending, timeout=2, return_when=futures.FIRST_COMPLETED)
        for future in finished:
            emit(future.result())
            completed += 1
        if time.monotonic() - last_progress >= 2 or completed % 100 < len(finished):
            print("収集進捗: %d ファイル完了 / 最大4並列" % completed, file=sys.stderr, flush=True)
            last_progress = time.monotonic()
emit({"event": "done", "completed": completed})
print("収集完了: %d ファイル" % completed, file=sys.stderr, flush=True)
'''


def normalize(value: str) -> str:
    return unicodedata.normalize("NFC", value)


def label(value: object) -> str:
    # 改行入りのタグやファイル名でも、報告の項目に見せかけた別行を作らせない。
    return normalize(str(value)).encode("unicode_escape").decode("ascii") if any(
        ord(c) < 32 or ord(c) == 127 for c in str(value)
    ) else normalize(str(value))


@dataclass(frozen=True)
class Number:
    value: int | None = None
    total: int | None = None
    problem: str | None = None


def parse_number(raw: object) -> Number:
    if raw is None:
        return Number()
    values = getattr(raw, "text", raw)
    if not isinstance(values, list):
        values = [values]
    parsed = set()
    for value in values:
        if isinstance(value, tuple) and len(value) == 2:
            text = f"{value[0]}/{value[1]}"
        else:
            text = str(value).strip()
        if not text:
            continue
        match = re.fullmatch(r"([0-9]+)(?:\s*/\s*([0-9]+))?", text)
        if not match:
            return Number(problem=f"番号タグの形式が不正: {values!r}")
        number = int(match[1])
        total = int(match[2]) if match[2] else 0
        if total and number > total:
            return Number(problem=f"番号が総数を超過: {text}")
        parsed.add((number or None, total or None))
    if len(parsed) > 1:
        return Number(problem=f"番号タグが複数あり不一致: {values!r}")
    return Number(*next(iter(parsed))) if parsed else Number()


def filename_pattern(stem: str) -> tuple[str, int | None, int | None]:
    name = normalize(stem)
    match = re.match(r"^([0-9]+)-([0-9]{2,})(?=$|[\s._-])", name)
    if match:
        return "ディスク番号付き", int(match[2]), int(match[1])
    match = re.match(r"^([0-9]{2,})(?=$|\s)", name)
    if match:
        return "先頭番号あり（空白区切り／番号のみ）", int(match[1]), None
    match = re.match(r"^([0-9]{2,})([._-])", name)
    if match:
        return f"先頭番号あり（{match[2]}区切り）", int(match[1]), None
    # 1 桁も分類するが、数字で始まる曲名まで推測で番号へ変換しない。
    match = re.match(r"^([0-9])(?=$|[\s._-])", name)
    if match:
        return "先頭番号あり（1桁）", int(match[1]), None
    if re.match(r"^[0-9]", name):
        return "数字始まり・番号として判定不能", None, None
    return "先頭に番号なし", None, None


@dataclass
class Track:
    path: Path
    pattern: str
    filename_track: int | None
    filename_disc: int | None
    track: Number
    disc: Number
    albums: tuple[str, ...] = ()
    error: str | None = None


def read_track(path: Path) -> Track:
    pattern, filename_track, filename_disc = filename_pattern(path.stem)
    result = Track(path, pattern, filename_track, filename_disc, Number(), Number())
    try:
        # パスを直接渡さず、書き込み能力のないストリームだけを mutagen に渡す。
        with path.open("rb") as stream:
            audio = mutagen.File(stream, easy=False)
            if audio is None:
                raise ValueError("mutagen が音声形式を認識できません")
            tags = audio.tags or {}
            keys = (
                ("trkn", "disk", "\xa9alb") if isinstance(audio, MP4)
                else ("TRCK", "TPOS", "TALB") if isinstance(audio.tags, ID3)
                else ("tracknumber", "discnumber", "album")
            )
            result.track = parse_number(tags.get(keys[0]))
            result.disc = parse_number(tags.get(keys[1]))
            albums = getattr(tags.get(keys[2], []), "text", tags.get(keys[2], []))
            if isinstance(albums, str):
                albums = [albums]
            result.albums = tuple(sorted({normalize(str(v).strip()) for v in albums if str(v).strip()}))
    except Exception as error:
        # 破損ファイル一つで NAS 全体の集計を中断せず、不明と未設定を区別する。
        result.error = f"{type(error).__name__}: {error}"
    return result


def probe_track(record: dict) -> Track:
    path = Path(record["path"])
    pattern, filename_track, filename_disc = filename_pattern(path.stem)
    result = Track(path, pattern, filename_track, filename_disc, Number(), Number())
    if record.get("error") is not None:
        result.error = record["error"] or "ffprobe が読み取りに失敗しました"
        return result
    metadata = record["metadata"]
    # Ogg/Opus は stream、MP4/ID3 は format にタグが出る。大小文字も吸収する。
    containers = [metadata.get("format", {})] + metadata.get("streams", [])
    tags = defaultdict(list)
    for container in containers:
        for key, value in container.get("tags", {}).items():
            tags[key.casefold()].append(value)

    def values(*keys: str) -> list:
        return [value for key in keys for value in tags[key]]

    result.track = parse_number(values("track", "tracknumber", "trck"))
    result.disc = parse_number(values("disc", "discnumber", "tpos"))
    result.albums = tuple(sorted({normalize(str(v).strip()) for v in values("album", "talb") if str(v).strip()}))
    return result


def collector_source(root: str) -> str:
    return f"ROOT = {root!r}\nEXTENSIONS = {sorted(EXTENSIONS)!r}\n" + COLLECTOR


def scan_ssh(host: str, root: Path) -> tuple[dict[Path, list[Track]], list[str], int]:
    albums = defaultdict(list)
    errors = []
    skipped = 0
    pending = set()
    received = set()
    complete = False
    walked = False
    last_directory = None
    # SSH はリモートコマンドをシェルで解釈するが、ルートはコマンドへ埋め込まず標準入力へ送る。
    command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
               "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
               "--", host, "python3 -B -"]
    print(f"SSH収集開始: {label(host)}:{label(root)}（最大4並列）", file=sys.stderr, flush=True)
    try:
        with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              text=True, encoding="utf-8") as process:
            try:
                process.stdin.write(collector_source(str(root)))
                process.stdin.close()
                for line in process.stdout:
                    record = json.loads(line)
                    event = record["event"]
                    if event in {"queued", "track", "directory"}:
                        path = Path(record["path"])
                        # 壊れたストリームを別のルートの結果として集計しない。
                        path.relative_to(root)
                        if ".." in path.parts:
                            raise ValueError("収集パスに親ディレクトリ参照があります")
                    if event == "queued":
                        pending.add(record["path"])
                    elif event == "track":
                        if record["path"] not in pending or record["path"] in received:
                            raise ValueError("収集結果の重複または未登録パス")
                        track = probe_track(record)
                        albums[track.path.parent].append(track)
                        pending.remove(record["path"])
                        received.add(record["path"])
                    elif event == "directory":
                        last_directory = record["path"]
                    elif event == "skip":
                        skipped += 1
                    elif event == "error":
                        errors.append(record["message"])
                    elif event == "walk_done":
                        walked = True
                    elif event == "done":
                        complete = walked and not pending and record["completed"] == len(received)
                    elif event != "begin":
                        raise ValueError(f"不明な収集イベント: {event}")
                returncode = process.wait()
                if returncode:
                    errors.append(f"SSH/収集プロセスの終了コード: {returncode}")
                    complete = False
            except (OSError, ValueError, KeyError, TypeError, KeyboardInterrupt) as error:
                process.terminate()
                errors.append(f"収集中断: {type(error).__name__}: {error}")
                complete = False
    except OSError as error:
        errors.append(f"SSHを起動できません: {error}")
    if not complete:
        message = f"【未完了・部分集計】受信済み {len(received)} ファイル / 開始済み未受信 {len(pending)} ファイル"
        errors.append(message)
        print(message, flush=True)
        print(f"ディレクトリ走査: {'完了' if walked else '未完了（未発見ファイル数は不明）'} / 最後の走査先: {label(last_directory)}")
        print("未受信パス:")
        examples(sorted(pending), True)
        print("受信済みフォルダ（この件数だけ集計済み。フォルダ全件の完了を意味しません）:")
        for folder, tracks in sorted(albums.items()):
            print(f"  {label(folder)}: {len(tracks)} ファイル")
    # 並列完了順で代表例が揺れないよう、ローカル走査と同じ順序へ戻す。
    return {folder: sorted(tracks, key=lambda t: normalize(t.path.name))
            for folder, tracks in sorted(albums.items(), key=lambda item: normalize(str(item[0])))}, errors, skipped


def scan(root: Path) -> tuple[dict[Path, list[Track]], list[str], int]:
    albums = defaultdict(list)
    errors = []
    skipped = 0

    def traversal_error(error: OSError) -> None:
        errors.append(f"{error.filename}: {error.strerror}")

    for directory, directories, files in os.walk(root, onerror=traversal_error, followlinks=False):
        # リンク先のループやルート外の二重集計を避ける。実際のパスは正規化しない。
        for name in list(directories):
            if (Path(directory) / name).is_symlink():
                directories.remove(name)
                skipped += 1
        directories.sort(key=normalize)
        for name in sorted(files, key=normalize):
            path = Path(directory) / name
            if path.suffix.lower() not in EXTENSIONS:
                continue
            try:
                mode = path.lstat().st_mode
                if not stat.S_ISREG(mode):
                    skipped += 1
                    continue
            except OSError as error:
                traversal_error(error)
                continue
            albums[path.parent].append(read_track(path))
    return dict(albums), errors, skipped


def examples(items: list[str], verbose: bool, indent: str = "  ") -> None:
    for item in items if verbose else items[:EXAMPLE_LIMIT]:
        print(indent + label(item))
    if not verbose and len(items) > EXAMPLE_LIMIT:
        print(f"{indent}…ほか {len(items) - EXAMPLE_LIMIT} 件（--verbose で全件）")


def report(root: Path, albums: dict[Path, list[Track]], errors: list[str], skipped: int, verbose: bool) -> int:
    def relative(path: Path) -> str:
        return str(path.relative_to(root))

    all_tracks = [track for tracks in albums.values() for track in tracks]
    readable = [track for track in all_tracks if track.error is None]
    missing = [track for track in readable if track.track.value is None]
    affected = {track.path.parent for track in missing}
    print(f"調査ルート: {label(root)}")
    print("欠落あり（不正な番号タグも未設定に含む／読めなかったファイルは判定対象外）:")
    for folder, tracks in albums.items():
        absent = [track for track in tracks if track.error is None and track.track.value is None]
        if not absent:
            continue
        unknown = sum(track.error is not None for track in tracks)
        print(f"  {label(relative(folder))}  {len(absent)}/{len(tracks)} 曲が未設定（判定不能 {unknown} 曲）")
        if verbose:
            examples([relative(track.path) for track in absent], True, "    ")
    if not missing:
        print("  なし")
    print(f"合計: {len(albums)} アルバム / 未設定 {len(missing)} 曲 / 全 {len(all_tracks)} 曲")
    print(f"欠落あり {len(affected)} アルバム / 読取成功 {len(readable)} 曲 / ディスク番号未設定 {sum(t.disc.value is None for t in readable)} 曲")

    print("\nファイル名の命名パターン（欠落のあるアルバム内の全対象ファイル）:")
    print("先頭数字は候補であり、曲名の数字・年号との区別やタグへの採用は行いません。")
    for folder, tracks in albums.items():
        if folder not in affected:
            continue
        counts = Counter(track.pattern for track in tracks)
        marker = "【混在】" if len(counts) > 1 else ""
        print(f"  {marker}{label(relative(folder))}")
        for pattern, count in sorted(counts.items()):
            print(f"    {pattern}（{count}/{len(tracks)} ファイル）")
            examples([t.path.name for t in tracks if t.pattern == pattern], verbose, "      ")

    conflicts = []
    problems = []
    album_mismatches = []
    missing_albums = 0
    for track in readable:
        for name, candidate, number in (
            ("トラック", track.filename_track, track.track),
            ("ディスク", track.filename_disc, track.disc),
        ):
            if candidate is not None and number.value is not None and candidate != number.value:
                conflicts.append(f"{relative(track.path)}: {name}番号 ファイル名={candidate} / タグ={number.value}")
            if number.problem:
                problems.append(f"{relative(track.path)}: {name}: {number.problem}")
        if not track.albums:
            missing_albums += 1
        elif any(album != normalize(track.path.parent.name) for album in track.albums):
            album_mismatches.append(f"{relative(track.path)}: アルバムタグ={track.albums!r}")

    print(f"\n【要確認】ファイル名とタグの番号矛盾: {len(conflicts)} 件")
    examples(conflicts, verbose)
    print(f"\n番号タグの不正値: {len(problems)} 件")
    examples(problems, verbose)
    print(f"\nアルバムタグと親フォルダ名の不一致: {len(album_mismatches)} ファイル / アルバムタグなし {missing_albums} 曲")
    examples(album_mismatches, verbose)
    unreadable = [f"{relative(t.path)}: {t.error}" for t in all_tracks if t.error is not None]
    print(f"\n読めなかった: {len(unreadable)} ファイル / 走査エラー {len(errors)} 件")
    examples(unreadable, verbose)
    examples(errors, verbose)
    print(f"リンク・通常ファイル以外の除外: {skipped} 件")
    return 1 if unreadable or errors else 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="音源を読み取り専用で調査し、親フォルダ単位のトラック番号欠落・命名規則・矛盾を報告します。",
        epilog="リンクは追跡しません。終了コード: 0=走査完了、1=読取・走査エラーあり、2=引数エラー。",
    )
    parser.add_argument("root", type=Path, nargs="?", help="再帰走査するローカルルートディレクトリ")
    parser.add_argument("--ssh", metavar="HOST:/REMOTE/ROOT", help="SSH経由でffprobeを使って収集（最大4並列、NASへの書き込みなし）")
    parser.add_argument("--verbose", action="store_true", help="未設定ファイルと代表例・矛盾・エラーを省略せず全件表示")
    args = parser.parse_args()
    if bool(args.root) == bool(args.ssh):
        parser.error("ローカルrootまたは --ssh HOST:/REMOTE/ROOT のどちらか一方を指定してください")
    if args.ssh:
        host, separator, remote_root = args.ssh.partition(":")
        if not separator or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@-]*", host) or not remote_root.startswith("/"):
            parser.error("--ssh は HOST:/絶対パス で指定してください（HOSTはSSH configの別名も可）")
        root = Path(os.path.normpath(remote_root))
        albums, errors, skipped = scan_ssh(host, root)
        return report(root, albums, errors, skipped, args.verbose)
    try:
        root = args.root.expanduser().resolve(strict=True)
    except (OSError, RuntimeError) as error:
        parser.error(str(error))
    if not root.is_dir():
        parser.error("ルートにはディレクトリを指定してください")
    albums, errors, skipped = scan(root)
    return report(root, albums, errors, skipped, args.verbose)


if __name__ == "__main__":
    raise SystemExit(main())
