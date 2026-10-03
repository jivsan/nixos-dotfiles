"""Bridge regression tests; all executors and model requests are mocked.

Run with: python3 -m unittest discover -s hosts/heimdall/muninn/brain -p 'test_*.py'
"""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import bridge
from jobs import JobStore


def setUpModule():
    # This suite also runs on heimdall: keep it out of the live talk log, spool and Pulse counters.
    scratch = tempfile.TemporaryDirectory()
    unittest.addModuleCleanup(scratch.cleanup)
    for name, leaf in (("LOG_DIR", "talk"), ("TALK_SPOOL", "talk-spool.jsonl"), ("STATS_FILE", "stats.json")):
        patch = mock.patch.object(bridge, name, str(Path(scratch.name) / leaf))
        patch.start()
        unittest.addModuleCleanup(patch.stop)


def jev_choice(choice, confidence=0.9):
    return {"choice": choice, "confidence": confidence, "probabilities": {choice: 1.0}}


class RoutingTests(unittest.TestCase):
    def test_action_questions_still_reach_an_agent_without_jev(self):
        for text in (
            "Can you research backup strategies and file a report?",
            "Could you fix the broken notes?",
            "Please write a summary document?",
        ):
            with self.subTest(text=text):
                self.assertEqual(bridge.route_rules(text)["tier"], "agent")

    def test_commands_remain_commands(self):
        for text, command in (
            ("capture replace the backup disk", "capture"),
            ("search for backups", "search"),
            ("run daily-digest", "run_skill"),
            ("open memory", "open_view"),
        ):
            with self.subTest(text=text):
                result = bridge.route_rules(text)
                self.assertEqual((result["tier"], result["command"]), ("command", command))

    def test_informational_questions_do_not_start_an_agent(self):
        for text in ("How do I write a note?", "What research did we save?", "Where is my report?"):
            with self.subTest(text=text):
                self.assertEqual(bridge.route_rules(text)["tier"], "answer")

    def test_missing_jev_key_uses_local_routing(self):
        with mock.patch.object(bridge, "JEV_KEY", ""), mock.patch.object(bridge, "post_json") as post:
            self.assertIsNone(bridge.route_jev("What is my backup schedule?"))
        post.assert_not_called()

    def test_malformed_jev_responses_are_recoverable(self):
        for response in ([], None, {"answers": []}, {"answers": {"tier": "agent"}},
                         {"answers": {"tier": {"choice": "unrecognized"}}}):
            with self.subTest(response=response), mock.patch.object(bridge, "JEV_KEY", "test"), \
                    mock.patch.object(bridge, "post_json", return_value=response):
                self.assertIn("error", bridge.route_jev("Research backups"))

    def test_upstream_failure_is_reported(self):
        with mock.patch.object(bridge, "JEV_KEY", "test"), \
                mock.patch.object(bridge, "post_json", side_effect=TimeoutError("timed out")):
            self.assertIn("timed out", bridge.route_jev("Research backups")["error"])

    def test_jev_uses_separate_key_and_receives_worker_availability(self):
        response = {"answers": {"tier": jev_choice("agent"), "executor": jev_choice("codex", 0.8)}}
        available = {"hermes": False, "codex": True}
        with mock.patch.object(bridge, "JEV_KEY", "router-key"), \
                mock.patch.object(bridge, "available_agents", return_value=available), \
                mock.patch.object(bridge, "post_json", return_value=response) as post:
            result = bridge.route_jev("Research backups")
        self.assertEqual(result["executor"], "codex")
        self.assertEqual(post.call_args.kwargs["key"], "router-key")
        self.assertEqual(post.call_args.args[1]["state"]["available_agents"], available)

    def test_uncertain_skill_does_not_inherit_tier_confidence(self):
        response = {"answers": {"tier": jev_choice("command", 0.99),
                                "command": jev_choice("run_skill", 0.99),
                                "skill": jev_choice("gardener", 0.1)}}
        with mock.patch.object(bridge, "JEV_KEY", "router-key"), \
                mock.patch.object(bridge, "post_json", return_value=response):
            self.assertIn("uncertain Jev skill", bridge.route_jev("Run the gardener")["error"])

    def test_invalid_confidence_cannot_authorize_dispatch(self):
        for confidence in (None, True, "0.9", -0.1, 1.1, float("nan")):
            response = {"answers": {"tier": {"choice": "answer", "confidence": confidence}}}
            with self.subTest(confidence=confidence), mock.patch.object(bridge, "JEV_KEY", "test"), \
                    mock.patch.object(bridge, "post_json", return_value=response):
                self.assertIn("error", bridge.route_jev("What is in my vault?"))

    def test_malformed_probabilities_do_not_escape_into_logging(self):
        for probabilities in ("bad", [0.9], {"answer": "high"}):
            response = {"answers": {"tier": {"choice": "answer", "confidence": 0.9,
                                               "probabilities": probabilities}}}
            with self.subTest(probabilities=probabilities), mock.patch.object(bridge, "JEV_KEY", "test"), \
                    mock.patch.object(bridge, "post_json", return_value=response):
                result = bridge.route_jev("What is in my vault?")
                if "error" not in result:
                    self.assertIsInstance(result["probabilities"], dict)
                    self.assertTrue(all(type(value) in (int, float)
                                        for value in result["probabilities"].values()))

    def test_explicit_executor_still_goes_through_jev(self):
        route = {"via": "jev", "tier": "answer", "model": "test-jev", "ms": 1,
                 "probabilities": {"answer": 1.0}, "confidence": None,
                 "command": "none", "skill": "none"}
        with mock.patch.object(bridge, "route_jev", return_value=route) as router, \
                mock.patch.object(bridge, "pick_agent", return_value="codex"), \
                mock.patch.object(bridge, "start_agent", return_value={"id": "example"}) as start, \
                mock.patch.object(bridge, "log_talk"):
            result = bridge.talk("Please work on this", "codex")
        router.assert_called_once()
        start.assert_called_once()
        self.assertEqual(result["route"]["via"], "jev")
        self.assertEqual(result["route"]["tier"], "agent")
        self.assertEqual(result["job"], "example")

    def test_jev_failure_is_visible_in_response(self):
        with mock.patch.object(bridge, "route_jev", return_value={"error": "timed out"}), \
                mock.patch.object(bridge, "log_talk"):
            result = bridge.talk("open memory")
        self.assertEqual(result["jev_error"], "timed out")
        self.assertEqual(result["route"]["via"], "rules")
        self.assertEqual(result["action"], {"type": "view", "view": "memory"})

    def test_valid_jev_agent_choice_controls_actual_executor_dispatch(self):
        for executor in ("codex", "hermes"):
            response = {"model": "typesafe/jev-1.13", "answers": {
                "tier": jev_choice("agent"), "executor": jev_choice(executor)}}
            with self.subTest(executor=executor), mock.patch.object(bridge, "JEV_KEY", "test"), \
                    mock.patch.object(bridge, "available_agents", return_value={"hermes": True, "codex": True}), \
                    mock.patch.object(bridge, "post_json", return_value=response), \
                    mock.patch.object(bridge, "route_rules", wraps=bridge.route_rules) as rules, \
                    mock.patch.object(bridge, "start_agent", return_value={"id": "new-job"}) as start:
                result = bridge.talk("Please investigate storage")
            rules.assert_not_called()
            self.assertEqual(result["route"]["via"], "jev")
            self.assertEqual(result["route"]["selected_executor"], executor)
            self.assertEqual(start.call_args.args[:2], ("Please investigate storage", executor))
            self.assertEqual(start.call_args.args[2]["decisions"], response["answers"])
            self.assertNotIn("jev_error", result)

    def test_valid_jev_command_runs_selected_skill(self):
        response = {"answers": {"tier": jev_choice("command"), "command": jev_choice("run_skill"),
                                "skill": jev_choice("gardener")}}
        with mock.patch.object(bridge, "JEV_KEY", "test"), \
                mock.patch.object(bridge, "post_json", return_value=response), \
                mock.patch.object(bridge, "run_skill", return_value=(True, "Started gardener.")) as run, \
                mock.patch.object(bridge, "route_rules", wraps=bridge.route_rules) as rules, \
                mock.patch.object(bridge, "answer") as answer, \
                mock.patch.object(bridge, "start_agent") as start, \
                mock.patch.object(bridge, "log_talk"):
            result = bridge.talk("Please tidy the knowledge base")
        run.assert_called_once_with("gardener")
        rules.assert_not_called()
        answer.assert_not_called()
        start.assert_not_called()
        self.assertEqual(result["route"]["via"], "jev")
        self.assertEqual(result["action"], {"type": "run", "skill": "gardener", "ok": True})

    def test_valid_jev_answer_ignores_irrelevant_subchoices(self):
        response = {"answers": {"tier": jev_choice("answer"), "depth": jev_choice("light"),
                                "command": {"confidence": 0},
                                "executor": {"confidence": 0}, "skill": {"confidence": 0}}}
        with mock.patch.object(bridge, "JEV_KEY", "test"), \
                mock.patch.object(bridge, "post_json", return_value=response), \
                mock.patch.object(bridge, "route_rules", wraps=bridge.route_rules) as rules, \
                mock.patch.object(bridge, "answer", return_value={"answer": "Backups run daily."}) as answer, \
                mock.patch.object(bridge, "log_talk"):
            result = bridge.talk("When do backups run?")
        rules.assert_not_called()
        answer.assert_called_once_with("When do backups run?", "light")
        self.assertEqual(result["route"]["via"], "jev")
        self.assertEqual(result["answer"], "Backups run daily.")

    def test_jev_deep_answer_reaches_the_answer_tier_with_depth(self):
        response = {"answers": {"tier": jev_choice("answer"), "depth": jev_choice("deep")}}
        with mock.patch.object(bridge, "JEV_KEY", "test"), \
                mock.patch.object(bridge, "post_json", return_value=response), \
                mock.patch.object(bridge, "answer", return_value={"answer": "Detailed comparison."}) as answer, \
                mock.patch.object(bridge, "log_talk"):
            result = bridge.talk("Compare my backup strategies in depth")
        answer.assert_called_once_with("Compare my backup strategies in depth", "deep")
        self.assertEqual(result["route"]["depth"], "deep")

    def test_answer_tier_without_a_depth_choice_is_malformed(self):
        response = {"answers": {"tier": jev_choice("answer")}}
        with mock.patch.object(bridge, "JEV_KEY", "test"), \
                mock.patch.object(bridge, "post_json", return_value=response):
            self.assertIn("error", bridge.route_jev("What is in my vault?"))

    def test_rules_depth_heuristic(self):
        self.assertEqual(bridge.route_rules("How do I write a note?")["depth"], "light")
        self.assertEqual(bridge.route_rules("Compare my backup options and explain the tradeoffs")["depth"], "deep")
        self.assertEqual(bridge.route_rules("open memory")["depth"], None)

    def test_uncertain_command_or_skill_uses_rules_and_records_reason(self):
        for uncertain in ("command", "skill"):
            choices = {"tier": jev_choice("command"), "command": jev_choice("run_skill"),
                       "skill": jev_choice("gardener")}
            choices[uncertain]["confidence"] = 0.1
            with self.subTest(uncertain=uncertain), mock.patch.object(bridge, "JEV_KEY", "test"), \
                    mock.patch.object(bridge, "post_json", return_value={"answers": choices}), \
                    mock.patch.object(bridge, "run_skill", return_value=(True, "Started daily-digest.")) as run, \
                    mock.patch.object(bridge, "log_talk"):
                result = bridge.talk("Run daily-digest")
            run.assert_called_once_with("daily-digest")
            self.assertEqual(result["route"]["via"], "rules")
            self.assertEqual(result["route"]["fallback_reason"], f"uncertain Jev {uncertain} choice")
            self.assertEqual(result["jev_error"], result["route"]["fallback_reason"])

    def test_uncertain_executor_uses_available_worker_and_preserves_fallback_in_job(self):
        response = {"answers": {"tier": jev_choice("agent"), "executor": jev_choice("codex", 0.1)}}
        with mock.patch.object(bridge, "JEV_KEY", "test"), \
                mock.patch.object(bridge, "post_json", return_value=response), \
                mock.patch.object(bridge, "available_agents", return_value={"hermes": True, "codex": True}), \
                mock.patch.object(bridge, "start_agent", return_value={"id": "new-job"}) as start:
            result = bridge.talk("Research storage")
        self.assertEqual(start.call_args.args[1], "hermes")
        self.assertEqual(start.call_args.args[2]["fallback_reason"], "uncertain Jev executor choice")
        self.assertEqual(result["route"]["via"], "rules")


