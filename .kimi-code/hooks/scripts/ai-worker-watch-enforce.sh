#!/usr/bin/env bash
# [2026-09-01][feat] ai-worker 見張り設置の強制 hook（ai-worker-watch-enforce.sh）
# 背景:
#   - ユーザー依頼意図: ai-worker への委譲時に見張り（scripts/watch-worker-job.sh）の
#     立て忘れが発生し、ワーカーが落ちても利用者が話しかけるまで誰も気づかない事故
#     （2026-09-01 に5本中3本で実際に発生。2026-08-27 には正常終了後12時間放置の実例）
#     を機械的に防ぎたい。既に .claude/rules/general/ai-worker-watch.md が「委譲直後に
#     見張りを1本立てる」を義務として定めているが、守り忘れを検知する仕組みが無かった
#     ため、人間・AI の記憶に頼らず hook が毎回指摘する。
#   - 守るべき業務ルール:
#     1) hook から見張りプロセスを自動起動しない（設計上の最重要制約。理由は下記不採用1）。
#     2) どの経路でも exit 0・非ブロック（fail-open）。hook が作業を壊すことは絶対に避ける。
#     3) プロセス探索は自分のユーザーのものだけを読む（他セッションのプロセスを停止・変更しない）。
#     4) 台帳・ジョブ置き場のパスは env（AI_WORKER_WATCH_LEDGER / AI_WORKER_JOBS_DIR）で
#        差し替え可能にする（テスト隔離用。credit-baton-preflight.sh と同じ作法）。
#   - 他案不採用理由:
#     1) hook から見張りプロセスを自動起動する案 → hook が起動したプロセスはセッションから
#        切り離されるため、ジョブ終了を検知しても統括役（Claude）を起こせない。
#        「見張っているのに誰も気づかない」という今より悪い状態になるため不採用。
#     2) ルール文書（ai-worker-watch.md）に書くだけの案 → 既に義務として書かれていた
#        にもかかわらず、2026-09-01 に5本中3本で守られなかった。記憶に頼る仕組みでは
#        防げないため不採用。
#     3) 委譲そのものをブロックする案 → hook が作業を止めると、見張りの都合で本来の
#        仕事が進まなくなる。指摘に留め、fail-open を徹底するため不採用。
#   - 他案不採用理由（追記）: 再帰探索が値を潜るだけで job_id キーを判定しない実装は、必ず None を返し
#     互換フォールバックが空回りする。ネストした応答形式で見張り記録も警告も静かに抜けるため不採用
#     （2026-09-01 Codexレビュー指摘・実測確認）。各 dict の job_id を JOB_ID_RE で検証して返す。
#   - 他案不採用理由（追記）: payload 全体を再帰探索して job_id を拾う案は、tool_input 側の別 job_id を
#     先に拾い、今起動した worker が台帳・警告から漏れるため不採用（2026-09-01 Codexレビュー指摘）。
#     tool_response 配下に限定して取得する。
#   - 他案不採用理由（追記）: decision: "block" で委譲を止める案は、見張りの都合で本来の仕事が
#     止まるため不採用（2026-09-01 実走で発覚。前段の実装が自身の CaD と矛盾していた）。
#     指摘は強く出すが、作業は必ず通す。
#   - 他案不採用理由（追記）: 空の台帳を「壊れている」と扱う案は、初回が必ず空であり毎回警告が出て
#     本当の破損が埋もれるため不採用。存在しない・空・解析不能の3状態を分ける。
#   - 他案不採用理由（追記）: 台帳を固定の .tmp で read-modify-write する案は、複数の委譲が同時に
#     終わったとき後書きが先行記録を消し、見張り対象が台帳から脱落するため不採用
#     （2026-09-01 Codexレビュー指摘）。flock で読取から置換までを排他する。
#   - 他案不採用理由（追記）: job_id を ps 出力の部分一致で照合する案は、job-a と job-a-old のような
#     包含関係や別プロセス引数への偶然の混入で「見張り有り」と誤判定するため不採用。
#     watch-worker-job.sh の直後の引数と完全一致させる。
#   - 他案不採用理由（追記）: watched: true を恒久的な記録として信用する案は、見張りが途中で
#     落ちた実行中ジョブを「設置済み」と扱い、この hook の目的そのものを損なうため不採用
#     （2026-09-01 Codexレビュー指摘）。毎回プロセスの生存を確認する。
# 対応: PostToolUse（mcp__ai-worker-mcp__delegate_impl）で stdin JSON から job_id を取り
#   台帳へ記録。終了済み（status が running 以外／.terminal 存在）と記録24時間超の
#   エントリを掃除し、見張り未設置（実行中の watch-worker-job.sh <job_id> プロセスが
#   無い）ジョブがあれば PostToolUse フィードバックで「見張りを立てよ」と突き返す。
#   [2026-09-01][fix] この2行の記述を実装へ合わせた。旧記述は (a) 判定条件に「台帳の
#   watched が false」を併記していたが、実装は毎回プロセスの生存だけで判定する（台帳の
#   watched は記録用であり判定には使わない。見張りが途中で落ちた場合に「設置済み」と
#   誤認しないため）(b) 出力を「decision/block」と書いていたが、実装は decision:"approve"
#   を返す（作業を止めない fail-open が設計方針であり、block は自身の不採用理由と矛盾する）。
#   コメントと実装の契約がずれたままだと、次に読む者が誤った前提で直すため揃える。
#   出力契約は decision:"approve" + reason（委譲は通し、reason が統括役へ渡る）。
#   プロセス一覧の取得には
#   ps -u <uid> -o args= を使う（読むだけ）。AI_WORKER_WATCH_PS_FILE があれば実 ps の
#   代わりにそのファイルの行を読むテスト用 seam として動作する。

