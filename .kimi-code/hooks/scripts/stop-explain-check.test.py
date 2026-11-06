#!/usr/bin/env python3
# [2026-11-02][test] stop-explain-check.py の回帰。
# 背景: 説明の依頼に検品済みページの URL を付けず返す抜け道を Stop hook で1回だけ止める
#   （伸太郎さん 2026-11-02「言われないと動かないのはあってはならない」）。
# 守る: Claude Code と Codex の両方の会話記録の形で同じ結果になること。HOME・配信の記録・
#   検品の記録・台帳はすべて tmp に向け、本物の記録を読み書きしない。
# 不採用: 片方の形式だけのテスト（Codex で黙って動かない事故を見逃す）。
"""Regression tests for stop-explain-check.py."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

HOOK_PATH = Path(__file__).resolve().parent / "stop-explain-check.py"
SPEC = importlib.util.spec_from_file_location("stop_explain_check", HOOK_PATH)
assert SPEC and SPEC.loader
HOOK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOOK)

HOST = "https://macstudio-test.example.ts.net:18447"
USER_AT = "2026-11-02T10:00:00Z"
AFTER = "2026-11-02T10:05:00Z"
BEFORE = "2026-11-02T09:00:00Z"
REASON = "説明の依頼です。図つきの説明ページを作り検品してから、その URL を返してください"
EXPLAIN_ASK = "ビフォーアフターをわかりやすく説明して"
FORMATS = ("claude", "codex")


def _sha(path: str) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _entry(fmt: str, role: str, text: str, ts: str | None) -> dict:
    if fmt == "claude":
        entry = {
            "type": role,
            "message": {"role": role, "content": [{"type": "text", "text": text}]},
        }
    else:
        kind = "input_text" if role == "user" else "output_text"
        entry = {
            "type": "response_item",
            "payload": {"type": "message", "role": role, "content": [{"type": kind, "text": text}]},
        }
    if ts is not None:
        entry["timestamp"] = ts
    return entry


def _compact(fmt: str, text: str) -> dict:
    entry = _entry(fmt, "user", text, "2026-11-02T08:00:00Z")
    entry["isCompactSummary"] = True
    return entry


class Env:
    """tmp に配信フォルダ・記録・台帳・会話記録を作る。"""

    def __init__(self) -> None:
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="explain-check-test-"))
        self.status_dir = os.path.join(self.tmp, "status")
        self.state_dir = os.path.join(self.tmp, "state")
        self.record_dir = os.path.join(self.tmp, "records")
        self.home = os.path.join(self.tmp, "home")
        for path in (self.status_dir, self.state_dir, self.record_dir, self.home):
            os.makedirs(path)
        Path(self.state_dir, "state").write_text(
            f"URL={HOST}\nHTTP_PORT=8793\nHTTPS_PORT=18447\nSTATUS_DIR={self.status_dir}\n", encoding="utf-8"
        )
        self.policy = os.path.join(self.tmp, "policy.json")
        Path(self.policy).write_text(
            json.dumps(
                {
                    "version": 1,
                    "keywords": ["わかりやすく", "分かりやすく", "ビフォーアフター", "振り返り", "図で", "図解", "説明して"],
                    "stop_reason": REASON,
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        self.page = os.path.join(self.status_dir, "explain.html")
        Path(self.page).write_text("<html>説明</html>", encoding="utf-8")
        self.transcript = os.path.join(self.tmp, "transcript.jsonl")

    def cleanup(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    @property
    def page_url(self) -> str:
        return f"{HOST}/explain.html"

    def write_record(self, path: str | None = None, checked_at: str = AFTER, sha: str | None = None) -> None:
        path = path or self.page
        row = {
            "path": path,
            "sha256": sha if sha is not None else _sha(path),
            "checked_at": checked_at,
            "checker": "check-explain-html.py",
            "version": 1,
        }
        with open(os.path.join(self.record_dir, "records.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")

    def write_transcript(self, entries: list[dict], fmt: str) -> None:
        lines = list(entries)
        if fmt == "codex":
            lines.insert(0, {"type": "session_meta", "payload": {"id": "codex-test", "originator": "codex_cli_rs"}})
        with open(self.transcript, "w", encoding="utf-8") as fh:
            for entry in lines:
                fh.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def run(self, **extra) -> tuple[int, str]:
        payload = {"transcript_path": self.transcript}
        payload.update(extra)
        env = {
            "HOME": self.home,
            "EXPLAIN_VISUAL_POLICY_PATH": self.policy,
            "SERVE_STATUS_STATE_DIR": self.state_dir,
            "EXPLAIN_CHECK_RECORD_DIR": self.record_dir,
        }
        old_in, old_out = sys.stdin, sys.stdout
        sys.stdin = io.StringIO(json.dumps(payload))
        sys.stdout = io.StringIO()
        try:
            with mock.patch.dict(os.environ, env):
                code = HOOK.main()
            return code, sys.stdout.getvalue()
        finally:
            sys.stdin, sys.stdout = old_in, old_out

    def unchecked_lines(self) -> list[dict]:
        path = Path(self.record_dir, "unchecked.jsonl")
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


class StopExplainCheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.env = Env()
        self.addCleanup(self.env.cleanup)

    def conversation(self, fmt: str, reply: str, user: str = EXPLAIN_ASK, user_ts: str | None = USER_AT) -> list[dict]:
        return [
            _entry(fmt, "user", user, user_ts),
            _entry(fmt, "assistant", reply, "2026-11-02T10:04:00Z"),
        ]

    def assertPasses(self, result: tuple[int, str]) -> None:
        self.assertEqual(result[0], 0)
        self.assertEqual(result[1].strip(), "")

    def assertBlocks(self, result: tuple[int, str]) -> None:
        self.assertEqual(result[0], 0)
        data = json.loads(result[1])
        self.assertEqual(data["decision"], "block")
        self.assertEqual(data["reason"], REASON)

    # 1
    def test_checked_url_passes(self) -> None:
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                self.env.write_transcript(self.conversation(fmt, f"できました。\n{self.env.page_url}\n"), fmt)
                self.env.write_record()
                self.assertPasses(self.env.run())

    # 2
    def test_keyword_at_end_of_very_long_user_message(self) -> None:
        long_text = "あ" * 25_000 + "わかりやすく説明して"
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                self.env.write_transcript(self.conversation(fmt, "文字で説明します", user=long_text), fmt)
                self.assertBlocks(self.env.run())

    # 3
    def test_compaction_summary_keyword_is_not_a_user_message(self) -> None:
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                entries = [
                    _entry(fmt, "user", "こんにちは", USER_AT),
                    _entry(fmt, "assistant", "こんにちは", AFTER),
                    _compact(fmt, "要約: ビフォーアフターをわかりやすく説明して、と頼まれた"),
                ]
                self.env.write_transcript(entries, fmt)
                self.assertPasses(self.env.run())

    # 4
    def test_other_host_or_outside_folder_url_blocks(self) -> None:
        outside = os.path.join(self.env.tmp, "outside.html")
        Path(outside).write_text("x", encoding="utf-8")
        self.env.write_record()
        self.env.write_record(path=outside)
        bad_urls = [
            "https://evil.example.ts.net:18447/explain.html",
            "https://macstudio-test.example.ts.net:9999/explain.html",
            f"{HOST}/../outside.html",
            f"{HOST}/%2e%2e/outside.html",
            f"{HOST}/sub/../../outside.html",
        ]
        for fmt in FORMATS:
            for url in bad_urls:
                with self.subTest(fmt=fmt, url=url):
                    self.env.write_transcript(self.conversation(fmt, f"どうぞ {url}"), fmt)
                    self.assertBlocks(self.env.run())

    # 5
    def test_no_check_blocks(self) -> None:
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                self.env.write_transcript(self.conversation(fmt, f"できました {self.env.page_url}"), fmt)
                self.assertBlocks(self.env.run())

    # 6
    def test_check_from_before_the_request_blocks(self) -> None:
        self.env.write_record(checked_at=BEFORE)
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                self.env.write_transcript(self.conversation(fmt, f"できました {self.env.page_url}"), fmt)
                self.assertBlocks(self.env.run())

    # 7
    def test_edited_after_check_blocks(self) -> None:
        self.env.write_record()
        Path(self.env.page).write_text("<html>書き換え後</html>", encoding="utf-8")
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                self.env.write_transcript(self.conversation(fmt, f"できました {self.env.page_url}"), fmt)
                self.assertBlocks(self.env.run())

    # 8
    def test_same_name_in_other_folder_blocks(self) -> None:
        other_dir = os.path.join(self.env.tmp, "elsewhere")
        os.makedirs(other_dir)
        other = os.path.join(other_dir, "explain.html")
        Path(other).write_text("<html>説明</html>", encoding="utf-8")
        self.env.write_record(path=other)
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                self.env.write_transcript(self.conversation(fmt, f"できました {self.env.page_url}"), fmt)
                self.assertBlocks(self.env.run())

    # 9
    def test_no_url_blocks(self) -> None:
        self.env.write_record()
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                self.env.write_transcript(self.conversation(fmt, "用意できませんでした"), fmt)
                self.assertBlocks(self.env.run())

    # 10
    def test_non_explain_request_passes(self) -> None:
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                self.env.write_transcript(self.conversation(fmt, "実行しました", user="テストを実行して"), fmt)
                self.assertPasses(self.env.run())

    # 11
    def test_stop_hook_active_without_check_passes_and_logs(self) -> None:
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                before = len(self.env.unchecked_lines())
                self.env.write_transcript(self.conversation(fmt, f"文字で説明 {self.env.page_url}"), fmt)
                self.assertPasses(self.env.run(stop_hook_active=True))
                rows = self.env.unchecked_lines()
                self.assertEqual(len(rows), before + 1)
                row = rows[-1]
                self.assertEqual(row["transcript_path"], self.env.transcript)
                self.assertTrue(row["user_head"].startswith("ビフォーアフター"))
                self.assertEqual(row["urls"], [self.env.page_url])
                self.assertIn("at", row)

    # 12
    def test_stop_hook_active_with_check_passes_without_log(self) -> None:
        self.env.write_record()
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                self.env.write_transcript(self.conversation(fmt, f"できました {self.env.page_url}"), fmt)
                self.assertPasses(self.env.run(stop_hook_active=True))
                self.assertEqual(self.env.unchecked_lines(), [])

    # 13
    def test_missing_user_timestamp_blocks(self) -> None:
        self.env.write_record()
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                self.env.write_transcript(
                    self.conversation(fmt, f"できました {self.env.page_url}", user_ts=None), fmt
                )
                self.assertBlocks(self.env.run())

    # 14
    def test_real_message_after_compaction_line(self) -> None:
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                prefix = [_compact(fmt, "要約: 図解の依頼があった"), {"type": "summary", "summary": "図で見せて"}]
                reply = f"できました {self.env.page_url}"
                self.env.write_transcript(prefix + self.conversation(fmt, reply), fmt)
                self.env.write_record()
                self.assertPasses(self.env.run())
                shutil.rmtree(self.env.record_dir)
                os.makedirs(self.env.record_dir)
                self.assertBlocks(self.env.run())

    # 15
    def test_very_long_transcript_is_fast_and_correct(self) -> None:
        for fmt in FORMATS:
            with self.subTest(fmt=fmt):
                filler: list[dict] = []
                for i in range(15_000):
                    filler.append(_entry(fmt, "user", f"質問{i}", "2026-11-02T08:00:00Z"))
                    filler.append(_entry(fmt, "assistant", f"回答{i} https://example.com/{i}", "2026-11-02T08:00:01Z"))
                entries = filler + self.conversation(fmt, f"できました {self.env.page_url}")
                self.env.write_transcript(entries, fmt)
                self.assertGreaterEqual(len(Path(self.env.transcript).read_text(encoding="utf-8").splitlines()), 30_000)
                shutil.rmtree(self.env.record_dir)
                os.makedirs(self.env.record_dir)
                started = time.monotonic()
                self.assertBlocks(self.env.run())
                self.assertLess(time.monotonic() - started, 5.0)
                self.env.write_record()
                started = time.monotonic()
                self.assertPasses(self.env.run())
                self.assertLess(time.monotonic() - started, 5.0)

    # 補足: fail-open
    def test_fail_open_cases(self) -> None:
        self.env.write_transcript(self.conversation("claude", "文字だけ"), "claude")
        with mock.patch.dict(os.environ, {"EXPLAIN_VISUAL_POLICY_PATH": os.path.join(self.env.tmp, "none.json")}):
            Path(self.env.policy).rename(Path(self.env.tmp, "moved.json"))
            self.assertPasses(self.env.run())
        Path(self.env.tmp, "moved.json").rename(Path(self.env.policy))
        Path(self.env.policy).write_text("{壊れた", encoding="utf-8")
        self.assertPasses(self.env.run())
        Path(self.env.policy).write_text(
            json.dumps({"keywords": ["図解"], "stop_reason": REASON}), encoding="utf-8"
        )
        os.remove(self.env.transcript)
        self.assertPasses(self.env.run())
        self.assertPasses(self.env.run(transcript_path=None))

    # 補足: 差し込み文・ツール結果は本人の発言ではない
    def test_system_reminder_and_tool_result_are_not_user_text(self) -> None:
        entries = [
            _entry("claude", "user", "直して", USER_AT),
            {
                "type": "user",
                "timestamp": AFTER,
                "message": {
                    "role": "user",
                    "content": [{"type": "tool_result", "content": "わかりやすく説明して"}],
                },
            },
            _entry("claude", "user", "<system-reminder>図解はわかりやすく</system-reminder>OK", AFTER),
        ]
        self.env.write_transcript(entries, "claude")
        self.assertPasses(self.env.run())


if __name__ == "__main__":
    unittest.main(verbosity=1)