class ExecutorTests(unittest.TestCase):
    def test_hermes_jobs_have_distinct_conversations_and_vault_instructions(self):
        response = {"output": [{"type": "message", "content": [
            {"type": "output_text", "text": "Research completed."}]}]}
        with mock.patch.object(bridge, "post_json", return_value=response) as post:
            for identifier in ("job-one", "job-two"):
                job = {"id": identifier, "text": "Research backups", "agent": "hermes"}
                bridge.run_hermes(job)
                self.assertEqual(job["status"], "done")
        bodies = [call.args[1] for call in post.call_args_list]
        self.assertNotEqual(bodies[0]["conversation"], bodies[1]["conversation"])
        for identifier, body in zip(("job-one", "job-two"), bodies):
            self.assertIn(identifier, body["conversation"])
            self.assertIn("CLAUDE.md", body["input"])
            self.assertIn("Research backups", body["input"])

    def test_empty_hermes_output_fails(self):
        job = {"id": "empty", "text": "Research backups", "agent": "hermes"}
        with mock.patch.object(bridge, "post_json", return_value={"output": []}):
            bridge.run_hermes(job)
        self.assertEqual(job["status"], "failed")
        self.assertTrue(job["answer"])


class BridgeJobIntegrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.store = JobStore(root / "jobs.db", root, max_active=1)
        self.route = {"via": "jev", "tier": "agent", "executor": "hermes"}
        patch = mock.patch.object(bridge, "job_store", return_value=self.store)
        patch.start()
        self.addCleanup(patch.stop)

    def test_unexpected_executor_failure_is_filed_and_logged_with_original_route(self):
        job = self.store.create("Research storage", "hermes", self.route)
        with mock.patch.object(bridge, "run_hermes", side_effect=RuntimeError("Worker crashed")), \
                mock.patch.object(bridge, "log_talk") as log:
            bridge.run_agent(job)
        saved = self.store.get(job["id"])
        self.assertEqual(saved["status"], "failed")
        self.assertIn("Worker crashed", saved["answer"])
        self.assertTrue((self.store.vault / saved["report"]).is_file())
        self.assertEqual(log.call_args.args[1]["route"], self.route)
        self.assertIn(saved["report"][:-3], log.call_args.args[1]["answer"])

    def test_thread_start_failure_is_a_durable_failure(self):
        with mock.patch.object(bridge.threading, "Thread", side_effect=RuntimeError("Cannot start")):
            job = bridge.start_agent("Research storage", "hermes", self.route)
        saved = self.store.get(job["id"])
        self.assertEqual(saved["status"], "failed")
        self.assertIn("worker thread", saved["answer"])
        self.assertIn("report", saved)

    def test_busy_bridge_never_starts_another_worker(self):
        self.store.create("Existing work", "hermes", self.route)
        with mock.patch.object(bridge, "route_jev", return_value=self.route), \
                mock.patch.object(bridge, "pick_agent", return_value="hermes"), \
                mock.patch.object(bridge, "log_talk") as log, \
                mock.patch.object(bridge.threading, "Thread") as thread:
            result = bridge.talk("Research storage")
        self.assertTrue(result["busy"])
        self.assertNotIn("job", result)
        thread.assert_not_called()
        # the refusal is logged with the worker that was asked, the response is unchanged
        self.assertEqual(log.call_args.args[0], "Research storage")
        self.assertEqual(log.call_args.args[1]["agent"], "hermes")
        self.assertNotIn("agent", result)