set -u

# python3 が無ければ何も出さず exit 0（fail-open）
command -v python3 >/dev/null 2>&1 || exit 0

RAW_INPUT="$(cat 2>/dev/null || true)"
# 空入力は静かに抜ける（他の tool 呼び出しを邪魔しない）
[ -n "$RAW_INPUT" ] || exit 0

LEDGER_PATH="${AI_WORKER_WATCH_LEDGER:-${XDG_CACHE_HOME:-$HOME/.cache}/agent-hub/ai-worker-watch-ledger.json}"
JOBS_DIR="${AI_WORKER_JOBS_DIR:-$HOME/.cache/agent-hub/ai-worker-mcp/jobs}"

# python スクリプト本体（プロセス置換でファイル引数として渡し、stdin は hook 入力 JSON 専用。
# delegation-routing-backstop.sh と同型。env 経由ではなく argv でパスを渡す）。
WATCH_ENFORCE_PY() {
  cat <<'PY'
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

# 台帳ロックの取得期限と再試行間隔。長く待たない（hook が SessionStart 等を止めないため）が、
# 通常の同時実行では取りこぼさない程度には粘る。
LOCK_WAIT_SECONDS = 3.0
LOCK_RETRY_SECONDS = 0.05

# 見張りスクリプトの置き場。既存 hook（fable-implementation-guard.sh 等）と同じ作法で
# env による上書きを許し、未設定なら標準配置へフォールバックする。
WATCHER_SCRIPT_ROOT = os.environ.get("AGENT_HUB_ROOT") or os.path.expanduser(
    "~/business/AGENT-HUB"
)

LEDGER_PATH = sys.argv[1]
JOBS_DIR = sys.argv[2]
DAY_SECONDS = 24 * 3600
WATCHER_MARK = "watch-worker-job.sh"
# job_id は台帳記録と <job_id>.json / <job_id>.terminal のパス構築に使うため、
# 経路区切り等を含まない既知文字集合だけを許可する（path traversal 対策。
# delegation-routing-backstop.sh の session_id sha256 化と同旨の防御）。
JOB_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def find_job_id(payload):
    """tool_response 配下から job_id を取得する。tool_input は対象にしない。"""
    tool_response = payload.get("tool_response")
    if not isinstance(tool_response, dict):
        # tool_response が文字列の場合、JSON として解析を試みる
        if isinstance(tool_response, str):
            try:
                tool_response = json.loads(tool_response)
            except Exception:
                return None
        else:
            return None
    if not isinstance(tool_response, dict):
        return None
    # 1. スキーマどおりの正規の場所（最優先）
    value = tool_response.get("job_id")
    if isinstance(value, str) and JOB_ID_RE.match(value):
        return value
    # 2. tool_response 配下の再帰探索（互換フォールバック）
    def _recursive_find(obj):
        if isinstance(obj, dict):
            # まず自分自身の job_id を確認（浅い方を優先）
            value = obj.get("job_id")
            if isinstance(value, str) and JOB_ID_RE.match(value):
                return value
            # マッチしない場合だけ、値を再帰する
            for child in obj.values():
                found = _recursive_find(child)
                if found:
                    return found
        elif isinstance(obj, list):
            for child in obj:
                found = _recursive_find(child)
                if found:
                    return found
        return None
    return _recursive_find(tool_response)


def list_own_process_args():
    # テスト用 seam: AI_WORKER_WATCH_PS_FILE がある時は実 ps を叩かずそのファイルの行を使う
    # （実マシンの他セッション プロセスに依存しないテストのため）。
    ps_file = os.environ.get("AI_WORKER_WATCH_PS_FILE", "")
    if ps_file:
        try:
            with open(ps_file, encoding="utf-8", errors="replace") as f:
                return f.read().splitlines()
        except Exception:
            return []
    # 本番経路: 自分の uid のプロセスの引数列を読むだけ（停止・変更はしない）。
    try:
        result = subprocess.run(
            ["ps", "-u", str(os.getuid()), "-o", "args="],
            capture_output=True,
            text=True,
            timeout=3,
        )
        if result.returncode == 0:
            return result.stdout.splitlines()
    except Exception:
        pass
    # ps が取れない環境では「見張り無し」として扱う（警告側へ倒す。
    # 見逃しより指摘を優先する方向。台帳の watched:true は有効）。
    return []


def extract_watched_job_ids(ps_lines):
    """ps 出力の各行から watch-worker-job.sh の直後の引数を完全一致で取り出す。"""
    watched = set()
    for line in ps_lines:
        # watch-worker-job.sh が含まれていない行は無視
        if WATCHER_MARK not in line:
            continue
        # 行を空白で分割して引数列にする
        parts = line.strip().split()
        # watch-worker-job.sh（またはそのパス）の直後の引数を探す
        for i, part in enumerate(parts):
            # パス付きでも basename でもマッチ
            if os.path.basename(part) == WATCHER_MARK or part.endswith("/" + WATCHER_MARK):
                # 直後の引数があればそれを job_id として採用
                if i + 1 < len(parts):
                    candidate = parts[i + 1]
                    # job_id 形式の検証（path traversal 対策と偶然の混入対策）
                    if JOB_ID_RE.match(candidate):
                        watched.add(candidate)
                break
    return watched


def parse_recorded_at(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def job_finished(job_id):
    # 終端ファイルがあれば終わっている（.json の status より優先）。
    if os.path.exists(os.path.join(JOBS_DIR, job_id + ".terminal")):
        return True
    job_json = os.path.join(JOBS_DIR, job_id + ".json")
    if os.path.exists(job_json):
        try:
            with open(job_json, encoding="utf-8") as f:
                doc = json.load(f)
            if isinstance(doc, dict):
                status = doc.get("status")
                if isinstance(status, str) and status != "running":
                    return True
        except Exception:
            # .json が読めない場合は「不明」として保持する（fail-open。24hで掃除される）。
            pass
    return False


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except Exception:
        return
    if not isinstance(payload, dict):
        return
    job_id = find_job_id(payload)
    if not job_id:
        return

    now = datetime.now(timezone.utc)

    entries = []
    ledger_broken = False
    if os.path.exists(LEDGER_PATH):
        try:
            with open(LEDGER_PATH, encoding="utf-8") as f:
                raw_ledger = f.read()
            if raw_ledger.strip():
                try:
                    doc = json.loads(raw_ledger)
                except Exception:
                    # 壊れた台帳は新規作成して続行（破損警告のみ）。
                    ledger_broken = True
                else:
                    if isinstance(doc, dict) and isinstance(doc.get("entries"), list):
                        raw_entries = [
                            e
                            for e in doc["entries"]
                            if isinstance(e, dict) and isinstance(e.get("job_id"), str)
                        ]
                        seen = set()
                        for e in raw_entries:
                            if e["job_id"] in seen:
                                continue
                            seen.add(e["job_id"])
                            entries.append(e)
                    else:
                        ledger_broken = True
        except Exception:
            # 既存台帳が読めない状態は壊れとして扱い、warn のみで復旧して続行する。
            ledger_broken = True

    if ledger_broken:
        # 壊れた台帳は新規作成して続行（警告のみ。作業は止めない）。
        print(
            "ai-worker-watch-enforce: 台帳が壊れているため新規作成します",
            file=sys.stderr,
        )
        entries = []

    # 新規委譲を記録（既にあれば重複させない）。
    if not any(e.get("job_id") == job_id for e in entries):
        entries.append(
            {"job_id": job_id, "recorded_at": now.isoformat(), "watched": False}
        )

    ps_lines = list_own_process_args()
    watched_ids = extract_watched_job_ids(ps_lines)

    kept = []
    unwatched = []
    for entry in entries:
        current_id = entry["job_id"]
        recorded_at = parse_recorded_at(entry.get("recorded_at"))
        if recorded_at is None or (now - recorded_at).total_seconds() > DAY_SECONDS:
            continue
        if job_finished(current_id):
            continue
        has_watcher = current_id in watched_ids
        entry["watched"] = bool(has_watcher)
        if not has_watcher:
            unwatched.append(current_id)
        kept.append(entry)

    # 台帳へ保存（flock で排他ロック。プロセスごとの一意な一時ファイル + rename の原子書き込み）。
    try:
        ledger_dir = os.path.dirname(LEDGER_PATH)
        if ledger_dir:
            os.makedirs(ledger_dir, exist_ok=True)
        lock_path = LEDGER_PATH + ".lock"
        tmp_path = LEDGER_PATH + ".tmp." + str(os.getpid())
        with open(lock_path, "w", encoding="utf-8") as lock_f:
            # 短いタイムアウトでロック取得を試みる（待ちすぎない）。
            # タイムアウトしたら台帳更新を諦め、指摘だけは出して exit 0（fail-open）。
            # [2026-09-01][fix] 一度きりの LOCK_NB を、短い期限つきの再試行へ変える。
            # 背景: 一度失敗しただけで台帳更新を諦める作りだったため、3本同時に委譲が終わると
            #   2本が記録を捨て、見張り対象が台帳から脱落していた（並行実行テストで検出）。
            #   「待ちすぎない」は守りつつ、通常の同時実行では取りこぼさない必要がある。
            # 他案不採用理由: LOCK_EX のブロッキング待ちにする案は、ロック保持者が異常終了したとき
            #   hook が無限に待ち、SessionStart 等を止めるため不採用。期限つき再試行にする。
            lock_deadline = time.monotonic() + LOCK_WAIT_SECONDS
            lock_acquired = False
            lock_error = None
            try:
                import fcntl
                while True:
                    try:
                        fcntl.flock(lock_f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                        lock_acquired = True
                        break
                    except OSError as exc:
                        if time.monotonic() >= lock_deadline:
                            lock_error = exc
                            break
                        time.sleep(LOCK_RETRY_SECONDS)
            except ImportError as exc:
                lock_error = exc
            if not lock_acquired:
                print(
                    "ai-worker-watch-enforce: 台帳のロックが取れないため更新を諦めます"
                    f"（{LOCK_WAIT_SECONDS}秒待機・理由: {lock_error}）",
                    file=sys.stderr,
                )
                # ロック取れなくても指摘は出す（台帳更新だけスキップ）
                if unwatched:
                    _emit_feedback(unwatched)
                return
            # ロック取得後に再読み込み（他プロセスが更新した可能性がある）
            latest_entries = kept
            if os.path.exists(LEDGER_PATH):
                try:
                    with open(LEDGER_PATH, encoding="utf-8") as f:
                        raw_ledger = f.read()
                    if raw_ledger.strip():
                        doc = json.loads(raw_ledger)
                        if isinstance(doc, dict) and isinstance(doc.get("entries"), list):
                            # 他プロセスのエントリとマージ（自分の job_id は上書き）
                            existing = {}
                            for e in doc["entries"]:
                                if isinstance(e, dict) and isinstance(e.get("job_id"), str):
                                    existing[e["job_id"]] = e
                            for e in kept:
                                existing[e["job_id"]] = e
                            # 現在の委譲 job_id がまだ無ければ追加
                            if not any(e.get("job_id") == job_id for e in kept):
                                existing[job_id] = {
                                    "job_id": job_id,
                                    "recorded_at": now.isoformat(),
                                    "watched": False,
                                }
                            # [2026-09-01][fix] マージ後にもう一度、生死と期限で絞る。
                            # 背景: ロック取得後の再読み込みは他プロセスの更新を取り込むためだが、
                            #   ファイルから読み直した時点で、走査で除外したはずの終了済みエントリが
                            #   復活してしまう（kept で上書きするのは自分が持つ job_id だけのため）。
                            #   実測（2026-09-01）で「終了済みジョブが台帳に残る」テスト失敗として検出した。
                            # 他案不採用理由: テストを緩めて残存を許す案は、台帳が無限に膨らみ走査コストが
                            #   増え続けるため不採用。マージ結果へ同じ判定をもう一度かける。
                            merged = []
                            for e in existing.values():
                                mid = e.get("job_id")
                                if not isinstance(mid, str):
                                    continue
                                merged_at = parse_recorded_at(e.get("recorded_at"))
                                if merged_at is None or (now - merged_at).total_seconds() > DAY_SECONDS:
                                    continue
                                if job_finished(mid):
                                    continue
                                merged.append(e)
                            latest_entries = merged
                except Exception:
                    pass
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump({"entries": latest_entries}, f, ensure_ascii=False, indent=2)
            os.replace(tmp_path, LEDGER_PATH)
            try:
                fcntl.flock(lock_f.fileno(), fcntl.LOCK_UN)
            except Exception:
                pass
    except Exception as e:
        print(
            "ai-worker-watch-enforce: 台帳書き込み失敗: {}".format(e),
            file=sys.stderr,
        )

    if not unwatched:
        return

    _emit_feedback(unwatched)


def _emit_feedback(unwatched):
    message_lines = [
        "⛔ ai-worker の見張りが未設置です（{n}件）。今すぐ background で立ててください。".format(
            n=len(unwatched)
        ),
        "",
        # [2026-09-01][fix] 見張りコマンドのパスを env で解決可能にする。
        # 背景: global include として全PJへ配る hook なので、AGENT-HUB の配置が標準と違う環境では
        #   ~/business/AGENT-HUB 固定の案内どおりに実行できない（2026-09-01 Codexレビュー指摘）。
        # 他案不採用理由: 案内文からパスを消して「見張りを立てよ」だけにする案は、受け取った側が
        #   毎回パスを調べ直すことになり、立て忘れ防止という目的を弱めるため不採用。
        "  {root}/scripts/watch-worker-job.sh {first} 1800".format(
            root=WATCHER_SCRIPT_ROOT, first=unwatched[0]
        ),
        "",
        "  未設置: " + unwatched[0],
    ]
    for extra in unwatched[1:]:
        message_lines.append("          " + extra)
    message_lines.append("")
    message_lines.append(
        "立てるまで「待ちで大丈夫」と報告しないこと。見張りは統括役のセッションから起動したものだけが、"
    )
    message_lines.append(
        "終了時に統括役を起こせます（hook が裏で起動したものは誰も起こせません）。"
    )

    # PostToolUse フィードバック（delegation-routing-backstop.sh と同型の decision/reason
    # スキーマ。委譲自体は取り消されず、reason が統括役へ渡る）。
    print(
        json.dumps(
            {"decision": "approve", "reason": "\n".join(message_lines)},
            ensure_ascii=False,
        )
    )


try:
    main()
except Exception:
    pass
PY
}

printf '%s' "$RAW_INPUT" | python3 <(WATCH_ENFORCE_PY) "$LEDGER_PATH" "$JOBS_DIR"

# どの経路でも exit 0（fail-open。hook が作業を止めない）。
exit 0
