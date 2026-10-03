#!/usr/bin/env python3
"""Regression tests for stop-goal-check.py (#1709)."""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

HOOK_PATH = Path(__file__).resolve().parent / "stop-goal-check.py"
SPEC = importlib.util.spec_from_file_location("stop_goal_check", HOOK_PATH)
assert SPEC and SPEC.loader
HOOK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOOK)


def _run_main(payload: dict, monkey_stdin: str | None = None) -> tuple[int, str]:
    raw = json.dumps(payload)
    old_stdin, old_stdout = sys.stdin, sys.stdout
    sys.stdin = io.StringIO(monkey_stdin if monkey_stdin is not None else raw)
    sys.stdout = io.StringIO()
    try:
        code = HOOK.main()
        return code, sys.stdout.getvalue()
    finally:
        sys.stdin = old_stdin
        sys.stdout = old_stdout


def _write_jsonl(path: Path, entries: list[dict]) -> None:
    path.write_text(
        "".join(json.dumps(entry, ensure_ascii=False) + "\n" for entry in entries),
        encoding="utf-8",
    )


class EvidenceDetectionTests(unittest.TestCase):
    def test_compact_summary_counts_as_plan_ledger_evidence(self) -> None:
        entries = [
            {
                "type": "system",
                "message": {
                    "content": (
                        "This session is being continued from a previous conversation. "
                        "Compaction summary: /goal で台帳 47 行をタスク化した。"
                        "実装 PR 5 本は ai-worker 経由でマージ済み。"
                    )
                },
            }
        ]
        self.assertFalse(HOOK.should_block(entries))
        self.assertTrue(HOOK.has_plan_ledger_evidence(HOOK.combined_transcript_text(entries)))

    def test_tasklist_holds_are_complete_per_section_6(self) -> None:
        entries = [
            {"type": "user", "message": {"content": "/goal 全部✓"}},
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {"type": "tool_use", "name": "TaskList", "input": {}},
                    ]
                },
            },
            {
                "type": "user",
                "message": {
                    "content": [
                        {
                            "type": "tool_result",
                            "content": json.dumps(
                                {
                                    "tasks": [
                                        {
                                            "content": "台帳行を実装する",
                                            "status": "completed",
                                        },
                                        {
                                            "content": "本番投入 owner ゲート 10/6以降",
                                            "status": "pending",
                                        },
                                        {
                                            "content": "本人承認待ち",
                                            "status": "pending",
                                        },
                                        {
                                            "content": "次期プラン",
                                            "status": "pending",
                                        },
                                    ]
                                },
                                ensure_ascii=False,
                            ),
                        }
                    ]
                },
            },
        ]
        self.assertFalse(HOOK.should_block(entries))

    def test_actionable_pending_still_blocks(self) -> None:
        entries = [
            {"type": "user", "message": {"content": "/goal 全部✓"}},
            {
                "type": "assistant",
                "message": {
                    "content": [
                        {"type": "tool_use", "name": "TaskList", "input": {}},
                    ]
                },
            },
            {
                "type": "user",
                "message": {
                    "content": [
                        {
                            "type": "tool_result",
                            "content": json.dumps(
                                {
                                    "tasks": [
                                        {
                                            "content": "まだ誰も着手していない実装",
                                            "status": "pending",
                                        }
                                    ]
                                },
                                ensure_ascii=False,
                            ),
                        }
                    ]
                },
            },
        ]
        self.assertTrue(HOOK.should_block(entries))

    def test_goal_without_plan_or_tasks_blocks(self) -> None:
        entries = [{"type": "user", "message": {"content": "/goal 全部✓ で進めて"}}]
        self.assertTrue(HOOK.should_block(entries))

    def test_no_goal_is_silent(self) -> None:
        entries = [{"type": "user", "message": {"content": "今日の天気は？"}}]
        self.assertFalse(HOOK.should_block(entries))


class HookCliTests(unittest.TestCase):
    def test_stop_hook_active_is_silent(self) -> None:
        code, out = _run_main({"stop_hook_active": True, "transcript_path": "/nope"})
        self.assertEqual(code, 0)
        self.assertEqual(out, "")

    def test_loop_count_is_silent(self) -> None:
        code, out = _run_main({"loop_count": 2, "transcript_path": "/nope"})
        self.assertEqual(code, 0)
        self.assertEqual(out, "")

    def test_compacted_transcript_does_not_fire(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "t.jsonl"
            _write_jsonl(
                path,
                [
                    {
                        "type": "system",
                        "compactMetadata": {"trigger": "manual"},
                        "message": {
                            "content": (
                                "compaction summary: コミットメント台帳 47行を"
                                " TaskCreate でタスク化済み。3行は明示保留。"
                            )
                        },
                    },
                    {"type": "user", "message": {"content": "続けて"}},
                ],
            )
            code, out = _run_main(
                {"transcript_path": str(path), "stop_hook_active": False}
            )
            self.assertEqual(code, 0)
            self.assertEqual(out, "")

    def test_missing_plan_fires_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "t.jsonl"
            _write_jsonl(
                path,
                [{"type": "user", "message": {"content": "/goal プランを完走"}}],
            )
            code, out = _run_main(
                {"transcript_path": str(path), "stop_hook_active": False}
            )
            self.assertEqual(code, 0)
            payload = json.loads(out)
            self.assertEqual(payload["decision"], "block")
            self.assertIn("プラン文書", payload["reason"])


if __name__ == "__main__":
    unittest.main()