class RestartLogTests(unittest.TestCase):
    def test_job_cut_off_by_a_restart_is_logged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            JobStore(root / "jobs.db", root).create("Research storage", "hermes", {"via": "jev", "tier": "agent"})
            with mock.patch.multiple(bridge, JOBS=None, JOBS_DB=str(root / "jobs.db"), VAULT=str(root), KEY=""), \
                    mock.patch.object(bridge, "log_talk") as log:
                bridge.job_store()
        self.assertEqual(log.call_args.args[0], "Research storage")
        self.assertIn("Bridge restarted", log.call_args.args[1]["answer"])
        self.assertEqual(log.call_args.args[1]["agent"], "hermes")


class TalkLogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name, leaf in (("LOG_DIR", "talk"), ("TALK_SPOOL", "spool.jsonl")):
            patch = mock.patch.object(bridge, name, str(self.root / leaf))
            patch.start()
            self.addCleanup(patch.stop)

    def said(self, text, **res):
        bridge.log_talk(text, {"answer": "An answer.", "sources": [], **res})

    def log(self):
        return next((self.root / "talk").glob("Talk *.md")).read_text()

    def test_entry_names_the_model_and_depth_that_answered(self):
        deep = {"tier": "answer", "via": "jev", "depth": "deep", "probabilities": {"answer": 0.9}}
        self.said("Compare the hosts", route=deep, model="claude-opus-5-5", depth="deep")
        self.said("Compare them again", route=deep, model="codex (gpt)", depth="light")
        self.said("Anyone there?", route={"tier": "answer"}, model=None, depth="light")
        self.said("Research storage", route={"tier": "agent", "via": "jev"}, agent="hermes")
        self.said("hi hermes", route={"tier": "hermes", "via": "direct"})
        heads = [line.split(" · ")[1:] for line in self.log().splitlines() if line.startswith("### ")]
        self.assertEqual(heads, [["answer (0.90 via jev)", "claude-opus-5-5", "deep"],
                                 ["answer (0.90 via jev)", "codex (gpt)", "light (deep requested)"],
                                 ["answer", "no model", "light"],
                                 ["agent", "hermes"],
                                 ["hermes"]])

    def test_refused_write_is_held_and_written_with_the_next_entry(self):
        (self.root / "blocker").write_text("")
        with mock.patch.object(bridge, "LOG_DIR", str(self.root / "blocker" / "talk")), \
                mock.patch("builtins.print") as printed:
            self.said("first question", route={"tier": "answer"})
        self.assertIn("talk log write failed", printed.call_args.args[0])
        self.assertTrue(Path(bridge.TALK_SPOOL).is_file())
        self.said("second question", route={"tier": "answer"})
        text = self.log()
        self.assertLess(text.index("first question"), text.index("second question"))
        self.assertFalse(Path(bridge.TALK_SPOOL).exists())

    def test_held_entries_are_written_at_startup(self):
        held = {"day": "2026-10-01", "entry": "\n### 09:00 · answer\n- **you:** earlier\n"}
        Path(bridge.TALK_SPOOL).write_text(json.dumps(held) + "\nnot json\n")
        bridge.flush_talk()
        self.assertIn("earlier", (self.root / "talk" / "Talk 2026-10-01.md").read_text())
        self.assertFalse(Path(bridge.TALK_SPOOL).exists())


