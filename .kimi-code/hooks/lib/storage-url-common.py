# [2026-05-16][refactor]
# 背景:
#   - ユーザー依頼意図: gmail-mcp へ配布された hook-library の Python ファイルも、配布先の CaD ルールに合う形へ揃えたい。
#   - 守るべき業務ルール: Python ファイル冒頭には shebang 直後または冒頭に # 形式の CaD ヘッダーを置く。
#   - 他案不採用理由: docstring 内の履歴だけに残す案は、配布先の CaD 検査で冒頭ヘッダーとして認識されないため不採用。
# 対応: 既存 docstring 履歴を残したまま、冒頭に配布共通の CaD ヘッダーを追加。
"""
Storage URL検証の共通ロジック。
storage-url-check.sh (PostToolUse) と storage-url-pr-gate.sh (PreToolUse) から呼び出される。

[2026-03-03][refactor]
背景: jtt-cms Gen 3 のstorage-url-common.pyをAGENT-HUBのhook-libraryにポート。
  Supabase Storage URLの存在検証をPJ横断で共有するためコンポーネント化。
対応: jtt-cms storage-url-common.py をそのままポート。

[2026-03-04][fix]
背景: ユーザー意図は「Python実行環境差でチェックが無効化されないこと」。
  業務ルールとして、共通ライブラリは最低運用環境でも構文エラーなく動作する必要がある。
  代替案として Python 3.9+ 専用型ヒントを維持すると、3.8系でゲートが素通りするため不採用。
対応: 型ヒントを typing.List/Set/Tuple へ置換し、互換性を確保。

使い方:
  python3 lib/storage-url-common.py <mode> <file1> [<file2> ...]
  mode: "check" (PostToolUse用) または "gate" (PreToolUse用)

- check モード: 最大5URL検証、未アップロードがあれば stderr + exit 2
- gate モード: 最大10URL検証（並列）、未アップロードがあれば deny理由を stdout + exit 1
"""

import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Set, Tuple

# --- 定数 ---
CURL_TIMEOUT_SECONDS = 2
MAX_URLS_CHECK_MODE = 5
MAX_URLS_GATE_MODE = 10

STORAGE_URL_PATTERN = re.compile(
    r"https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/[^\x22\x27\s,)\]}\x60]+"
)


def remove_sql_comments(content: str) -> str:
    """SQLコメントを除去する。コメント内のURLを誤検知しないため。"""
    content = re.sub(r"--[^\n]*", "", content)
    content = re.sub(r"/\*.*?\*/", "", content, flags=re.DOTALL)
    return content


def extract_storage_urls(filepaths: List[str]) -> List[str]:
    """ファイル群からStorage URLを抽出し、重複排除・ソートして返す。"""
    all_urls: Set[str] = set()
    for fp in filepaths:
        if not os.path.isfile(fp):
            continue
        try:
            content = open(fp, encoding="utf-8").read()
        except Exception:
            continue
        cleaned = remove_sql_comments(content)
        all_urls.update(STORAGE_URL_PATTERN.findall(cleaned))
    return sorted(all_urls)


def check_url_head(url: str) -> Tuple[str, str]:
    """curl HEAD でURLの存在を検証し、(url, HTTPステータス) を返す。"""
    try:
        result = subprocess.run(
            [
                "curl", "-sI",
                "--max-time", str(CURL_TIMEOUT_SECONDS),
                "-o", "/dev/null",
                "-w", "%{http_code}",
                url,
            ],
            capture_output=True,
            text=True,
            timeout=CURL_TIMEOUT_SECONDS + 3,
        )
        return (url, result.stdout.strip())
    except Exception:
        return (url, "error")


def build_upload_hints(missing_urls: List[Tuple[str, str]]) -> List[str]:
    """未アップロードURLからバケット名・パスを逆算し、アップロードコマンドを生成する。"""
    hints: List[str] = []
    for url, _ in missing_urls:
        m = re.search(r"https://[^/]+/storage/v1/object/public/([^/]+)/(.+)", url)
        if m:
            hints.append(f"  pnpm upload:storage {m.group(1)} {m.group(2)}")
    return hints


def run_check_mode(filepaths: List[str]) -> None:
    """PostToolUse用: 逐次検証、未アップロードがあればstderr + exit 2。"""
    urls = extract_storage_urls(filepaths)
    if not urls:
        sys.exit(0)

    check_urls = urls[:MAX_URLS_CHECK_MODE]
    remaining = max(0, len(urls) - MAX_URLS_CHECK_MODE)

    missing: List[Tuple[str, str]] = []
    for url in check_urls:
        url, status = check_url_head(url)
        if status != "200":
            missing.append((url, status))

    if not missing:
        sys.exit(0)

    msg = "\n[hook:storage-url-check] 未アップロードのStorage画像を検出しました:\n"
    for url, status in missing:
        msg += f"  - {url} -> HTTP {status}\n"
    if remaining > 0:
        msg += f"  (他に{remaining}件のURLが未検証です)\n"

    hints = build_upload_hints(missing)
    msg += "\nアップロード方法:\n"
    if hints:
        msg += "\n".join(hints) + "\n"
    else:
        msg += "  Supabase DashboardまたはMCP経由でStorage画像をアップロードしてください。\n"
    msg += "\nアップロード完了後、再度ファイルを保存してください。\n"

    sys.stderr.write(msg)
    sys.exit(2)


def run_gate_mode(filepaths: List[str]) -> None:
    """PreToolUse用: 並列検証、未アップロードがあればdeny理由をstdout + exit 1。"""
    urls = extract_storage_urls(filepaths)
    if not urls:
        sys.exit(0)

    check_urls = urls[:MAX_URLS_GATE_MODE]
    remaining = max(0, len(urls) - MAX_URLS_GATE_MODE)

    missing: List[Tuple[str, str]] = []
    with ThreadPoolExecutor(max_workers=MAX_URLS_GATE_MODE) as executor:
        futures = {executor.submit(check_url_head, url): url for url in check_urls}
        for future in as_completed(futures):
            url, status = future.result()
            if status != "200":
                missing.append((url, status))

    if not missing:
        sys.exit(0)

    parts = [
        "[hook:storage-url-pr-gate] 未アップロードのStorage画像があります。"
        "PR作成前にアップロードしてください。\\n\\n未検証URL:"
    ]
    for url, status in sorted(missing):
        parts.append(f"  - {url} -> HTTP {status}")

    if remaining > 0:
        parts.append(f"  (他に{remaining}件のURLが未検証です)")

    hints = build_upload_hints(sorted(missing))
    parts.append("\\nアップロード方法:")
    if hints:
        parts.extend(hints)
    else:
        parts.append("  Supabase DashboardまたはMCP経由でStorage画像をアップロードしてください。")

    print("\\n".join(parts))
    sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <check|gate> <file1> [file2 ...]", file=sys.stderr)
        sys.exit(1)

    mode = sys.argv[1]
    files = sys.argv[2:]

    if mode == "check":
        run_check_mode(files)
    elif mode == "gate":
        run_gate_mode(files)
    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)
