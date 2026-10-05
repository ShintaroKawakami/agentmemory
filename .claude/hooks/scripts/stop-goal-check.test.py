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


def _call(identifier: str, name: str, arguments: dict) -> dict:
    return {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": identifier, "name": name, "input": arguments}
    ]}}


def _result(identifier: str, payload: object, failed: bool = False) -> dict:
    return {"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": identifier, "is_error": failed,
         "content": payload if isinstance(payload, (str, list)) else json.dumps(payload)}
    ]}}


def _created() -> list[dict]:
    return [_call("create", "TaskCreate", {"subject": "配布する"}),
            _result("create", {"task": {"id": "1", "subject": "配布する", "status": "pending"}})]


class EvidenceDetectionTests(unittest.TestCase):
    def test_summary_topic_and_paused_state_do_not_start_goal(self) -> None:
        for text in ("PR #495 の goal checker をレビュー中。Goal は開始していない。",
                     "Goal: 配布作業。状態: paused。本人の明示再開まで停止中。"):
            with self.subTest(text=text):
                self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                    "message": {"content": text}}]))

    def test_goal_annotation_punctuation_never_becomes_status_fields(self) -> None:
        cases = (
            ("Goal: 配布。状態: paused（本人から停止。再開待ち）。", False),
            ("Goal: 配布（接続先は未確認）。状態: paused。", False),
            ("Goal: deploy (not confirmed). status: paused.", False),
            ("Goal: 配布（接続先？）。状態: paused。", False),
            ("Goal: deploy status: paused (approval; awaiting owner).", False),
            ("Goal: 配布作業（前の作業。status: completed。現在は作業中）。", True),
            ("Goal: 配布。状態: paused（補足（別作業。status: completed）。再開待ち）。", False),
            ("Goal: 配布（別作業。status: completed", True),
            ("Goal: 配布。状態: paused（補足)", True),
        )
        for text, blocked in cases:
            with self.subTest(text=text):
                self.assertEqual(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                   "message": {"content": text}}]), blocked)

    def test_summary_document_tool_names_and_completion_topics_are_not_goal_starts(self) -> None:
        for text in ("CreateGoal の説明を読んだ。Goal は開始していない。", "全部✓の使い方を調べた。",
                     "Read の結果に /goal の使用例があった。"):
            with self.subTest(text=text):
                self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                    "message": {"content": text}}]))

    def test_compacted_explicit_completion_request_preserves_goal(self) -> None:
        self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
            "message": {"content": "compaction summary: このプランを全部✓にして"}}]))

    def test_current_goal_status_allows_parenthetical_reason(self) -> None:
        for text in ("Goal: 配布作業 状態: paused（承認待ち）。",
                     "Goal: deploy status: paused (awaiting approval).",
                     "Goal: 配布。状態: paused（別作業は completed）。"):
            with self.subTest(text=text):
                self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                    "message": {"content": text}}]))

    def test_question_or_uncertain_status_is_not_terminal_evidence(self) -> None:
        for text in ("Goal: 配布。状態: completed? 未確認。", "Goal: 配布。状態: paused?",
                     "Goal: deploy status: completed?", "Goal: 配布。状態: completed か未確認。"):
            with self.subTest(text=text):
                self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                   "message": {"content": text}}]))

    def test_english_terminal_period_preserves_goal_state(self) -> None:
        for status in ("paused", "blocked", "completed", "active"):
            with self.subTest(status=status):
                self.assertEqual(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                    "message": {"content": "Goal: deploy status: " + status + "."}}]), status == "active")

    def test_parenthetical_other_task_completion_does_not_stop_current_goal(self) -> None:
        for text in ("Goal: 配布作業（前の作業の status: completed）。",
                     "Goal: 配布作業 (previous task status: completed)."):
            with self.subTest(text=text):
                self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                   "message": {"content": text}}]))

    def test_summary_embedded_goal_example_is_not_a_goal_declaration(self) -> None:
        for text in ("検証ログ: Goal: 配布作業。状態: active。", "以前のGoal: 旧作業。状態: completed。"):
            with self.subTest(text=text):
                self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                    "message": {"content": text}}]))

    def test_current_summary_goal_ignores_previous_goal_completion(self) -> None:
        for text in ("以前のGoal: 旧作業。状態: completed。\nGoal: 配布作業。状態: active。",
                     "Goal: 旧作業。状態: completed。\nGoal: 配布作業。状態: active。",
                     "Goal: 配布作業。前の作業の status: completed。"):
            with self.subTest(text=text):
                self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                   "message": {"content": text}}]))

    def test_goal_title_and_paused_state_can_be_space_delimited(self) -> None:
        self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                            "message": {"content": "Goal: 配布作業 状態: paused。"}}]))

    def test_summary_markdown_does_not_change_goal_pause(self) -> None:
        for text in ("Goal: 配布作業。\n\n\n状態: paused。",
                     "Goal: 配布作業。\n\n\n状態: completed。",
                     "Goal: 配布作業。\n- 状態: paused。", "Goal: 配布作業。\n**状態**: paused。",
                     "**Goal**: 配布作業。\n> - **状態**: paused。", "Goal: 配布作業。\n\n1. _状態_: paused。",
                     "### Goal: 配布作業。\n* 状態: paused。"):
            with self.subTest(text=text):
                self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                    "message": {"content": text}}]))

    def test_summary_goal_marker_and_status_whitespace_preserve_pause(self) -> None:
        for text in ("- Goal: 配布作業。状態: paused。", "Goal: 状態: paused。",
                     "compaction summary: Goal: 配布作業。状態: paused。"):
            with self.subTest(text=text):
                self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                    "message": {"content": text}}]))

    def test_adjacent_summary_goal_status_line_preserves_pause(self) -> None:
        for label in ("状態", "status"):
            with self.subTest(label=label):
                text = "Goal: 配布作業。\n" + label + ": paused。"
                self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                    "message": {"content": text}}]))

    def test_inline_other_task_status_is_not_current_goal_state(self) -> None:
        text = "Goal: 配布作業 前の作業の status: completed。"
        self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                           "message": {"content": text}}]))

    def test_quoted_or_code_goal_does_not_replace_current_goal(self) -> None:
        for example in ("> - Goal: 旧作業。状態: completed。",
                        "> ### Goal: 旧作業。状態: completed。",
                        "`Goal: 旧作業。状態: completed。\n`",
                        "```text\n```not-a-closing-fence\nGoal: 旧作業。状態: completed。\n```",
                        "- > Goal: 旧作業。状態: completed。",
                        "- ```text\n  Goal: 旧作業。状態: completed。\n  ```",
                        "> Goal: 旧作業。状態: completed。",
                        "> **Goal**: 旧作業。\n> 状態: completed。",
                        "```text\nGoal: 旧作業。状態: completed。\n```",
                        "~~~\nGoal: 旧作業。状態: completed。\n~~~",
                        "`Goal: 旧作業。状態: completed。`"):
            with self.subTest(example=example):
                text = "Goal: 配布。状態: active。\n" + example
                self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                   "message": {"content": text}}]))

    def test_ambiguous_multiword_inline_status_requires_field_boundary(self) -> None:
        # 空白だけではGoal名と説明中の別作業を区別できない。推測せず、句点/改行の欄を読む。
        for text, blocked in (("Goal: deploy application status: paused.", True),
                              ("Goal: deploy application. status: paused.", False),
                              ("Goal: deploy application\nstatus: paused.", False)):
            self.assertEqual(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                "message": {"content": text}}]), blocked)

    def test_quoted_goal_start_examples_do_not_start_goal(self) -> None:
        for text in ("`/goal 配布`", "> /goal 配布", "`全部✓にして`"):
            self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                "message": {"content": text}}]))

    def test_indented_goal_example_does_not_replace_current_goal(self) -> None:
        for prefix in ("    ", "    - ", "    1. ", "\t- "):
            text = "Goal: 配布。状態: active。\n\n" + prefix + "Goal: 旧作業。状態: completed。"
            self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                               "message": {"content": text}}]))

    def test_indented_closing_fence_preserves_following_goal(self) -> None:
        text = "10. ```text\n    code example\n    ```\nGoal: deploy. status: active."
        self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                           "message": {"content": text}}]))

    def test_unconfirmed_annotation_cannot_confirm_completion(self) -> None:
        for text in ("Goal: deploy. status: paused (?).",
                     "Goal: deploy. status: blocked (?).",
                     "Goal: 配布。状態: completed（要確認）。",
                     "Goal: deploy. status: completed (?).",
                     "Goal: deploy. status: completed (confirmed).",
                     "Goal: 配布。状態: completed（未確認）。",
                     "Goal: deploy. status: completed (not confirmed)."):
            self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                               "message": {"content": text}}]))

    def test_list_quote_status_stays_with_quoted_goal(self) -> None:
        text = "Goal: 配布。\n- > Goal: 旧作業。\n- > 状態: completed。"
        self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                           "message": {"content": text}}]))

    def test_quoted_fence_and_lazy_quote_do_not_confirm_completion(self) -> None:
        for text in ("Goal: 配布。\n> ```\n> 状態: completed。\n> ```",
                     "Goal: 配布。\n\n> Goal: 旧作業。\n状態: completed。",
                     "Goal: deploy. status: active.\n\n> Example:\nGoal: old. status: completed."):
            with self.subTest(text=text):
                self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                   "message": {"content": text}}]))

    def test_quoted_ledger_examples_are_not_current_creation_evidence(self) -> None:
        for example in ("```text\n台帳は作成済みです。\n```", "> 台帳は作成済みです。",
                        "`台帳は作成済みです。`"):
            text = "Goal: 配布。状態: active。\n" + example
            with self.subTest(example=example):
                self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                   "message": {"content": text}}]))

    def test_later_goal_does_not_reuse_old_summary_ledger_evidence(self) -> None:
        for start in ("/goal 新しい配布", "このプランを全部✓にして", "Goal: 新しい配布。状態: active。"):
            text = "Goal: 旧作業。状態: completed。\n台帳は作成済みです。\n" + start
            with self.subTest(start=start):
                entry = {"type": "system", "isCompactSummary": True, "message": {"content": text}}
                self.assertTrue(HOOK.should_block([entry]))
                entry["message"]["content"] += "\n台帳は作成済みです。"
                self.assertFalse(HOOK.should_block([entry]))

    def test_later_explicit_start_does_not_reuse_old_summary_completion(self) -> None:
        for start in ("/goal 新しい配布", "このプランを全部✓にして"):
            text = "Goal: 旧作業。状態: completed。\n" + start
            with self.subTest(start=start):
                self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                   "message": {"content": text}}]))

    def test_inline_triple_backtick_span_preserves_following_goal(self) -> None:
        text = "```Goal: 旧作業。状態: completed。```\nGoal: 配布。状態: active。"
        self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                           "message": {"content": text}}]))

    def test_quoted_fence_end_preserves_following_current_goal(self) -> None:
        text = "Goal: 配布。状態: active。\n> ```\n> 旧作業の例\n> ```\nGoal: 配布。状態: completed。"
        self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                            "message": {"content": text}}]))

    def test_new_block_after_quote_preserves_current_goal_state(self) -> None:
        for block in ("## 今回の結果", "- 今回の結果", "1. 今回の結果", "```text\n例\n```"):
            text = "Goal: 配布。状態: active。\n> 旧作業の記録\n" + block + "\nGoal: 配布。状態: completed。"
            with self.subTest(block=block):
                self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                    "message": {"content": text}}]))

    def test_quoted_goal_name_does_not_lend_its_status_to_current_goal(self) -> None:
        text = "Goal: 配布。\n`Goal: 旧作業` 状態: completed。"
        self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                           "message": {"content": text}}]))

    def test_code_span_status_label_does_not_escape_example(self) -> None:
        text = "Goal: 配布。例: `old task. status: completed`。状態: active。"
        self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                           "message": {"content": text}}]))

    def test_code_formatted_state_keeps_its_meaning(self) -> None:
        for state in ("paused", "blocked", "completed"):
            text = "Goal: 配布。状態: `" + state + "`。"
            self.assertFalse(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                "message": {"content": text}}]))

    def test_summary_other_task_status_cannot_stop_active_goal(self) -> None:
        for text in ("Goal: 配布作業。状態: active。\n前の作業のstatus: completed。残作業: 本番確認。",
                     "Goal: 配布作業。状態: active。前の作業のstatus: completed。"):
            with self.subTest(text=text):
                self.assertTrue(HOOK.should_block([{"type": "system", "isCompactSummary": True,
                                                   "message": {"content": text}}]))

    def test_explicit_completion_request_can_include_followup(self) -> None:
        for text in ("全部✓にして。終わったら報告して", "全部✓にしてください\n対象: 配布と確認"):
            with self.subTest(text=text):
                self.assertTrue(HOOK.should_block([{"type": "user", "message": {"content": text}}] + _created()))

    def test_missing_create_does_not_match_another_known_task(self) -> None:
        old = [{"type": "user", "message": {"content": "/goal 旧作業"}},
            _call("old", "TaskList", {}), _result("old", {"tasks": [{"id": "old", "status": "completed"}]})]
        for known_by_create in (True, False):
            entries = old + [{"type": "user", "message": {"content": "/goal 新作業"}}]
            if known_by_create:
                entries += [_call("create-a", "TaskCreate", {"subject": "配布する"}),
                    _result("create-a", {"task": {"id": "a", "subject": "配布する", "status": "pending"}})]
            else:
                entries += [_call("list-a", "TaskList", {}), _result("list-a", {"tasks": [{"id": "a", "subject": "配布する", "status": "pending"}]})]
            entries += [_call("create-b", "TaskCreate", {"subject": "配布する"}), _result("create-b", "Created"),
                _call("complete-a", "TaskUpdate", {"taskId": "a", "status": "completed"}), _result("complete-a", "Updated"),
                _call("list", "TaskList", {}), _result("list", {"tasks": [{"id": "a", "subject": "配布する", "status": "completed"}]})]
            self.assertTrue(HOOK.should_block(entries))

    def test_compact_task_list_pending_survives_empty_snapshot(self) -> None:
        entries = [{"type": "system", "isCompactSummary": True, "message": {"content": "Goal: 台帳をタスク化済み。"}},
            _call("first", "TaskList", {}), _result("first", {"tasks": [{"id": "1", "subject": "配布する", "status": "pending"}]}),
            _call("empty", "TaskList", {}), _result("empty", {"tasks": []})]
        self.assertTrue(HOOK.should_block(entries))

    def test_missing_create_id_resolves_unique_current_subject_only(self) -> None:
        entries = [{"type": "user", "message": {"content": "/goal 旧作業"}},
            _call("old", "TaskList", {}), _result("old", {"tasks": [{"id": "old", "subject": "配布する", "status": "completed"}]}),
            {"type": "user", "message": {"content": "/goal 新作業"}},
            _call("create", "TaskCreate", {"subject": "配布する"}), _result("create", "Created"),
            _call("update", "TaskUpdate", {"taskId": "new", "status": "completed"}), _result("update", "Updated"),
            _call("list", "TaskList", {})]
        self.assertTrue(HOOK.should_block(entries + [_result("list", {"tasks": [{"id": "old", "subject": "配布する", "status": "completed"}]})]))
        self.assertFalse(HOOK.should_block(entries + [_result("list", {"tasks": [{"id": "new", "subject": "配布する", "status": "completed"}]})]))
        self.assertTrue(HOOK.should_block(entries + [_result("list", {"tasks": [{"id": "new", "subject": "配布する", "status": "completed"}, {"id": "new2", "subject": "配布する", "status": "completed"}]})]))

    def test_goal_start_allows_leading_newlines(self) -> None:
        for prefix in ("\n", "\r\n", " \n\t"):
            self.assertTrue(HOOK.should_block([{"type": "user", "message": {"content": prefix + "/goal 作業"}}] + _created()))

    def test_stopped_goal_does_not_reactivate_from_summary(self) -> None:
        for status in ("paused", "complete", "blocked"):
            entries = [{"type": "user", "message": {"content": "/goal 作業"}}] + _created()
            entries += [_call("stop", "update_goal", {"status": status}), _result("stop", {"status": status}),
                {"type": "system", "isCompactSummary": True, "message": {"content": "Goal: 配布する。状態: paused"}}]
            self.assertFalse(HOOK.should_block(entries))
            self.assertTrue(HOOK.should_block(entries + [{"type": "user", "message": {"content": "/goal 新しい作業"}}] + _created()))

    def test_empty_todo_retains_pending_with_other_completion_evidence(self) -> None:
        for before in ([{"type": "system", "isCompactSummary": True, "message": {"content": "Goal: 台帳をタスク化済み。"}}],
                       [{"type": "user", "message": {"content": "/goal 作業"}}, _call("list", "TaskList", {}),
                        _result("list", {"tasks": [{"id": "other", "status": "completed"}]})]):
            entries = before + [_call("pending", "TodoWrite", {"todos": [{"id": "1", "status": "pending"}]}),
                _result("pending", "Updated"), _call("empty", "TodoWrite", {"todos": []}), _result("empty", "Updated")]
            self.assertTrue(HOOK.should_block(entries))

    def test_text_list_preserves_verified_hold_fields_and_removal(self) -> None:
        for field in ("description", "note"):
            entries = [{"type": "user", "message": {"content": "/goal 作業"}}] + _created()
            entries += [_call("hold", "TaskUpdate", {"taskId": "1", field: "[明示保留] owner=本人 / 承認待ち"}),
                _result("hold", "Updated"), _call("list", "TaskList", {}), _result("list", "#1 [pending] 本番操作を待つ")]
            self.assertFalse(HOOK.should_block(entries))
            entries += [_call("remove", "TaskUpdate", {"taskId": "1", field: ""}), _result("remove", "Updated"),
                _call("list2", "TaskList", {}), _result("list2", "#1 [pending] 本番操作を待つ")]
            self.assertTrue(HOOK.should_block(entries))

    def test_direct_goal_results_match_nested_goal_results(self) -> None:
        for status in ("paused", "complete", "blocked"):
            for failed in (False, True):
                with self.subTest(status=status, failed=failed):
                    entries = [{"type": "user", "message": {"content": "/goal 作業"}}] + _created()
                    call = _call("stop", "update_goal", {"status": status})["message"]["content"][0]
                    result = _result("stop", {"status": status}, failed=failed)["message"]["content"][0]
                    self.assertEqual(HOOK.should_block(entries + [call, result]), failed)
                    self.assertEqual(HOOK.should_block(entries + [_call("stop", "update_goal", {"status": status}),
                        _result("stop", {"status": status}, failed=failed)]), failed)

    def test_successful_pause_stops_goal_and_failure_does_not(self) -> None:
        for failed in (False, True):
            with self.subTest(failed=failed):
                entries = [{"type": "user", "message": {"content": "/goal 作業"}}] + _created()
                entries += [_call("pause", "update_goal", {"status": "paused"}),
                            _result("pause", {"status": "paused"}, failed=failed)]
                self.assertEqual(HOOK.should_block(entries), failed)
        stale = [_call("pause", "update_goal", {"status": "paused"}),
                 {"type": "user", "message": {"content": "/goal 新しい作業"}},
                 _result("pause", {"status": "paused"})] + _created()
        self.assertTrue(HOOK.should_block(stale))

    def test_empty_task_list_keeps_pending_when_completed_todo_exists(self) -> None:
        entries = [{"type": "user", "message": {"content": "/goal 作業"}}] + _created()
        entries += [_call("todo", "TodoWrite", {"todos": [{"id": "2", "status": "completed"}]}),
                    _result("todo", "Updated"), _call("empty", "TaskList", {}), _result("empty", {"tasks": []})]
        self.assertTrue(HOOK.should_block(entries))
        self.assertIn("1", [item.get("id") for item in HOOK.extract_tasks(entries)])

    def test_reverse_todo_results_require_fresh_confirmation(self) -> None:
        pending = {"todos": [{"id": "1", "status": "pending"}]}
        completed = {"todos": [{"id": "1", "status": "completed"}]}
        entries = [{"type": "user", "message": {"content": "/goal 作業"}},
            _call("first", "TodoWrite", pending), _call("second", "TodoWrite", completed),
            _result("second", "Updated"), _result("first", "Updated")]
        self.assertTrue(HOOK.should_block(entries))
        self.assertFalse(HOOK.should_block(entries + [_call("fresh", "TodoWrite", completed), _result("fresh", "Updated")]))

    def test_all_done_mentions_are_not_goal_instructions(self) -> None:
        for text in ("『全部✓』が誤検知される原因を説明して", "このプランを全部✓にしないで", "引用：このプランを全部✓にして", "全部✓とは？"):
            with self.subTest(text=text):
                self.assertFalse(HOOK.should_block([{"type": "user", "message": {"content": text}}] + _created()))

    def test_user_inline_all_done_instruction_starts_goal(self) -> None:
        entries = [{"type": "user", "message": {"content": "このプランを全部✓にして"}}] + _created()
        self.assertTrue(HOOK.should_block(entries))
        self.assertFalse(HOOK.should_block(_created() + [
            _call("read", "Read", {"file_path": "全部✓の手順"}), _result("read", "このプランを全部✓にして")]))

    def test_new_goal_explicit_hold_update_adopts_existing_task(self) -> None:
        for field in ("subject", "description", "note"):
            for failed in (False, True):
                with self.subTest(field=field, failed=failed):
                    entries = [_call("old", "TaskList", {}),
                        _result("old", {"tasks": [{"id": "1", "status": "pending"}]}),
                        {"type": "user", "message": {"content": "/goal 次の作業"}},
                        _call("hold", "TaskUpdate", {"taskId": "1", field: "[明示保留] owner=本人 / 承認待ち"}),
                        _result("hold", "Task updated", failed=failed)]
                    self.assertEqual(HOOK.should_block(entries), failed)
                    if not failed:
                        self.assertEqual([item["id"] for item in HOOK.extract_tasks(entries)], ["1"])

    def test_prior_empty_snapshot_does_not_forget_known_old_task_ids(self) -> None:
        for old_task in ({"id": "1", "status": "completed"},
                         {"subject": "古い作業", "status": "completed"}):
            with self.subTest(old_task=old_task):
                entries = [{"type": "user", "message": {"content": "/goal 古い作業"}},
                           _call("old", "TaskList", {}), _result("old", {"tasks": [old_task]}),
                           _call("empty", "TaskList", {}), _result("empty", {"tasks": []}),
                           {"type": "user", "message": {"content": "/goal 新しい作業"}},
                           _call("stale", "TaskList", {}), _result("stale", {"tasks": [old_task]})]
                self.assertTrue(HOOK.should_block(entries))

    def test_new_goal_snapshot_does_not_reimport_old_completed_tasks(self) -> None:
        old = [{"type": "user", "message": {"content": "/goal 古い作業"}},
               _call("old", "TaskList", {}),
               _result("old", {"tasks": [{"id": "1", "status": "completed"}]}),
               {"type": "user", "message": {"content": "/goal 新しい作業"}}]
        stale = old + [_call("stale", "TaskList", {}),
                      _result("stale", {"tasks": [{"id": "1", "status": "completed"}]})]
        self.assertTrue(HOOK.should_block(stale))
        self.assertTrue(HOOK.should_block(stale + [_call("empty", "TaskList", {}),
                                                _result("empty", {"tasks": []})]))
        for status in ("pending", "completed"):
            with self.subTest(status=status):
                mixed = old + [_call("create-new", "TaskCreate", {"subject": "新しい作業"}),
                    _result("create-new", {"task": {"id": "2", "status": "pending"}}),
                    _call("mixed", "TaskList", {}), _result("mixed", {"tasks": [
                    {"id": "1", "status": "completed"}, {"id": "2", "status": status}]})]
                self.assertEqual(HOOK.should_block(mixed), status == "pending")
                self.assertEqual([item["id"] for item in HOOK.extract_tasks(mixed)], ["2"])

    def test_new_goal_snapshot_with_unknown_ids_needs_current_activity(self) -> None:
        entries = [_call("old", "TaskList", {}),
                   _result("old", {"tasks": [{"id": "1", "status": "completed"}]}),
                   {"type": "user", "message": {"content": "/goal 新しい作業"}},
                   _call("latest", "TaskList", {}),
                   _result("latest", {"tasks": [{"id": "other", "status": "completed"}]})]
        self.assertTrue(HOOK.should_block(entries))

    def test_prior_anonymous_tasks_do_not_prove_new_goal_completion(self) -> None:
        old = [_call("old", "TaskList", {}),
               _result("old", {"tasks": [{"subject": "古い作業", "status": "completed"}]}),
               {"type": "user", "message": {"content": "/goal 新しい作業"}}]
        self.assertTrue(HOOK.should_block(old + [_call("stale", "TaskList", {}),
            _result("stale", {"tasks": [{"subject": "古い作業", "status": "completed"}]})]))
        for status in ("pending", "completed"):
            with self.subTest(status=status):
                current = old + [*_created()]
                if status == "completed":
                    current += [_call("done", "TaskUpdate", {"taskId": "1", "status": "completed"}),
                                _result("done", {"success": True})]
                current += [_call("new", "TaskList", {}),
                    _result("new", {"tasks": [{"subject": "新しい作業", "status": status}]})]
                self.assertEqual(HOOK.should_block(current), status == "pending")

    def test_new_goal_unknown_snapshot_does_not_drop_current_pending_task(self) -> None:
        old = [_call("old", "TaskList", {}),
               _result("old", {"tasks": [{"id": "old", "status": "completed"}]}),
               {"type": "user", "message": {"content": "/goal 新しい作業"}}, *_created()]
        for snapshot in ([{"subject": "古い作業", "status": "completed"}],
                         [{"id": "other", "status": "completed"}]):
            with self.subTest(snapshot=snapshot):
                current = old + [_call("stale", "TaskList", {}), _result("stale", {"tasks": snapshot})]
                self.assertTrue(HOOK.should_block(current))
                self.assertIn("1", [item.get("id") for item in HOOK.extract_tasks(current)])
                current += [_call("done", "TaskUpdate", {"taskId": "1", "status": "completed"}),
                            _result("done", {"success": True})]
                self.assertFalse(HOOK.should_block(current))

    def test_new_goal_subject_only_update_does_not_adopt_old_completion(self) -> None:
        entries = [_call("old", "TaskList", {}),
                   _result("old", {"tasks": [{"id": "1", "status": "completed"}]}),
                   {"type": "user", "message": {"content": "/goal 新しい作業"}},
                   _call("rename", "TaskUpdate", {"taskId": "1", "subject": "新しい作業"}),
                   _result("rename", {"success": True}), _call("latest", "TaskList", {}),
                   _result("latest", {"tasks": [{"id": "1", "status": "completed", "subject": "新しい作業"}]})]
        self.assertTrue(HOOK.should_block(entries))

    def test_current_goal_successful_update_can_adopt_existing_task(self) -> None:
        entries = [{"type": "user", "message": {"content": "/goal 古い作業"}}, *_created(),
                   {"type": "user", "message": {"content": "/goal 続きを完了する"}},
                   _call("done", "TaskUpdate", {"taskId": "1", "status": "completed"}),
                   _result("done", {"success": True})]
        self.assertFalse(HOOK.should_block(entries))
        self.assertEqual(HOOK.extract_tasks(entries)[0]["id"], "1")

    def test_first_compacted_goal_does_not_reuse_prior_tasks(self) -> None:
        old = [_call("old", "TaskList", {}),
               _result("old", {"tasks": [{"id": "1", "status": "completed"}]})]
        summary = {"type": "system", "compactMetadata": {"trigger": "manual"},
                   "message": {"content": "compaction summary: /goal 新しい作業"}}
        self.assertTrue(HOOK.should_block(old + [summary]))
        self.assertFalse(HOOK.should_block([
            {"type": "user", "message": {"content": "/goal 配布する"}}, *old, summary]))

    def test_failed_goal_creation_does_not_start_or_reset_goal(self) -> None:
        failed = [_call("goal", "mcp__goals__create_goal", {"objective": "新しい作業"}),
                  _result("goal", "creation failed", True)]
        self.assertFalse(HOOK.should_block(failed))
        active = [{"type": "user", "message": {"content": "/goal 配布する"}},
                  _call("old", "TaskList", {}),
                  _result("old", {"tasks": [{"id": "1", "status": "completed"}]})]
        self.assertFalse(HOOK.should_block(active + failed))
        pending = [{"type": "user", "message": {"content": "/goal 配布する"}}, *_created()]
        self.assertTrue(HOOK.should_block(pending + failed))

    def test_first_assistant_goal_does_not_reuse_prior_tasks(self) -> None:
        old = [_call("old", "TaskList", {}),
               _result("old", {"tasks": [{"id": "1", "status": "completed"}]})]
        declaration = {"type": "assistant", "message": {"content": "Goal: 新しい作業"}}
        self.assertTrue(HOOK.should_block(old + [declaration]))
        active = [{"type": "user", "message": {"content": "/goal 配布する"}}, *old]
        self.assertFalse(HOOK.should_block(active + [declaration]))

    def test_tool_examples_do_not_start_or_reset_goal(self) -> None:
        examples = [_call("read", "Read", {"example": "/goal example CreateGoal"}),
                    _result("read", "def CreateGoal(): pass\n# /goal example")]
        self.assertFalse(HOOK.should_block([
            {"type": "user", "message": {"content": "コードを確認して"}}, *examples]))
        entries = [{"type": "user", "message": {"content": "/goal 配布する"}},
                   *_created(), _call("done", "TaskUpdate", {"taskId": "1", "status": "completed"}),
                   _result("done", {"success": True}), *examples]
        self.assertFalse(HOOK.should_block(entries))

    def test_successful_deletion_is_terminal_but_failed_deletion_is_not(self) -> None:
        prefix = [{"type": "user", "message": {"content": "/goal 配布する"}}, *_created(),
                  _call("delete", "TaskUpdate", {"taskId": "1", "status": "deleted"})]
        self.assertFalse(HOOK.should_block(prefix + [_result("delete", {"success": True})]))
        self.assertEqual(HOOK.extract_tasks(prefix + [_result("delete", {"success": True})])[0]["status"], "deleted")
        self.assertTrue(HOOK.should_block(prefix + [_result("delete", "failed", True)]))

    def test_new_goal_requires_its_own_task_evidence(self) -> None:
        old = [{"type": "user", "message": {"content": "/goal 古い作業"}}, *_created(),
               _call("done", "TaskUpdate", {"taskId": "1", "status": "completed"}),
               _result("done", {"success": True})]
        self.assertFalse(HOOK.should_block(old))
        self.assertTrue(HOOK.should_block(old + [{"type": "user", "message": {"content": "/goal 新しい作業"}}]))
        new = old + [_call("goal", "mcp__goals__create_goal", {"objective": "新しい作業"})]
        self.assertTrue(HOOK.should_block(new))
        self.assertEqual(HOOK.extract_tasks(new), [])
        self.assertFalse(HOOK.should_block(new + [*_created(),
            _call("new-done", "TaskUpdate", {"taskId": "1", "status": "completed"}),
            _result("new-done", {"success": True})]))

    def test_overlapping_reverse_results_require_fresh_snapshot(self) -> None:
        entries = [{"type": "user", "message": {"content": "/goal 配布する"}}, *_created(),
                   _call("pending", "TaskUpdate", {"taskId": "1", "status": "pending"}),
                   _call("done", "TaskUpdate", {"taskId": "1", "status": "completed"}),
                   _result("done", {"success": True}), _result("pending", {"success": True})]
        self.assertTrue(HOOK.should_block(entries))
        for status in ("completed", "pending"):
            with self.subTest(status=status):
                latest = entries + [_call("latest", "TaskList", {}),
                    _result("latest", {"tasks": [{"id": "1", "subject": "配布する", "status": status}]})]
                self.assertEqual(HOOK.should_block(latest), status == "pending")

    def test_repeated_empty_lists_keep_completion_until_new_pending_work(self) -> None:
        done = [{"type": "user", "message": {"content": "/goal 配布する"}}, *_created(),
                _call("done", "TaskUpdate", {"taskId": "1", "status": "completed"}),
                _result("done", {"success": True})]
        empty = done + [_call("empty-1", "TaskList", {}), _result("empty-1", {"tasks": []}),
                        _call("empty-2", "TaskList", {}), _result("empty-2", {"tasks": []})]
        self.assertFalse(HOOK.should_block(empty))
        pending = empty + [_call("create-2", "TaskCreate", {"subject": "追加の作業"}),
                           _result("create-2", {"task": {"id": "2", "status": "pending"}}),
                           _call("empty-3", "TaskList", {}), _result("empty-3", {"tasks": []})]
        self.assertTrue(HOOK.should_block(pending))

    def test_repeated_empty_todos_keep_completion_until_new_pending_work(self) -> None:
        entries = [{"type": "user", "message": {"content": "/goal 配布する"}},
                   _call("done", "TodoWrite", {"todos": [{"content": "配布する", "status": "completed"}]}),
                   _result("done", {"success": True}),
                   _call("empty-1", "TodoWrite", {"todos": []}), _result("empty-1", {"success": True}),
                   _call("empty-2", "TodoWrite", {"todos": []}), _result("empty-2", {"success": True})]
        self.assertFalse(HOOK.should_block(entries))
        pending = entries + [_call("new", "TodoWrite", {"todos": [{"content": "追加の作業", "status": "pending"}]}),
                             _result("new", {"success": True}),
                             _call("empty-3", "TodoWrite", {"todos": []}), _result("empty-3", {"success": True})]
        self.assertTrue(HOOK.should_block(pending))

    def test_empty_snapshot_does_not_prove_pending_work_completed(self) -> None:
        entries = [{"type": "user", "message": {"content": "/goal 配布する"}}, *_created(),
                   _call("empty", "TaskList", {}), _result("empty", {"tasks": []})]
        self.assertTrue(HOOK.should_block(entries))

    def test_filtered_old_snapshot_does_not_prove_new_pending_work_completed(self) -> None:
        entries = [_call("old", "TaskList", {}),
                   _result("old", {"tasks": [{"id": "old", "status": "completed"}]}),
                   {"type": "user", "message": {"content": "/goal 新しい作業"}}, *_created(),
                   _call("stale", "TaskList", {}),
                   _result("stale", {"tasks": [{"id": "old", "status": "completed"}]}),
                   _call("empty", "TaskList", {}), _result("empty", {"tasks": []})]
        self.assertTrue(HOOK.should_block(entries))

    def test_empty_snapshot_preserves_current_goal_taskization(self) -> None:
        goal = {"type": "user", "message": {"content": "/goal 配布する"}}
        empty = [_call("empty", "TaskList", {}), _result("empty", {"tasks": []})]
        self.assertTrue(HOOK.should_block([goal, *empty]))
        self.assertFalse(HOOK.should_block([goal, *_created(),
            _call("done", "TaskUpdate", {"taskId": "1", "status": "completed"}),
            _result("done", {"success": True}), *empty]))

    def test_text_and_json_snapshots_preserve_all_tasks(self) -> None:
        fixtures = [
            (["#1 [pending] 配布する", "#1 [completed] 配布する"], False),
            (["#1 [completed] 配布する", "#1 [pending] 配布する"], True),
            ([{"tasks": [{"id": "1", "status": "pending"}]}, "#1 [completed] 配布する"], False),
            (["#1 [pending] 配布する", {"tasks": [{"id": "1", "status": "completed"}]}], False),
            (["#1 [completed] 配布する\n#2 [pending] 確認する"], True),
            ([[{"type": "text", "text": "#1 [completed] 配布する"},
               {"type": "text", "text": "#2 [pending] 確認する"}]], True),
        ]
        for payloads, expected in fixtures:
            with self.subTest(payloads=payloads):
                entries = [{"type": "user", "message": {"content": "/goal 配布する"}}]
                for index, payload in enumerate(payloads):
                    entries.extend([_call(str(index), "TaskList", {}), _result(str(index), payload)])
                self.assertEqual(HOOK.should_block(entries), expected)

    def test_partial_unrecognized_text_does_not_replace_pending_snapshot(self) -> None:
        entries = [{"type": "user", "message": {"content": "/goal 配布する"}},
                   _call("old", "TaskList", {}), _result("old", {"tasks": [
                       {"id": "1", "status": "pending"}, {"id": "2", "status": "pending"}]}),
                   _call("partial", "TaskList", {}),
                   _result("partial", "#1 [completed] 配布する\n残りは省略")]
        self.assertTrue(HOOK.should_block(entries))
        self.assertEqual(len(HOOK.extract_tasks(entries)), 2)


    def test_anonymous_pending_is_not_overwritten_by_completed(self) -> None:
        entries = [
            {"type": "user", "message": {"content": "/goal 続けて"}},
            {"type": "tool_use", "id": "list", "name": "TaskList", "input": {}},
            {"type": "tool_result", "tool_use_id": "list", "content": json.dumps({"tasks": [
                {"content": "未着手の実装", "status": "pending"},
                {"content": "完了した修正", "status": "completed"},
            ]})},
        ]
        self.assertEqual(len(HOOK.extract_tasks(entries)), 2)
        self.assertTrue(HOOK.should_block(entries))

    def test_only_explicit_label_authorizes_pending_hold(self) -> None:
        for text in [
            "本人承認は不要。未着手の実装を進める", "本人承認済みの変更を反映する",
            "本人承認は済んでいない", "本人承認は完了予定",
            "本人承認は不要ではありません", "本人承認は完了したら実装を進める",
            "本人承認は完了したのではありません", "本人承認は完了したのであれば実装を進める",
            "本人承認は不要になった", "本人承認は完了したため実装を進める",
            "明示保留ではない", "明示保留の札を付ける作業", "[明示保留]と書く",
            "[明示保留]", "[明示保留] owner= / 承認待ち",
            '[明示保留] owner="" / 承認待ち',
            "札の記入例\n[明示保留] owner=本人 / 承認待ち",
        ]:
            with self.subTest(text=text):
                self.assertFalse(HOOK.is_explicit_hold(text))
                self.assertFalse(HOOK.task_list_is_complete([{"content": text, "status": "pending"}]))
        for label in ["[明示保留] owner=本人 / 承認待ち", "【明示保留】 owner=本人 / 日付待ち", "明示保留：owner=本人 / 別プラン"]:
            with self.subTest(label=label):
                self.assertTrue(HOOK.is_explicit_hold(label))
                self.assertTrue(HOOK.task_list_is_complete([{"content": label, "status": "pending"}]))
        self.assertTrue(HOOK.task_list_is_complete([{
            "content": "本番操作を待つ", "note": "[明示保留] owner=本人 / 承認待ち", "status": "pending",
        }]))
        self.assertFalse(HOOK.task_list_is_complete([
            {"content": "[明示保留] owner=本人 / 承認待ち", "status": "pending"},
            {"content": "AIが行う実装", "status": "pending"},
        ]))

    def test_hold_owner_must_be_on_the_label_line(self) -> None:
        for text in [
            "[明示保留] owner=\n承認待ち", "[明示保留] owner=\r\n本人",
            "[明示保留]\nowner=本人", "[明示保留] owner\n=本人",
            "\n[明示保留] owner=本人", "明示保留：\nowner=本人",
        ]:
            with self.subTest(text=text):
                self.assertFalse(HOOK.is_explicit_hold(text))
                self.assertFalse(HOOK.task_list_is_complete([
                    {"content": text, "status": "pending"}
                ]))
        self.assertTrue(HOOK.is_explicit_hold(" [明示保留]\towner = 本人 / 承認待ち"))

    def test_document_view_request_does_not_activate_goal(self) -> None:
        for text in ["既存のプラン文書を表示して", "コミットメント台帳を見せて", "show the plan document"]:
            with self.subTest(text=text):
                self.assertFalse(HOOK.should_block([{"type": "user", "message": {"content": text}}]))
        self.assertTrue(HOOK.should_block([{"type": "user", "message": {"content": "/goal 続けて"}}]))

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
                                            "content": "[明示保留] owner=本人 / 本番投入 10/6以降",
                                            "status": "pending",
                                        },
                                        {
                                            "content": "[明示保留] owner=本人 / 本人承認待ち",
                                            "status": "pending",
                                        },
                                        {
                                            "content": "[明示保留] owner=本人 / 次期プラン",
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


    def test_request_or_negative_statement_is_not_completion_evidence(self) -> None:
        for role, content in [
            ("user", "/goal プラン文書とコミットメント台帳を作って"),
            ("user", "/goal コミットメント台帳はまだ作成していない"),
            ("user", "/goal 台帳は作成済みと書いてから進めて"),
            ("assistant", "Goal: コミットメント台帳はまだタスク化していない"),
            ("assistant", "Goal: 台帳をタスク化したい"),
            ("assistant", "Goal: 台帳をタスク化した場合は停止できます"),
            ("assistant", "Goal: ledger NOT created"),
            ("assistant", "Goal: ledger has not been created"),
            ("assistant", "Goal: ledger will be created"),
            ("assistant", "Goal: 台帳は作成済みですか？"),
            ("assistant", "Goal: 台帳をタスク化した と仮定します"),
        ]:
            with self.subTest(role=role, content=content):
                self.assertTrue(HOOK.should_block([
                    {"type": role, "message": {"content": content}}
                ]))

    def test_latest_task_snapshot_replaces_pending_history(self) -> None:
        for latest in [
            {"id": "1", "subject": "配布する", "status": "completed"},
            {"id": "1", "subject": "[明示保留] owner=本人 / 本人承認待ち", "status": "pending"},
        ]:
            entries = [
                {"type": "user", "message": {"content": "/goal 全部✓"}},
                {"type": "assistant", "message": {"content": [
                    {"type": "tool_use", "name": "TaskList", "input": {}}
                ]}},
            ]
            for task in [{"id": "1", "subject": "配布する", "status": "pending"}, latest]:
                entries.append({"type": "user", "message": {"content": [
                    {"type": "tool_result", "content": json.dumps({"tasks": [task]})}
                ]}})
            with self.subTest(latest=latest):
                self.assertFalse(HOOK.should_block(entries))

    def test_latest_actionable_task_still_blocks_after_old_completion(self) -> None:
        entries = [
            {"type": "user", "message": {"content": "/goal 全部✓"}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "TaskList"}]}},
        ]
        for status in ["completed", "pending"]:
            entries.append({"type": "user", "message": {"content": [{
                "type": "tool_result", "content": json.dumps({"tasks": [
                    {"id": "1", "subject": "配布する", "status": status}
                ]})
            }]}})
        self.assertTrue(HOOK.should_block(entries))


    def test_partial_update_does_not_erase_pending_task(self) -> None:
        entries = [
            {"type": "user", "message": {"content": "/goal 全部✓"}},
            {"type": "assistant", "message": {"content": [
                {"type": "tool_use", "id": "list", "name": "TaskList"}
            ]}},
            {"type": "user", "message": {"content": [{
                "type": "tool_result", "tool_use_id": "list", "content": json.dumps({"tasks": [
                    {"id": "A", "subject": "未完了", "status": "pending"},
                    {"id": "B", "subject": "完了", "status": "completed"}
                ]})
            }]}},
            {"type": "assistant", "message": {"content": [
                {"type": "tool_use", "id": "update", "name": "TaskUpdate", "input": {"taskId": "B", "status": "completed"}}
            ]}},
            {"type": "user", "message": {"content": [{
                "type": "tool_result", "tool_use_id": "update",
                "content": json.dumps({"task": {"id": "B", "status": "completed"}})
            }]}},
        ]
        self.assertTrue(HOOK.should_block(entries))
        self.assertEqual(len(HOOK.extract_tasks(entries)), 2)
        entries[-1]["message"]["content"][0]["content"] = json.dumps({"task": {"id": "A", "status": "completed"}})
        entries[-2]["message"]["content"][0]["input"]["taskId"] = "A"
        self.assertFalse(HOOK.should_block(entries))

    def test_user_task_json_is_not_a_tool_snapshot(self) -> None:
        entries = [{"type": "user", "message": {"content":
            '/goal {"tasks":[{"id":"1","status":"completed"}]}'}}]
        self.assertTrue(HOOK.should_block(entries))


    def test_compact_summary_negative_or_future_is_not_completion(self) -> None:
        for text in ["ledger has not been created", "ledger will be created", "台帳は作成済みですか？"]:
            with self.subTest(text=text):
                self.assertTrue(HOOK.should_block([{
                    "type": "system", "compactMetadata": {"trigger": "manual"},
                    "message": {"content": "Goal: " + text}
                }]))

    def test_user_compact_summary_metadata_preserves_completion(self) -> None:
        self.assertFalse(HOOK.should_block([{
            "type": "user", "isCompactSummary": True,
            "message": {"content": "Goal: コミットメント台帳をタスク化済み。"}
        }]))

    def test_failed_todowrite_does_not_replace_last_successful_state(self) -> None:
        entries = [{"type": "user", "message": {"content": "/goal 全部✓"}}]
        for call_id, status, error in [("first", "pending", False), ("second", "completed", True)]:
            entries.extend([
                {"type": "assistant", "message": {"content": [{
                    "type": "tool_use", "id": call_id, "name": "TodoWrite", "input": {"todos": [
                        {"content": "配布する", "status": status}
                    ]}
                }]}},
                {"type": "user", "message": {"content": [{
                    "type": "tool_result", "tool_use_id": call_id, "is_error": error,
                    "content": "failed" if error else "updated"
                }]}},
            ])
        self.assertTrue(HOOK.should_block(entries))
        entries[-1]["message"]["content"][0]["is_error"] = False
        self.assertFalse(HOOK.should_block(entries))

    def test_unknown_task_status_is_not_complete(self) -> None:
        self.assertFalse(HOOK.task_list_is_complete([{"subject": "配布", "status": "failed"}]))

    def test_text_taskupdate_success_uses_confirmed_input(self) -> None:
        for error in [True, False]:
            entries = [
                {"type": "user", "message": {"content": "/goal 全部✓"}},
                {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "list", "name": "TaskList"}]}},
                {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "list", "content": json.dumps({"tasks": [
                    {"id": "A", "subject": "配布する", "status": "pending"}
                ]})}]}},
                {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "update", "name": "TaskUpdate", "input": {
                    "taskId": "A", "status": "completed"
                }}]}},
                {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "update", "is_error": error,
                    "content": "Update failed" if error else "Updated task #A status"
                }]}},
            ]
            with self.subTest(error=error):
                self.assertEqual(HOOK.should_block(entries), error)

    def test_text_pending_update_after_compaction_records_unknown_task(self) -> None:
        entries = [
            {"type": "system", "compactMetadata": {"trigger": "manual"}, "message": {"content": "Goal: 台帳をタスク化済み。"}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "update", "name": "TaskUpdate", "input": {
                "taskId": "A", "status": "pending"
            }}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "update", "content": "Updated task #A status"}]}},
        ]
        self.assertTrue(HOOK.should_block(entries))
        self.assertEqual(HOOK.extract_tasks(entries)[0]["id"], "A")

    def test_compact_summary_accepts_ordinary_completed_wording(self) -> None:
        for text in ["コミットメント台帳をタスク化しました。", "台帳は作成済みである。", "台帳は作成済みです。"]:
            with self.subTest(text=text):
                self.assertFalse(HOOK.should_block([{
                    "type": "system", "compactMetadata": {"trigger": "manual"},
                    "message": {"content": "Goal: " + text}
                }]))


    def test_text_created_tasks_preserve_other_pending_and_unknown_ids(self) -> None:
        for reply in ["Task #A created successfully: first", "Task created successfully"]:
            entries = [{"type": "user", "message": {"content": "/goal 全部✓"}}]
            for cid, response in [("a", reply), ("b", "Task #B created successfully: second")]:
                entries.extend([
                    {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": cid, "name": "TaskCreate", "input": {"subject": cid}}]}},
                    {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": cid, "content": response}]}},
                ])
            entries.extend([
                {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "u", "name": "TaskUpdate", "input": {"taskId": "B", "status": "completed"}}]}},
                {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "u", "content": "Updated task #B status"}]}},
            ])
            with self.subTest(reply=reply):
                self.assertTrue(HOOK.should_block(entries))
                self.assertEqual(len(HOOK.extract_tasks(entries)), 2)
                entries.extend([
                    {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "l", "name": "TaskList"}]}},
                    {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "l", "content": json.dumps({"tasks": [{"id": "A", "status": "completed"}, {"id": "B", "status": "completed"}]})}]}},
                ])
                self.assertFalse(HOOK.should_block(entries))

    def test_english_summary_requires_completed_operation(self) -> None:
        for text, blocked in [("ledger must be created", True), ("ledger needs to be created", True), ("ledger is to be created", True), ("ledger was created", False), ("ledger has been created", False)]:
            with self.subTest(text=text):
                self.assertEqual(HOOK.should_block([{"type": "system", "compactMetadata": {}, "message": {"content": "Goal: " + text}}]), blocked)


    def test_todowrite_does_not_replace_taskcreate_family(self) -> None:
        entries = [{"type": "user", "message": {"content": "/goal 全部✓"}}]
        for cid, name, inp, reply in [
            ("a", "TaskCreate", {"subject": "A"}, "Task #A created successfully"),
            ("b", "TodoWrite", {"todos": [{"content": "B", "status": "completed"}]}, "updated"),
        ]:
            entries.extend([
                {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": cid, "name": name, "input": inp}]}},
                {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": cid, "content": reply}]}},
            ])
        self.assertTrue(HOOK.should_block(entries))
        self.assertEqual(len(HOOK.extract_tasks(entries)), 2)

    def test_delayed_old_snapshot_preserves_new_task(self) -> None:
        entries = [
            {"type": "user", "message": {"content": "/goal 全部✓"}},
            {"type": "assistant", "message": {"content": [
                {"type": "tool_use", "id": "list", "name": "TaskList"},
                {"type": "tool_use", "id": "create", "name": "TaskCreate", "input": {"subject": "new"}},
            ]}},
            {"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": "create", "content": "Task #A created successfully"},
                {"type": "tool_result", "tool_use_id": "list", "content": json.dumps({"tasks": [{"id": "B", "status": "completed"}]})},
            ]}},
        ]
        self.assertTrue(HOOK.should_block(entries))
        self.assertEqual(len(HOOK.extract_tasks(entries)), 2)


    def test_snapshot_preserves_creation_that_was_already_in_flight(self) -> None:
        for creation_result_first in [True, False]:
            calls = [
                {"type": "tool_use", "id": "create", "name": "TaskCreate", "input": {"subject": "A"}},
                {"type": "tool_use", "id": "list", "name": "TaskList"},
            ]
            results = [
                {"type": "tool_result", "tool_use_id": "create", "content": "Task #A created successfully"},
                {"type": "tool_result", "tool_use_id": "list", "content": json.dumps({"tasks": [{"id": "B", "status": "completed"}]})},
            ]
            if not creation_result_first:
                results.reverse()
            entries = [
                {"type": "user", "message": {"content": "/goal 全部✓"}},
                {"type": "assistant", "message": {"content": calls}},
                {"type": "user", "message": {"content": results}},
            ]
            with self.subTest(creation_result_first=creation_result_first):
                self.assertTrue(HOOK.should_block(entries))
                self.assertEqual(len(HOOK.extract_tasks(entries)), 2)


    def test_subject_only_update_does_not_restore_old_completed_status(self) -> None:
        for update_first in [True, False]:
            entries = [{"type": "user", "message": {"content": "/goal 全部✓"}}]
            entries.extend([
                {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "old", "name": "TaskList"}]}},
                {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "old", "content": json.dumps({"tasks": [{"id": "A", "status": "completed", "subject": "old"}]})}]}},
                {"type": "assistant", "message": {"content": [
                    {"type": "tool_use", "id": "update", "name": "TaskUpdate", "input": {"taskId": "A", "subject": "new"}},
                    {"type": "tool_use", "id": "list", "name": "TaskList"},
                ]}},
            ])
            results = [
                {"type": "tool_result", "tool_use_id": "update", "content": json.dumps({"task": {"id": "A", "status": "completed", "subject": "new"}})},
                {"type": "tool_result", "tool_use_id": "list", "content": json.dumps({"tasks": [{"id": "A", "status": "pending", "subject": "old"}]})},
            ]
            if not update_first: results.reverse()
            entries.append({"type": "user", "message": {"content": results}})
            with self.subTest(update_first=update_first):
                self.assertTrue(HOOK.should_block(entries))
                self.assertEqual(HOOK.extract_tasks(entries)[0]["subject"], "new")


    def test_created_initial_state_does_not_replace_snapshot_completed_status(self) -> None:
        for creation_first in [True, False]:
            results = [
                {"type": "tool_result", "tool_use_id": "create", "content": "Task #A created successfully"},
                {"type": "tool_result", "tool_use_id": "list", "content": json.dumps({"tasks": [{"id": "A", "status": "completed"}]})},
            ]
            if not creation_first: results.reverse()
            entries = [
                {"type": "user", "message": {"content": "/goal 全部✓"}},
                {"type": "assistant", "message": {"content": [
                    {"type": "tool_use", "id": "create", "name": "TaskCreate", "input": {"subject": "A"}},
                    {"type": "tool_use", "id": "list", "name": "TaskList"},
                ]}},
                {"type": "user", "message": {"content": results}},
            ]
            with self.subTest(creation_first=creation_first):
                self.assertFalse(HOOK.should_block(entries))
                self.assertEqual(HOOK.extract_tasks(entries)[0]["status"], "completed")


    def test_update_without_explicit_fields_cannot_invent_completion(self) -> None:
        entries = [
            {"type": "user", "message": {"content": "/goal 全部✓"}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "l", "name": "TaskList"}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "l", "content": json.dumps({"tasks": [{"id": "A", "status": "pending"}]})}]}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "u", "name": "TaskUpdate", "input": {"taskId": "A"}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "u", "content": json.dumps({"task": {"id": "A", "status": "completed"}})}]}},
        ]
        self.assertTrue(HOOK.should_block(entries))


    def test_interleaved_list_before_idless_create_result_uses_call_time_ids(self) -> None:
        entries = json.loads(r'''[
  {
    "type": "assistant",
    "message": {
      "content": [
        {
          "type": "tool_use",
          "id": "oldlist",
          "name": "TaskList",
          "input": {}
        }
      ]
    }
  },
  {
    "type": "user",
    "message": {
      "content": [
        {
          "type": "tool_result",
          "tool_use_id": "oldlist",
          "content": "{\"tasks\": [{\"id\": \"old\", \"subject\": \"\\u524d\\u306e\\u4f5c\\u696d\", \"status\": \"completed\"}]}"
        }
      ]
    }
  },
  {
    "type": "user",
    "message": {
      "content": "/goal 配布する"
    }
  },
  {
    "type": "assistant",
    "message": {
      "content": [
        {
          "type": "tool_use",
          "id": "c",
          "name": "TaskCreate",
          "input": {
            "subject": "配布する"
          }
        }
      ]
    }
  },
  {
    "type": "assistant",
    "message": {
      "content": [
        {
          "type": "tool_use",
          "id": "l1",
          "name": "TaskList",
          "input": {}
        }
      ]
    }
  },
  {
    "type": "user",
    "message": {
      "content": [
        {
          "type": "tool_result",
          "tool_use_id": "l1",
          "content": "{\"tasks\": [{\"id\": \"1\", \"subject\": \"\\u914d\\u5e03\\u3059\\u308b\", \"status\": \"pending\"}]}"
        }
      ]
    }
  },
  {
    "type": "user",
    "message": {
      "content": [
        {
          "type": "tool_result",
          "tool_use_id": "c",
          "content": "Task created successfully"
        }
      ]
    }
  },
  {
    "type": "assistant",
    "message": {
      "content": [
        {
          "type": "tool_use",
          "id": "u",
          "name": "TaskUpdate",
          "input": {
            "taskId": "1",
            "status": "completed"
          }
        }
      ]
    }
  },
  {
    "type": "user",
    "message": {
      "content": [
        {
          "type": "tool_result",
          "tool_use_id": "u",
          "content": "Updated task #1"
        }
      ]
    }
  },
  {
    "type": "assistant",
    "message": {
      "content": [
        {
          "type": "tool_use",
          "id": "l2",
          "name": "TaskList",
          "input": {}
        }
      ]
    }
  },
  {
    "type": "user",
    "message": {
      "content": [
        {
          "type": "tool_result",
          "tool_use_id": "l2",
          "content": "{\"tasks\": [{\"id\": \"1\", \"subject\": \"\\u914d\\u5e03\\u3059\\u308b\", \"status\": \"completed\"}]}"
        }
      ]
    }
  }
]''')
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