class RequestValidationTests(unittest.TestCase):
    def post(self, payload):
        handler = bridge.H.__new__(bridge.H)
        raw = json.dumps(payload).encode()
        handler.path = "/bridge/talk"
        handler.headers = {"content-length": str(len(raw))}
        handler.rfile = io.BytesIO(raw)
        handler._j = mock.Mock()
        handler.do_POST()
        return handler._j.call_args.args

    def test_invalid_payloads_are_client_errors_and_never_run(self):
        for payload in ([], "text", None, {"text": 42}, {"text": "work", "target": "unknown"}):
            with self.subTest(payload=payload), mock.patch.object(bridge, "talk") as talk:
                status, response = self.post(payload)
                self.assertEqual(status, 400)
                self.assertIn("error", response)
                talk.assert_not_called()


class AnswerTierTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.object(bridge, "retrieve", return_value=([], "", []))
        patch.start()
        self.addCleanup(patch.stop)

    def answer(self, depth, **patches):
        mocks = {"run_claude_answer": mock.Mock(return_value=patches.get("claude_text")),
                 "run_codex_answer": mock.Mock(return_value=patches.get("codex_text"))}
        with mock.patch.multiple(bridge,
                                 claude_ready=mock.Mock(return_value=patches.get("claude", False)),
                                 codex_ready=mock.Mock(return_value=patches.get("codex", False)),
                                 KEY=patches.get("key", "test-key"), **mocks):
            result = bridge.answer("A question", depth)
        return result, mocks

    def test_deep_uses_claude_when_logged_in(self):
        result, m = self.answer("deep", claude=True, claude_text="Deep thoughts.", codex=True, codex_text="Quick.")
        self.assertEqual((result["answer"], result["model"], result["depth"]),
                         ("Deep thoughts.", bridge.CLAUDE_MODEL, "deep"))
        m["run_codex_answer"].assert_not_called()

    def test_deep_degrades_to_light_when_claude_is_unavailable(self):
        result, m = self.answer("deep", claude=False, codex=True, codex_text="Quick.")
        self.assertEqual((result["answer"], result["depth"]), ("Quick.", "light"))

    def test_deep_degrades_past_a_failed_claude_call(self):
        result, m = self.answer("deep", claude=True, claude_text=None, codex=True, codex_text="Quick.")
        self.assertEqual((result["answer"], result["depth"]), ("Quick.", "light"))

    def test_light_uses_codex_and_never_touches_claude(self):
        result, m = self.answer("light", claude=True, codex=True, codex_text="Quick.")
        self.assertEqual(result["answer"], "Quick.")
        m["run_claude_answer"].assert_not_called()

    def test_minimax_is_the_floor(self):
        payload = {"choices": [{"message": {"content": "MiniMax says."}}]}
        off = mock.Mock(return_value=False)
        with mock.patch.multiple(bridge, claude_ready=off, codex_ready=off, KEY="test-key"), \
                mock.patch.object(bridge, "post_json", return_value=payload) as post:
            result = bridge.answer("A question", "deep")
        self.assertEqual((result["answer"], result["model"]), ("MiniMax says.", bridge.MODEL))
        self.assertEqual(post.call_args.args[1]["model"], bridge.MODEL)

    def test_no_models_at_all_still_names_notes(self):
        note = {"id": "Backups", "path": "Resources/Backups.md", "title": "Backups", "body": "Backup notes."}
        off = mock.Mock(return_value=False)
        with mock.patch.object(bridge, "retrieve", return_value=([note], "", [])), \
                mock.patch.multiple(bridge, claude_ready=off, codex_ready=off, KEY=""):
            result = bridge.answer("A question", "light")
        self.assertIn("Backups", result["answer"])
        self.assertIsNone(result["model"])


