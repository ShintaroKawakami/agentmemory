#!/usr/bin/env python3
"""Regression tests for stop-loop-continuity.py (止まる前の点検)."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
HOOK_PATH = HERE / "stop-loop-continuity.py"
POLICY_PATH = HERE.parent / "lib" / "loop-continuity-policy.json"
SPEC = importlib.util.spec_from_file_location("stop_loop_continuity", HOOK_PATH)
assert SPEC and SPEC.loader
HOOK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOOK)

PREFIX = "止まる前の点検:"


# ---- fixture builders -------------------------------------------------------

def user(text: str, kind: str | None = "human", **extra) -> dict:
    entry = {"type": "user", "message": {"role": "user", "content": text}}
    if kind:
        entry["origin"] = {"kind": kind}
    entry.update(extra)
    return entry


def assistant(text: str) -> dict:
    return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def tool_use(tid: str, name: str, **inp) -> dict:
    return {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": tid, "name": name, "input": inp}]}}


def tool_result(tid: str, text: str, is_error: bool = False, **tur) -> dict:
    entry = {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tid, "is_error": is_error, "content": text}]}}
    if tur:
        entry["toolUseResult"] = tur
    return entry


def notification(task_id: str, status: str | None = "completed", tool_use_id: str = "") -> dict:
    body = f"<task-notification>\n<task-id>{task_id}</task-id>\n"
    if tool_use_id:
        body += f"<tool-use-id>{tool_use_id}</tool-use-id>\n"
    if status:
        body += f"<status>{status}</status>\n"
    body += "<summary>x</summary>\n</task-notification>"
    return user(body, kind="task-notification")


def bg_bash(tid: str, task: str) -> list[dict]:
    return [tool_use(tid, "Bash", command="sleep 300", run_in_background=True),
            tool_result(tid, f"Command running in background with ID: {task}. Output is being written to: /tmp/x",
                        backgroundTaskId=task)]


def monitor(tid: str, task: str) -> list[dict]:
    return [tool_use(tid, "Monitor", command="until false; do sleep 1; done"),
            tool_result(tid, f"Monitor started (task {task}, expires in 30m unless the source ends first)",
                        taskId=task, timeoutMs=1800000)]


def agent_bg(tid: str, agent: str) -> list[dict]:
    return [tool_use(tid, "Agent", prompt="x", run_in_background=True),
            tool_result(tid, f"Async agent launched successfully.\nagentId: {agent}",
                        isAsync=True, status="async_launched", agentId=agent)]


class _Base(unittest.TestCase):
    def setUp(self) -> None:
        self._env = mock.patch.dict(os.environ, {}, clear=False)
        self._env.start()
        self.addCleanup(self._env.stop)
        for key in (HOOK.SKIP_PS_ENV, HOOK.PS_FILE_ENV, HOOK.POLICY_ENV):
            os.environ.pop(key, None)
        # 実マシンのプロセスに依存しない: 既定は「見張りプロセス無し」の ps ファイル。
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.set_ps([])
        self.policy = HOOK.load_policy(POLICY_PATH)
        assert self.policy is not None

    def set_ps(self, lines: list[str]) -> None:
        path = Path(self.tmp.name) / "ps.txt"
        path.write_text("\n".join(lines), encoding="utf-8")
        os.environ[HOOK.PS_FILE_ENV] = str(path)

    def decide(self, entries: list[dict]) -> str | None:
        return HOOK.decide(entries, self.policy)

    def run_main(self, payload: dict, entries: list[dict] | None = None, raw_file: str | None = None) -> tuple[int, str]:
        if entries is not None or raw_file is not None:
            path = Path(self.tmp.name) / "t.jsonl"
            path.write_text(raw_file if raw_file is not None else
                            "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in entries), encoding="utf-8")
            payload = {**payload, "transcript_path": str(path)}
        old_in, old_out = sys.stdin, sys.stdout
        sys.stdin, sys.stdout = io.StringIO(json.dumps(payload)), io.StringIO()
        try:
            code = HOOK.main()
            return code, sys.stdout.getvalue()
        finally:
            sys.stdin, sys.stdout = old_in, old_out


class WaitWithoutWatcher(_Base):
    def test_wait_without_watcher_blocks(self):
        reason = self.decide([user("続きをお願い"), assistant("テストは裏で走っています。終わったら続けます。")])
        self.assertTrue(reason and reason.startswith(PREFIX))
        self.assertIn("見張り", reason)

    def test_wait_with_open_background_bash_passes(self):
        entries = [user("開始して"), *bg_bash("t1", "bg1"), assistant("終わったら続けます。")]
        self.assertIsNone(self.decide(entries))

    def test_wait_with_open_monitor_passes(self):
        self.assertIsNone(self.decide([user("開始して"), *monitor("m1", "mon1"), assistant("結果が出たら確認します。")]))

    def test_wait_with_open_background_agent_passes(self):
        self.assertIsNone(self.decide([user("開始して"), *agent_bg("a1", "agent1"), assistant("完了を待ちます。")]))

    def test_watcher_launch_failed_blocks(self):
        entries = [user("開始して"),
                   tool_use("t1", "Bash", command="x", run_in_background=True),
                   tool_result("t1", "command not found", is_error=True),
                   assistant("終わったら続けます。")]
        self.assertTrue(self.decide(entries))

    def test_finished_background_blocks(self):
        entries = [user("開始して"), *bg_bash("t1", "bg1"), notification("bg1", "completed"),
                   assistant("終わったら続けます。")]
        self.assertTrue(self.decide(entries))

    def test_notification_matched_by_tool_use_id(self):
        entries = [user("開始して"), *bg_bash("t1", "bg1"), notification("zzz", "failed", tool_use_id="t1"),
                   assistant("完了を待ちます。")]
        self.assertTrue(self.decide(entries))

    def test_other_jobs_notification_keeps_watcher_open(self):
        entries = [user("開始して"), *bg_bash("t1", "bg1"), notification("other", "completed"),
                   assistant("終わったら続けます。")]
        self.assertIsNone(self.decide(entries))

    def test_monitor_event_without_status_does_not_close(self):
        entries = [user("開始して"), *monitor("m1", "mon1"), notification("mon1", None),
                   assistant("結果が出たら確認します。")]
        self.assertIsNone(self.decide(entries))

    def test_monitor_stream_ended_closes(self):
        entries = [user("開始して"), *monitor("m1", "mon1"), notification("mon1", "completed"),
                   assistant("結果が出たら確認します。")]
        self.assertTrue(self.decide(entries))

    def test_watcher_process_alive_without_transcript_background_blocks(self):
        # [2026-10-24][fix] 別セッションの見張りプロセスは「見張りあり」の証拠にしない（回帰テスト）。
        self.set_ps(["/bin/bash /Users/x/business/AGENT-HUB/scripts/watch-pr-checks.sh 12 a/b 900"])
        reason = self.decide([user("お願い"), assistant("CI の完了を待ちます。")])
        self.assertTrue(reason and reason.startswith(PREFIX))

    def test_grep_for_watcher_is_not_a_watcher(self):
        self.set_ps(["grep watch-pr-checks.sh", "vim scripts/watch-cli-log.sh"])
        self.assertTrue(self.decide([user("お願い"), assistant("CI の完了を待ちます。")]))

    def test_skip_process_check_ignores_alive_process(self):
        # [2026-10-24][fix] alive は見張りの証拠にならないため、SKIP の有無にかかわらず block する。
        self.set_ps(["/bin/bash /Users/x/scripts/watch-worker-job.sh job1"])
        self.assertTrue(self.decide([user("お願い"), assistant("完了を待ちます。")]))
        os.environ[HOOK.SKIP_PS_ENV] = "1"
        self.assertTrue(self.decide([user("お願い"), assistant("完了を待ちます。")]))

    def test_skip_process_check_still_honours_transcript_background(self):
        os.environ[HOOK.SKIP_PS_ENV] = "1"
        entries = [user("開始"), *bg_bash("t1", "bg1"), assistant("終わったら続けます。")]
        self.assertIsNone(self.decide(entries))

    def test_ps_unavailable_is_unknown_and_passes(self):
        os.environ[HOOK.PS_FILE_ENV] = str(Path(self.tmp.name) / "missing.txt")
        self.assertIsNone(self.decide([user("お願い"), assistant("完了を待ちます。")]))

    def test_unrecognised_background_result_is_unknown_and_passes(self):
        entries = [user("開始"),
                   tool_use("t1", "Bash", command="x", run_in_background=True),
                   tool_result("t1", "started somehow"),
                   assistant("終わったら続けます。")]
        self.assertIsNone(self.decide(entries))

    def test_wait_with_carryover_passes(self):
        self.assertIsNone(self.decide([user("お願い"), assistant("明日の夜の実行が終わったら確認します。")]))


class MidSentence(_Base):
    def test_intent_ending_blocks(self):
        reason = self.decide([user("調べて"), assistant("原因の目星はつきました。次に設定を確認します。")])
        self.assertTrue(reason and "今やってください" in reason)

    def test_intent_continue_blocks(self):
        self.assertTrue(self.decide([user("やって"), assistant("では実装を続けます。")]))

    def test_tool_after_text_passes(self):
        entries = [user("調べて"), assistant("設定を確認します。"), tool_use("t1", "Read", file_path="/x")]
        self.assertIsNone(self.decide(entries))

    def test_completion_report_passes(self):
        self.assertIsNone(self.decide([user("直して"), assistant("修正が終わりました。テストも通っています。")]))

    def test_done_phrase_with_final_intent_passes(self):
        self.assertIsNone(self.decide([user("直して"), assistant("実装は完了しました。細部は後で本人が確認します。")]))

    def test_carryover_passes(self):
        self.assertIsNone(self.decide([user("直して"), assistant("残りは次回に確認します。")]))

    def test_plain_report_passes(self):
        self.assertIsNone(self.decide([user("どうなった"), assistant("テストは全て緑です。変更は3ファイルです。")]))

    def test_intent_inside_code_or_quote_is_ignored(self):
        text = "結果は次のとおりです。\n```\n確認します。\n```\n> 続けます。\n`実行します`"
        self.assertIsNone(self.decide([user("見せて"), assistant(text)]))


class ReconfirmAfterApproval(_Base):
    def test_reconfirm_after_approval_blocks(self):
        reason = self.decide([user("進めて"), assistant("計画は以上です。進めてよいですか？")])
        self.assertTrue(reason and "承認があります" in reason)

    def test_reconfirm_after_ok_blocks(self):
        self.assertTrue(self.decide([user("OK、お願いします"), assistant("では実行してよいですか？")]))

    def test_reconfirm_without_prior_approval_passes(self):
        self.assertIsNone(self.decide([user("これを調べて"), assistant("進めてよいですか？")]))

    def test_reconfirm_with_scope_reason_passes(self):
        self.assertIsNone(self.decide([user("進めて"), assistant("承認の範囲外のファイルも触るため、進めてよいですか？")]))

    def test_user_negation_passes(self):
        self.assertIsNone(self.decide([user("待って、まだ進めないで"), assistant("進めてよいですか？")]))

    def test_production_gate_passes(self):
        self.assertIsNone(self.decide([user("進めて"), assistant("本番に出していいですか？")]))


class HumanWait(_Base):
    def test_explicit_hold_passes(self):
        self.assertIsNone(self.decide([user("お願い"), assistant("[明示保留] owner=伸太郎 本番確認を待ちます。終わったら続けます。")]))

    def test_choice_question_passes(self):
        self.assertIsNone(self.decide([user("お願い"), assistant("方法は2つあります。\nA 全部直す / B 一部だけ直す\nどれにしますか？推奨: B")]))

    def test_production_go_wait_passes(self):
        self.assertIsNone(self.decide([user("お願い"), assistant("準備ができました。本番に反映してよいか承認をお願いします。続けます。")]))

    def test_plan_approval_passes(self):
        self.assertIsNone(self.decide([user("お願い"), assistant("この実装でいいですか？（進めて / 直す / やらない）")]))

    def test_ask_user_question_passes(self):
        entries = [user("お願い"), tool_use("q", "AskUserQuestion", questions=[]), assistant("確認します。")]
        self.assertIsNone(self.decide(entries))

    def test_answered_ask_user_question_does_not_pass_intent_end(self):
        # [2026-10-24][fix] 回答済みの質問があっても、回答後の途中の一言は通さない（回帰テスト）。
        entries = [user("お願い"), tool_use("q", "AskUserQuestion", questions=[]),
                   tool_result("q", "回答: A 全部直す"), assistant("では実装を続けます。")]
        reason = self.decide(entries)
        self.assertTrue(reason and reason.startswith(PREFIX))


class TurnBoundary(_Base):
    def test_synthetic_user_lines_do_not_move_boundary(self):
        # 実ユーザー「進めて」の後に通知・system-reminder・hook feedback・tool_result が挟まっても境界は動かない。
        entries = [
            user("進めて"),
            assistant("作業を進めます。"),
            tool_result("x", "ok"),
            user("<system-reminder>reminder</system-reminder>", kind=None),
            user("Stop hook feedback:\nsomething", kind=None, isMeta=True),
            notification("zzz", "completed"),
            assistant("進めてよいですか？"),
        ]
        self.assertTrue(self.decide(entries))

    def test_old_turn_text_is_not_judged(self):
        entries = [user("前の依頼"), assistant("終わったら続けます。"), user("新しい依頼"), assistant("結果です。問題ありません。")]
        self.assertIsNone(self.decide(entries))

    def test_real_user_after_synthetic_is_boundary(self):
        entries = [user("進めて"), assistant("完了しました。"), notification("z"), user("ありがとう"),
                   assistant("どういたしまして。")]
        self.assertIsNone(self.decide(entries))

    def test_approval_taken_from_latest_real_user_not_notification(self):
        entries = [user("調べて"), notification("z", "completed"), assistant("進めてよいですか？")]
        self.assertIsNone(self.decide(entries))

    def test_sidechain_entries_are_ignored(self):
        side = assistant("終わったら続けます。")
        side["isSidechain"] = True
        self.assertIsNone(self.decide([user("お願い"), assistant("結果です。以上です。"), side]))


class MainEntry(_Base):
    BLOCKING = [user("お願い"), assistant("完了を待ちます。")]

    def test_block_output_shape(self):
        code, out = self.run_main({}, entries=self.BLOCKING)
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertEqual(data["decision"], "block")
        self.assertTrue(data["reason"].startswith(PREFIX))

    def test_pass_prints_nothing(self):
        code, out = self.run_main({}, entries=[user("どう"), assistant("全て終わりました。")])
        self.assertEqual((code, out), (0, ""))

    def test_stop_hook_active_always_passes(self):
        for key, value in (("stop_hook_active", True), ("stopHookActive", True), ("loop_count", 1)):
            code, out = self.run_main({key: value}, entries=self.BLOCKING)
            self.assertEqual((code, out), (0, ""), key)

    def test_empty_transcript_passes(self):
        self.assertEqual(self.run_main({}, raw_file=""), (0, ""))

    def test_broken_transcript_passes(self):
        self.assertEqual(self.run_main({}, raw_file="{not json\n\x00\x01garbage\n"), (0, ""))

    def test_no_transcript_path_cursor_form_passes(self):
        self.assertEqual(self.run_main({"conversation_id": "c1", "status": "completed"}), (0, ""))

    def test_non_claude_transcript_shape_passes(self):
        cursor = [{"role": "user", "text": "お願い"}, {"role": "assistant", "text": "完了を待ちます。"}]
        self.assertEqual(self.run_main({}, entries=cursor), (0, ""))

    def test_missing_transcript_file_passes(self):
        self.assertEqual(self.run_main({"transcript_path": "/nonexistent/x.jsonl"}), (0, ""))

    def test_unreadable_stdin_passes(self):
        old_in, old_out = sys.stdin, sys.stdout
        sys.stdin, sys.stdout = io.StringIO("not json"), io.StringIO()
        try:
            self.assertEqual(HOOK.main(), 0)
            self.assertEqual(sys.stdout.getvalue(), "")
        finally:
            sys.stdin, sys.stdout = old_in, old_out


class PolicyFile(_Base):
    def test_unreadable_policy_passes(self):
        bad = Path(self.tmp.name) / "bad.json"
        bad.write_text("{broken", encoding="utf-8")
        os.environ[HOOK.POLICY_ENV] = str(bad)
        self.assertIsNone(HOOK.load_policy())
        self.assertEqual(self.run_main({}, entries=MainEntry.BLOCKING), (0, ""))

    def test_missing_policy_passes(self):
        os.environ[HOOK.POLICY_ENV] = str(Path(self.tmp.name) / "none.json")
        self.assertIsNone(HOOK.load_policy())
        self.assertEqual(self.run_main({}, entries=MainEntry.BLOCKING), (0, ""))

    def test_policy_missing_required_key_passes(self):
        data = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
        del data["wait_patterns"]
        broken = Path(self.tmp.name) / "partial.json"
        broken.write_text(json.dumps(data), encoding="utf-8")
        self.assertIsNone(HOOK.load_policy(broken))

    def test_script_has_no_hardcoded_trigger_words(self):
        source = HOOK_PATH.read_text(encoding="utf-8")
        body = source.split('"""', 2)[2]  # docstring（CaD）より後ろ
        for word in ("待ちます", "続けます", "進めてよいですか", "よろしいですか"):
            self.assertNotIn(word, body)


if __name__ == "__main__":
    unittest.main()