class HermesChatTests(unittest.TestCase):
    def post(self, payload):
        handler = bridge.H.__new__(bridge.H)
        raw = json.dumps(payload).encode()
        handler.path = "/bridge/hermes"
        handler.headers = {"content-length": str(len(raw))}
        handler.rfile = io.BytesIO(raw)
        handler._j = mock.Mock()
        handler.do_POST()
        return handler._j.call_args.args

    def test_chat_uses_a_persistent_sanitized_conversation(self):
        with mock.patch.object(bridge, "HERMES_KEY", "key"), \
                mock.patch.object(bridge, "hermes_chat", return_value="Hello.") as chat, \
                mock.patch.object(bridge, "log_talk"):
            status, response = self.post({"text": "hi hermes", "conversation": "abc 123!<script>"})
        self.assertEqual(status, 200)
        self.assertEqual(response["answer"], "Hello.")
        self.assertEqual(chat.call_args.args, ("hi hermes", "abc123script"))
        self.assertEqual(response["conversation"], "abc123script")

    def test_chat_requires_hermes_and_text(self):
        with mock.patch.object(bridge, "HERMES_KEY", ""):
            status, _ = self.post({"text": "hi"})
            self.assertEqual(status, 503)
        with mock.patch.object(bridge, "HERMES_KEY", "key"):
            status, _ = self.post({"text": "  "})
            self.assertEqual(status, 400)
            status, _ = self.post({"notext": True})
            self.assertEqual(status, 400)

    def test_empty_hermes_reply_is_a_bad_gateway(self):
        with mock.patch.object(bridge, "HERMES_KEY", "key"), \
                mock.patch.object(bridge, "hermes_chat", return_value=""):
            status, response = self.post({"text": "hi"})
        self.assertEqual(status, 502)
        self.assertIn("error", response)


class ReportTitlerTests(unittest.TestCase):
    def test_minimax_title_and_tags_shape_the_report(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            titler = mock.Mock(return_value={"title": "Backup strategy review", "tags": ["backups", "Storage!!", "x"]})
            store = JobStore(root / "jobs.db", root, titler=titler)
            job = store.create("Review backups", "codex", {"via": "jev"})
            job.update(status="done", answer="Findings.")
            store.finish(job)
            saved = store.get(job["id"])
            self.assertTrue(saved["report"].startswith("Resources/Reports/Backup strategy review ("))
            text = (root / saved["report"]).read_text()
            self.assertIn("# Backup strategy review", text)
            self.assertIn("tags: [backups, x]", text)

    def test_a_failing_titler_falls_back_to_the_template(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            store = JobStore(root / "jobs.db", root, titler=mock.Mock(side_effect=RuntimeError("MiniMax down")))
            job = store.create("Review backups", "codex", {"via": "jev"})
            job.update(status="done", answer="Findings.")
            store.finish(job)
            saved = store.get(job["id"])
            self.assertIn("Agent report", saved["report"])
            self.assertIn("tags: [agents, report]", (root / saved["report"]).read_text())


if __name__ == "__main__":
    unittest.main()
