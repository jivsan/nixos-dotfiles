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


LIVE_STATE = bridge.live_state   # the real one, for the tests about it


def setUpModule():
    # This suite also runs on heimdall: keep it out of the live talk log, spool and Pulse counters.
    scratch = tempfile.TemporaryDirectory()
    unittest.addModuleCleanup(scratch.cleanup)
    values = [(name, str(Path(scratch.name) / leaf))
              for name, leaf in (("LOG_DIR", "talk"), ("TALK_SPOOL", "talk-spool.jsonl"), ("STATS_FILE", "stats.json"))]
    # Answers never probe the real systems here, and worker commands are the same on every host.
    values += [("live_state", lambda: ""), ("NO_NEW_PRIVS", []), ("hermes_up", lambda: True)]
    for name, value in values:
        patch = mock.patch.object(bridge, name, value)
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

    def test_jev_uses_separate_key_and_is_asked_what_the_task_needs(self):
        response = {"answers": {"tier": jev_choice("agent"), "executor": jev_choice("codex", 0.8),
                                "needs_web": {"type": "noul", "noul": 0.04}, "changes_vault": {"type": "noul", "noul": 0.91},
                                "deep_research": {"type": "noul", "noul": "high"}}}
        with mock.patch.object(bridge, "JEV_KEY", "router-key"), \
                mock.patch.object(bridge, "post_json", return_value=response) as post:
            result = bridge.route_jev("Cross the backup item off my list")
        self.assertEqual(result["executor"], "codex")
        self.assertEqual(result["needs"], {"web": 0.04, "writes": 0.91})   # an unusable answer is no answer
        self.assertNotIn("settled", result)
        self.assertEqual(post.call_args.kwargs["key"], "router-key")
        # who is connected is the bridge's business: Jev only reads the request
        self.assertEqual(post.call_args.args[1]["state"], {"request": "Cross the backup item off my list"})
        asked = post.call_args.args[1]["questions"]
        self.assertEqual({asked[name]["type"] for name in ("needs_web", "changes_vault", "deep_research")}, {"noul"})

    def test_unsure_tier_is_settled_by_what_the_task_needs(self):
        def route(web, writes, tier=("answer", 0.45)):
            nouls = {name: {"type": "noul", "noul": value} for name, value in
                     (("needs_web", web), ("changes_vault", writes)) if value is not None}
            response = {"answers": {"tier": jev_choice(*tier), "depth": jev_choice("light"),
                                    "executor": jev_choice("hermes", 0.3), **nouls}}
            with mock.patch.object(bridge, "JEV_KEY", "test"), mock.patch.object(bridge, "post_json", return_value=response):
                return bridge.route_jev("What are my todos? Make a priority list.")
        # nothing to look up online, nothing to change: it is a question about her notes
        asked = route(0.1, 0.2)
        self.assertEqual((asked["via"], asked["tier"], asked["depth"]), ("jev", "answer", "light"))
        self.assertIn("unsure (answer 0.45)", asked["settled"]["tier"])
        for web, writes in ((0.9, 0.1), (0.1, 0.8)):
            with self.subTest(web=web, writes=writes):
                self.assertEqual(route(web, writes)["tier"], "agent")
        # without those answers, or when it is a command Jev is unsure of, the rules decide
        self.assertEqual(route(None, 0.2)["error"], "uncertain Jev tier choice")
        self.assertEqual(route(0.1, 0.2, ("command", 0.4))["error"], "uncertain Jev tier choice")

    def test_deep_research_reaches_claude_on_either_signal(self):
        def executor(choice, deep):
            response = {"answers": {"tier": jev_choice("agent"), "executor": choice,
                                    "deep_research": {"type": "noul", "noul": deep}}}
            with mock.patch.object(bridge, "JEV_KEY", "test"), mock.patch.object(bridge, "post_json", return_value=response):
                return bridge.route_jev("Research local models and think hard about it")["executor"]
        self.assertEqual(executor(jev_choice("hermes", 0.4), 0.85), "claude")   # torn on the worker, sure it is deep
        self.assertEqual(executor(jev_choice("claude", 0.8), 0.2), "claude")
        self.assertIsNone(executor(jev_choice("claude", 0.6), 0.6))             # half-sure both ways: a lighter worker
        self.assertEqual(executor(jev_choice("hermes", 0.9), 0.3), "hermes")

    def test_a_worker_is_matched_to_what_the_task_needs(self):
        everyone = {"hermes": True, "codex": True, "claude": True}

        def worker(executor=None, have=everyone, tried=(), **needs):
            return bridge.delegate({"executor": executor, "needs": needs}, have, tried)
        self.assertEqual(worker("codex", web=0.9), "hermes")                 # codex has no internet, whatever Jev preferred
        self.assertEqual(worker("hermes", writes=0.9, web=0.1), "codex")     # a pure vault change is done in the vault
        self.assertEqual(worker("codex", web=0.8, writes=0.8), "hermes")     # only hermes does both
        self.assertEqual(worker("codex"), "codex")                           # nothing rules it out: Jev's pick
        self.assertEqual(worker(), "hermes")
        self.assertEqual(worker("claude", web=0.9), "claude")
        self.assertEqual(worker("claude", web=0.9, writes=0.9), "hermes")    # Claude changes nothing in the vault
        self.assertEqual(worker("claude", have={**everyone, "claude": False}, web=0.9), "hermes")
        self.assertEqual(worker(have={**everyone, "hermes": False}, web=0.9), "codex")   # nobody fits: the best there is
        self.assertEqual(worker(tried={"hermes"}, web=0.9), "codex")
        self.assertIsNone(worker(have={"hermes": False, "codex": False, "claude": True}))
        self.assertIsNone(worker(tried={"hermes", "codex"}))

    def test_rules_say_what_a_task_needs_when_jev_cannot(self):
        for text, web, writes, executor in (
                ("Research the latest NixOS release", 1.0, 0.0, None),
                ("Please add the backup disk to my todo list", 0.0, 1.0, None),
                ("Fix the broken notes", 0.0, 0.0, None),
                ("Research local models for me and think hard about it", 1.0, 0.0, "claude")):
            with self.subTest(text=text):
                route = bridge.route_rules(text)
                self.assertEqual((route["needs"]["web"], route["needs"]["writes"], route["executor"]), (web, writes, executor))

    def test_the_reason_for_a_worker_is_recorded(self):
        response = {"answers": {"tier": jev_choice("agent"), "executor": jev_choice("codex"),
                                "needs_web": {"type": "noul", "noul": 0.93}, "changes_vault": {"type": "noul", "noul": 0.1}}}
        with mock.patch.object(bridge, "JEV_KEY", "test"), mock.patch.object(bridge, "post_json", return_value=response), \
                mock.patch.object(bridge, "available_agents", return_value={"hermes": True, "codex": True, "claude": True}), \
                mock.patch.object(bridge, "start_agent", return_value={"id": "job"}) as start:
            result = bridge.talk("Find out what changed in the newest llama.cpp")
        self.assertEqual(start.call_args.args[1], "hermes")
        route = result["route"]
        self.assertEqual((route["selected_executor"], route["selected_because"]), ("hermes", "needs the web"))
        self.assertEqual(route["executor_fallback"], "Jev picked codex; hermes took it instead.")

    def test_preview_decides_without_doing_anything(self):
        response = {"answers": {"tier": jev_choice("agent"), "executor": jev_choice("codex"),
                                "changes_vault": {"type": "noul", "noul": 0.9}, "needs_web": {"type": "noul", "noul": 0.1}}}
        with mock.patch.object(bridge, "JEV_KEY", "test"), mock.patch.object(bridge, "post_json", return_value=response), \
                mock.patch.object(bridge, "available_agents", return_value={"hermes": True, "codex": True, "claude": True}), \
                mock.patch.object(bridge, "start_agent") as start, mock.patch.object(bridge, "answer") as answer, \
                mock.patch.object(bridge, "log_talk") as log, mock.patch.object(bridge, "record_stats") as stats:
            seen = bridge.preview("Cross the backup item off my list")
            by_hand = bridge.preview("Cross the backup item off my list", "hermes")
        for untouched in (start, answer, log, stats):
            untouched.assert_not_called()
        self.assertEqual((seen["worker"], seen["route"]["selected_because"]), ("codex", "changes the vault"))
        self.assertEqual((by_hand["worker"], by_hand["route"]["selected_because"]), ("hermes", "picked by hand"))
        answered = {"answers": {"tier": jev_choice("answer"), "depth": jev_choice("deep")}}
        with mock.patch.object(bridge, "JEV_KEY", "test"), mock.patch.object(bridge, "post_json", return_value=answered), \
                mock.patch.multiple(bridge, claude_ready=mock.Mock(return_value=True), codex_ready=mock.Mock(return_value=True)):
            self.assertEqual(bridge.preview("Compare my backup options")["answered_by"], bridge.CLAUDE_MODEL)

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

    def test_answer_without_a_usable_depth_is_answered_light(self):
        for depth in (None, {"choice": "profound", "confidence": 0.9}, jev_choice("deep", 0.3)):
            response = {"answers": {"tier": jev_choice("answer"), **({"depth": depth} if depth else {})}}
            with self.subTest(depth=depth), mock.patch.object(bridge, "JEV_KEY", "test"), \
                    mock.patch.object(bridge, "post_json", return_value=response):
                route = bridge.route_jev("What is in my vault?")
                # the tier Jev was sure of is kept; only the depth falls back
                self.assertEqual((route["via"], route["tier"], route["depth"]), ("jev", "answer", "light"))

    def test_rules_depth_heuristic(self):
        self.assertEqual(bridge.route_rules("How do I write a note?")["depth"], "light")
        self.assertEqual(bridge.route_rules("Compare my backup options and explain the tradeoffs")["depth"], "deep")
        self.assertEqual(bridge.route_rules("open memory")["depth"], None)
        self.assertEqual(bridge.route_rules("What are the trade-offs of ZFS?")["depth"], "deep")
        # light is the default: a long question is not a deep one
        self.assertEqual(bridge.route_rules("Tell me " + "a lot " * 60 + "about my notes?")["depth"], "light")

    def test_half_sure_deep_choices_take_the_light_path(self):
        deep = {"answers": {"tier": jev_choice("answer"), "depth": jev_choice("deep", 0.6)}}
        research = {"answers": {"tier": jev_choice("agent"), "executor": jev_choice("claude", 0.6)}}
        with mock.patch.object(bridge, "JEV_KEY", "test"):
            with mock.patch.object(bridge, "post_json", return_value=deep):
                self.assertEqual(bridge.route_jev("Tell me about my backups")["depth"], "light")
            with mock.patch.object(bridge, "post_json", return_value=research):
                self.assertIsNone(bridge.route_jev("Look into backups")["executor"])

    def test_sure_deep_research_goes_to_claude(self):
        response = {"answers": {"tier": jev_choice("agent"), "executor": jev_choice("claude")}}
        everyone = {"hermes": True, "codex": True, "claude": True}
        with mock.patch.object(bridge, "JEV_KEY", "test"), \
                mock.patch.object(bridge, "post_json", return_value=response), \
                mock.patch.object(bridge, "available_agents", return_value=everyone), \
                mock.patch.object(bridge, "start_agent", return_value={"id": "job"}) as start:
            bridge.talk("Do deep research on ZFS tuning")
        self.assertEqual(start.call_args.args[1], "claude")

    def test_rules_send_only_deep_research_to_claude(self):
        self.assertEqual(bridge.route_rules("Do deep research on ZFS tuning and write a report")["executor"], "claude")
        self.assertEqual(bridge.route_rules("Research ZFS tuning thoroughly")["executor"], "claude")
        self.assertIsNone(bridge.route_rules("Research backup strategies")["executor"])
        self.assertIsNone(bridge.route_rules("Write a summary document")["executor"])

    def test_claude_is_never_a_fallback_worker(self):
        everyone = {"hermes": True, "codex": True, "claude": True}
        with mock.patch.object(bridge, "available_agents", return_value=everyone):
            self.assertEqual(bridge.pick_agent("auto"), "hermes")
            self.assertEqual(bridge.pick_agent("auto", "claude"), "claude")
            self.assertEqual(bridge.pick_agent("claude"), "claude")
        with mock.patch.object(bridge, "available_agents", return_value={**everyone, "claude": False}):
            self.assertEqual(bridge.pick_agent("auto", "claude"), "hermes")
            self.assertIsNone(bridge.pick_agent("claude"))
        with mock.patch.object(bridge, "available_agents", return_value={"hermes": False, "codex": False, "claude": True}):
            self.assertIsNone(bridge.pick_agent("auto"))

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

    def test_uncertain_executor_costs_only_the_worker_choice(self):
        for executor in (jev_choice("codex", 0.1), {"choice": "nobody", "confidence": 0.9}, None):
            response = {"answers": {"tier": jev_choice("agent"), **({"executor": executor} if executor else {})}}
            with self.subTest(executor=executor), mock.patch.object(bridge, "JEV_KEY", "test"), \
                    mock.patch.object(bridge, "post_json", return_value=response), \
                    mock.patch.object(bridge, "available_agents", return_value={"hermes": True, "codex": True}), \
                    mock.patch.object(bridge, "route_rules", wraps=bridge.route_rules) as rules, \
                    mock.patch.object(bridge, "start_agent", return_value={"id": "new-job"}) as start:
                result = bridge.talk("Research storage")
            rules.assert_not_called()   # Jev was sure it is agent work: that stands
            self.assertEqual(start.call_args.args[1], "hermes")
            route = start.call_args.args[2]
            self.assertEqual((route["via"], route["executor"], route["selected_because"]), ("jev", None, "default worker"))
            self.assertIn("chosen by what the task needs", route["settled"]["executor"])
            self.assertNotIn("jev_error", result)


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
            # the gateway user cannot enter /home/christina: hermes gets the path it can reach
            self.assertIn("vault (her second brain) is at /mnt/muninn ", body["input"])
            self.assertNotIn("/home/christina", body["input"])
        with mock.patch.object(bridge, "post_json", return_value=response) as post:
            bridge.hermes_chat("hi", "a-fresh-conversation")
        self.assertIn("vault is at /mnt/muninn ", post.call_args.args[1]["input"])

    def test_empty_hermes_output_fails(self):
        job = {"id": "empty", "text": "Research backups", "agent": "hermes"}
        with mock.patch.object(bridge, "post_json", return_value={"output": []}):
            bridge.run_hermes(job)
        self.assertEqual(job["status"], "failed")
        self.assertTrue(job["answer"])

    def test_claude_research_is_read_only_and_confined_to_the_vault(self):
        job = {"id": "research", "text": "Research ZFS tuning", "agent": "claude"}
        done = mock.Mock(returncode=0, stdout="A cited report.\n", stderr="")
        with mock.patch.object(bridge.subprocess, "run", return_value=done) as run:
            bridge.run_claude(job)
        command = run.call_args.args[0]
        self.assertEqual((job["status"], job["answer"]), ("done", "A cited report."))
        self.assertIn("Research ZFS tuning", command[2])
        self.assertIn("--restricted", command)
        self.assertEqual(command[command.index("--tools") + 1], bridge.RESEARCH_TOOLS)
        self.assertFalse({"Bash", "Write", "Edit"} & set(bridge.RESEARCH_TOOLS.split(",")))
        self.assertEqual(command[command.index("--model") + 1], bridge.CLAUDE_MODEL)
        self.assertEqual(run.call_args.kwargs["cwd"], bridge.VAULT)

    def test_failed_claude_research_fails_the_job(self):
        job = {"id": "research", "text": "Research ZFS tuning", "agent": "claude"}
        refused = mock.Mock(returncode=1, stdout="", stderr="usage limit reached")
        with mock.patch.object(bridge.subprocess, "run", return_value=refused):
            bridge.run_claude(job)
        self.assertEqual((job["status"], job["answer"]), ("failed", "usage limit reached"))
        with mock.patch.object(bridge.subprocess, "run", side_effect=bridge.subprocess.TimeoutExpired("claude", 1500)):
            bridge.run_claude(job)
        self.assertIn("out of time", job["answer"])

    def test_no_worker_on_this_host_can_reach_sudo(self):
        guard = ["/bin/setpriv", "--no-new-privs"]
        done = mock.Mock(returncode=0, stdout="Done.", stderr="")
        runs = {"run_claude": (bridge.CLAUDE, lambda: bridge.run_claude({"id": "j", "text": "Research", "agent": "claude"})),
                "run_codex": (bridge.CODEX, lambda: bridge.run_codex({"id": "j", "text": "Tidy", "agent": "codex"})),
                "run_claude_answer": (bridge.CLAUDE, lambda: bridge.run_claude_answer("A question")),
                "run_codex_answer": (bridge.CODEX, lambda: bridge.run_codex_answer("A question"))}
        for name, (program, start) in runs.items():
            with self.subTest(worker=name), mock.patch.object(bridge, "NO_NEW_PRIVS", guard), \
                    mock.patch.object(bridge.subprocess, "run", return_value=done) as run:
                start()
                self.assertEqual(run.call_args.args[0][:3], guard + [program])


class BridgeJobIntegrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.store = JobStore(root / "jobs.db", root, max_active=1)
        self.route = {"via": "jev", "tier": "agent", "executor": "hermes"}
        # no key, no outcome check: only the tests about it ask Jev
        for patch in (mock.patch.object(bridge, "job_store", return_value=self.store),
                      mock.patch.object(bridge, "JEV_KEY", "")):
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

    def test_claude_jobs_run_the_research_worker(self):
        job = self.store.create("Research storage", "claude", self.route)
        with mock.patch.object(bridge, "run_claude", side_effect=lambda j: j.update(status="done", answer="Report.")) as research, \
                mock.patch.object(bridge, "run_codex") as codex, \
                mock.patch.object(bridge, "log_talk") as log:
            bridge.run_agent(job)
        research.assert_called_once()
        codex.assert_not_called()
        self.assertEqual(self.store.get(job["id"])["status"], "done")
        self.assertEqual(log.call_args.args[1]["agent"], "claude")

    def test_claude_out_of_quota_hands_the_job_to_a_lighter_worker(self):
        job = self.store.create("Research storage", "claude", self.route)
        limit = "You've hit your session limit · resets 10:50pm (Europe/Oslo)"
        with mock.patch.object(bridge, "run_claude", side_effect=lambda j: j.update(status="failed", answer=limit)), \
                mock.patch.object(bridge, "available_agents", return_value={"hermes": True, "codex": True, "claude": True}), \
                mock.patch.object(bridge, "run_hermes", side_effect=lambda j: j.update(status="done", answer="Report.")) as hermes, \
                mock.patch.object(bridge, "log_talk") as log:
            bridge.run_agent(job)
        hermes.assert_called_once()
        saved = self.store.get(job["id"])
        self.assertEqual((saved["agent"], saved["status"], saved["answer"]), ("hermes", "done", "Report."))
        self.assertIn("session limit", saved["route"]["executor_fallback"])
        self.assertEqual(log.call_args.args[1]["agent"], "hermes")

    def test_other_claude_failures_are_not_retried_elsewhere(self):
        job = self.store.create("Research storage", "claude", self.route)
        with mock.patch.object(bridge, "run_claude", side_effect=lambda j: j.update(status="failed", answer="Claude ran out of time (25 minutes).")), \
                mock.patch.object(bridge, "run_hermes") as hermes, mock.patch.object(bridge, "log_talk"):
            bridge.run_agent(job)
        hermes.assert_not_called()
        self.assertEqual(self.store.get(job["id"])["agent"], "claude")

    def test_worker_that_only_explains_why_it_could_not_is_replaced(self):
        job = self.store.create("What are my todos?", "hermes", self.route)
        excuse = "I can't access the vault from this session, so I can't verify your tasks."
        verdicts = [{"answers": {"gave_up": {"type": "noul", "noul": 0.97}}},
                    {"answers": {"gave_up": {"type": "noul", "noul": 0.02}}}]
        with mock.patch.object(bridge, "JEV_KEY", "jev-key"), \
                mock.patch.object(bridge, "post_json", side_effect=verdicts) as post, \
                mock.patch.object(bridge, "available_agents", return_value={"hermes": True, "codex": True, "claude": True}), \
                mock.patch.object(bridge, "run_hermes", side_effect=lambda j: j.update(status="done", answer=excuse)) as hermes, \
                mock.patch.object(bridge, "run_codex", side_effect=lambda j: j.update(status="done", answer="Three open todos.")), \
                mock.patch.object(bridge, "run_claude") as claude, \
                mock.patch.object(bridge, "log_talk"):
            bridge.run_agent(job)
        hermes.assert_called_once()
        claude.assert_not_called()
        saved = self.store.get(job["id"])
        self.assertEqual((saved["agent"], saved["status"], saved["answer"]), ("codex", "done", "Three open todos."))
        self.assertIn("can't access the vault", saved["route"]["executor_fallback"])
        self.assertEqual(saved["route"]["outcome"], {"worker": "codex", "gave_up": 0.02})
        asked = post.call_args_list[0]
        self.assertEqual(asked.args[1]["state"], {"request": "What are my todos?", "result": excuse})
        self.assertEqual(asked.args[1]["questions"]["gave_up"]["type"], "noul")
        self.assertEqual(asked.kwargs["key"], "jev-key")

    def test_job_goes_to_another_worker_when_hermes_is_unreachable(self):
        job = self.store.create("Tidy the backup notes", "hermes", self.route)
        with mock.patch.object(bridge, "hermes_up", return_value=False), \
                mock.patch.object(bridge, "post_json") as post, \
                mock.patch.object(bridge, "available_agents", return_value={"hermes": True, "codex": True, "claude": True}), \
                mock.patch.object(bridge, "run_codex", side_effect=lambda j: j.update(status="done", answer="Tidied.")) as codex, \
                mock.patch.object(bridge, "run_claude") as claude, mock.patch.object(bridge, "log_talk"):
            bridge.run_agent(job)
        post.assert_not_called()     # the job was never sent: nothing can have run twice
        claude.assert_not_called()
        codex.assert_called_once()
        saved = self.store.get(job["id"])
        self.assertEqual((saved["agent"], saved["status"], saved["answer"]), ("codex", "done", "Tidied."))
        self.assertIn("hermes could not start (Hermes is not reachable", saved["route"]["executor_fallback"])
        self.assertNotIn("unstarted", saved)

    def test_handover_respects_what_the_task_needs(self):
        # the job needs the web and hermes is gone: codex is still the best there is, and is tried once
        route = {**self.route, "needs": {"web": 0.9, "writes": 0.1}}
        job = self.store.create("What changed in the newest llama.cpp?", "hermes", route)
        with mock.patch.object(bridge, "hermes_up", return_value=False), \
                mock.patch.object(bridge, "available_agents", return_value={"hermes": True, "codex": True, "claude": True}), \
                mock.patch.object(bridge, "run_codex", side_effect=lambda j: j.update(status="failed", answer="Codex ran out of time (25 minutes).")) as codex, \
                mock.patch.object(bridge, "run_claude") as claude, mock.patch.object(bridge, "log_talk"):
            bridge.run_agent(job)
        codex.assert_called_once()
        claude.assert_not_called()   # never a fallback, even though it has the web
        self.assertEqual(self.store.get(job["id"])["status"], "failed")

    def test_job_nobody_could_do_is_filed_as_failed_with_the_reason(self):
        job = self.store.create("What are my todos?", "hermes", self.route)
        with mock.patch.object(bridge, "JEV_KEY", "jev-key"), \
                mock.patch.object(bridge, "post_json", return_value={"answers": {"gave_up": {"type": "noul", "noul": 0.97}}}), \
                mock.patch.object(bridge, "available_agents", return_value={"hermes": True, "codex": False, "claude": True}), \
                mock.patch.object(bridge, "run_hermes", side_effect=lambda j: j.update(status="done", answer="No vault access.")) as hermes, \
                mock.patch.object(bridge, "log_talk"):
            bridge.run_agent(job)
        hermes.assert_called_once()
        saved = self.store.get(job["id"])
        self.assertEqual((saved["agent"], saved["status"], saved["answer"]), ("hermes", "failed", "No vault access."))
        self.assertEqual(saved["route"]["outcome"], {"worker": "hermes", "gave_up": 0.97})
        self.assertIn("status: failed", (self.store.vault / saved["report"]).read_text())

    def test_done_job_stands_when_jev_is_unsure_or_silent(self):
        answers = ({"answers": {"gave_up": {"type": "noul", "noul": 0.6}}}, TimeoutError("timed out"),
                   {"answers": {"gave_up": {"type": "noul", "noul": True}}}, {"answers": {}})
        for answer in answers:
            job = self.store.create("Research storage", "hermes", self.route)
            with self.subTest(answer=answer), mock.patch.object(bridge, "JEV_KEY", "jev-key"), \
                    mock.patch.object(bridge, "post_json", side_effect=[answer]), \
                    mock.patch.object(bridge, "available_agents", return_value={"hermes": True, "codex": True, "claude": True}), \
                    mock.patch.object(bridge, "run_hermes", side_effect=lambda j: j.update(status="done", answer="Report.")), \
                    mock.patch.object(bridge, "run_codex") as codex, mock.patch.object(bridge, "log_talk"):
                bridge.run_agent(job)
            codex.assert_not_called()
            saved = self.store.get(job["id"])
            self.assertEqual((saved["agent"], saved["status"]), ("hermes", "done"))
            self.assertEqual(saved["route"].get("outcome"),
                             {"worker": "hermes", "gave_up": 0.6} if answer is answers[0] else None)

    def test_finished_job_gets_its_own_vault_commit(self):
        git = ["git", "-C", str(self.store.vault)]
        try:
            bridge.subprocess.run(git + ["init", "-q"], check=True, capture_output=True)
        except (OSError, bridge.subprocess.CalledProcessError):
            self.skipTest("git is not available")
        job = self.store.create("Research storage", "hermes", self.route)
        with mock.patch.object(bridge, "run_hermes", side_effect=lambda j: j.update(status="done", answer="Report.")), \
                mock.patch.object(bridge, "log_talk"):
            bridge.run_agent(job)
        log = bridge.subprocess.run(git + ["log", "--format=%an|%s", "--name-only"], capture_output=True, text=True).stdout
        self.assertIn("muninn-bridge|hermes: Agent report", log)
        self.assertIn(self.store.get(job["id"])["report"], log)

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


class HealthTests(unittest.TestCase):
    def test_embed_up_probes_the_question_instance(self):
        with mock.patch.object(bridge.urllib.request, "urlopen") as urlopen:
            urlopen.return_value.__enter__.return_value.status = 200
            self.assertTrue(bridge.embed_up())
            self.assertEqual(urlopen.call_args.args[0], bridge.embed.QUERY_URL + "/health")
            self.assertEqual(urlopen.call_args.kwargs["timeout"], 1.5)
            urlopen.return_value.__enter__.return_value.status = 503
            self.assertFalse(bridge.embed_up())
            urlopen.side_effect = OSError("mimir down")
            self.assertFalse(bridge.embed_up())


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

    def test_minimax_related_notes_replace_the_retrieved_sources(self):
        hits = [{"id": "Test Capture"}]
        self.said("How is hermod set up?", route={"tier": "answer"}, sources=hits, related=["hermod", "Backups"])
        self.said("Hello, this is a test", route={"tier": "answer"}, sources=hits, related=[])
        self.said("Anyone there?", route={"tier": "answer"}, sources=hits)
        log = self.log()
        self.assertIn("- related: [[hermod]] [[Backups]]\n", log)
        self.assertEqual(log.count("- related:"), 1)   # nothing related: no links at all
        self.assertEqual(log.count("- sources: [[Test Capture]]"), 1)   # MiniMax not asked: the hits stand in

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

    def test_claude_can_be_addressed_by_name(self):
        with mock.patch.object(bridge, "talk", return_value={"answer": "On it."}) as talk:
            status, _ = self.post({"text": "Research storage", "target": "claude"})
        self.assertEqual(status, 200)
        talk.assert_called_once_with("Research storage", "claude")


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

    def test_live_state_is_part_of_what_the_model_is_given(self):
        with mock.patch.object(bridge, "live_state", return_value="Failed systemd units on heimdall: none"):
            _, m = self.answer("light", codex=True, codex_text="All quiet.")
        prompt = m["run_codex_answer"].call_args.args[0]
        self.assertIn("--- live state ---\nFailed systemd units on heimdall: none", prompt)
        self.assertIn("General knowledge, not from your notes:", prompt)

    def test_general_knowledge_answer_does_not_cite_her_notes(self):
        note = {"id": "Backups", "path": "Resources/Backups.md", "title": "Backups", "body": "Backup notes."}
        for text, cited in (("General knowledge, not from your notes: an embedding is a vector.", []),
                            ("Your Backups note says nightly.", [{"id": "Backups", "path": "Resources/Backups.md", "title": "Backups"}])):
            with self.subTest(text=text), mock.patch.object(bridge, "retrieve", return_value=([note], "", ["heimdall"])):
                result, _ = self.answer("light", codex=True, codex_text=text)
                self.assertEqual(result["sources"], cited)
                self.assertEqual(result["code_nodes"], ["heimdall"] if cited else [])


class LiveStateTests(unittest.TestCase):
    def state(self, activity, **patches):
        with tempfile.TemporaryDirectory() as d:
            feed = Path(d) / "activity.json"
            if activity is not None:
                feed.write_text(json.dumps(activity))
            units = mock.Mock(stdout=patches.get("failed", ""), returncode=0)
            with mock.patch.object(bridge, "ACTIVITY_FILE", str(feed)), \
                    mock.patch.object(bridge.subprocess, "run", return_value=units), \
                    mock.patch.multiple(bridge, voice_up=mock.Mock(return_value=patches.get("voice", True)),
                                        embed_up=mock.Mock(return_value=True),
                                        monitored=mock.Mock(**patches.get("targets", {"return_value": (3, [])})),
                                        available_agents=mock.Mock(return_value={"hermes": True, "codex": False}),
                                        job_store=mock.Mock(return_value=mock.Mock(recent=lambda: [{"status": "running"}, {"status": "done"}])),
                                        usage=mock.Mock(return_value={"openai": {"five_hour": {"used_percent": 12.4}}, "anthropic": None})):
                return LIVE_STATE()

    def test_it_says_what_is_up_and_what_is_not(self):
        now = int(bridge.time.time())
        activity = {"counts": {"notes": 255, "inbox": 2},
                    "agents": [{"name": "inbox-sweep", "last": now - 60, "result": "success", "active": False},
                               {"name": "gardener", "last": 0, "result": "exit-code", "active": False}],
                    "services": [{"name": "nginx", "ok": True}, {"name": "obsidian", "ok": False}],
                    "gitlog": [{"t": now - 120, "msg": "huginn: inbox filing"}]}
        text = self.state(activity, failed="huginn-gardener.service loaded failed failed huginn\n", voice=False,
                          targets={"return_value": (15, ["pfsense"])})
        for line in ("Failed systemd units on heimdall: huginn-gardener.service",
                     "Vault: 255 notes, 2 waiting in the inbox.",
                     "gardener never exit-code", "nginx ok, obsidian DOWN", "huginn: inbox filing",
                     "hermes connected, codex NOT connected. Agent jobs running: 1 of",
                     "Codex 12% of the 5-hour window",
                     "On mimir: voice NOT answering, embedding model up.",
                     "Prometheus: 14 of 15 monitored targets up; DOWN: pfsense."):
            self.assertIn(line, text)

    def test_what_cannot_be_read_is_left_out(self):
        text = self.state(None, targets={"side_effect": OSError("refused")})
        self.assertIn("Failed systemd units on heimdall: none", text)
        self.assertIn("Workers: hermes connected", text)
        for absent in ("Vault:", "Scheduled agents", "Prometheus"):
            self.assertNotIn(absent, text)

    def test_prometheus_names_the_targets_that_are_down(self):
        rows = [{"metric": {"host": "hella", "instance": "10.0.20.10:9100"}, "value": [1, "1"]},
                {"metric": {"host": "pfsense", "instance": "10.0.20.1:9273"}, "value": [1, "0"]},
                {"metric": {"instance": "https://immich.oryxserver.org"}, "value": [1, "0"]}]
        reply = mock.MagicMock()
        reply.__enter__.return_value.read.return_value = json.dumps({"data": {"result": rows}}).encode()
        with mock.patch.object(bridge.urllib.request, "urlopen", return_value=reply):
            self.assertEqual(bridge.monitored(), (3, ["https://immich.oryxserver.org", "pfsense"]))


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


class PlacementTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        for note, text in (("MOCs/Knowledge MOC.md", "---\ntype: moc\n---\n# Knowledge MOC\nHub for filed knowledge.\n"),
                           ("MOCs/TODO MOC.md", "# TODO MOC\nEvery open checkbox in the vault.\n"),
                           ("Areas/hermod.md", "The Hermes VM."), ("Resources/Backups.md", "Backups."),
                           ("Resources/Reports/inbox-1.md", "A sweep report.")):
            (root / note).parent.mkdir(parents=True, exist_ok=True)
            (root / note).write_text(text)
        for name, value in (("VAULT", str(root)), ("KEY", "test-key")):
            patch = mock.patch.object(bridge, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def reply(self, content):
        return mock.patch.object(bridge, "post_json", return_value={"choices": [{"message": {"content": content}}]})

    def test_minimax_chooses_among_the_real_hubs_and_notes(self):
        picked = {"title": "Backup review", "tags": ["backups"], "moc": "Knowledge MOC",
                  "related": ["Backups", "A note nobody wrote", "Backups", "inbox-1"]}
        with self.reply("Here it is:\n```json\n" + json.dumps(picked) + "\n```") as post:
            placed = bridge.place("an agent report", "Request: review backups")
        self.assertEqual(placed, {**picked, "related": ["Backups"]})
        offered = post.call_args.args[1]["messages"][1]["content"]
        self.assertIn("- Knowledge MOC: Hub for filed knowledge.", offered)
        self.assertNotIn("TODO MOC", offered)   # a generated board is not a subject
        for note in ("- hermod", "- Backups"):
            self.assertIn(note, offered)
        self.assertNotIn("inbox-1", offered)

    def test_unknown_hub_is_not_passed_on(self):
        with self.reply(json.dumps({"title": "T", "tags": [], "moc": "TODO MOC", "related": "Backups"})):
            self.assertEqual(bridge.place("an agent report", "x"), {"title": "T", "tags": [], "moc": None, "related": []})

    def test_nothing_is_asked_without_a_key_and_a_bad_reply_falls_back(self):
        with mock.patch.object(bridge, "KEY", ""), mock.patch.object(bridge, "post_json") as post:
            self.assertEqual(bridge.place("a conversation", "hello"), {})
            self.assertIsNone(bridge.report_titler({"text": "x", "answer": "y"}))
        post.assert_not_called()
        with self.reply("I cannot file this."):
            self.assertIsNone(bridge.placing("hello")())
            with self.assertRaises(ValueError):
                bridge.report_titler({"text": "x", "answer": "y"})

    def test_with_the_embedding_index_the_closest_notes_lead_a_short_list(self):
        near = [("Resources/Backups.md", 0.71), ("Areas/gone.md", 0.66), ("Areas/hermod.md", 0.12)]   # last one: not really close
        with mock.patch.object(bridge.embed, "similar", return_value=near) as similar, \
                self.reply(json.dumps({"title": "T", "tags": [], "moc": "Knowledge MOC", "related": ["Backups"]})) as post:
            placed = bridge.place("an agent report", "Request: review backups\n\nResult excerpt: long", about="review backups")
        self.assertEqual(similar.call_args.args[0], "review backups")
        offered = post.call_args.args[1]["messages"][1]["content"]
        self.assertLess(offered.index("- Backups"), offered.index("- hermod"))   # closest first, then the newest others
        self.assertNotIn("gone", offered)
        self.assertEqual(placed["related"], ["Backups"])

    def test_similar_endpoint_returns_only_notes_that_are_really_close(self):
        handler = bridge.H.__new__(bridge.H)
        raw = json.dumps({"text": "where does hermes run", "k": 5}).encode()
        handler.path, handler.headers, handler.rfile, handler._j = "/bridge/similar", {"content-length": str(len(raw))}, io.BytesIO(raw), mock.Mock()
        with mock.patch.object(bridge.embed, "similar", return_value=[("Areas/hermod.md", 0.69), ("Resources/Backups.md", 0.2)]) as similar:
            handler.do_POST()
        self.assertEqual(similar.call_args.args[:2], ("where does hermes run", 5))
        self.assertEqual(handler._j.call_args.args, (200, {"notes": [{"path": "Areas/hermod.md", "name": "hermod", "score": 0.69}]}))

    def test_answers_are_placed_while_they_are_made(self):
        with mock.patch.object(bridge, "JEV_KEY", ""), \
                mock.patch.object(bridge, "place", return_value={"related": ["Backups"]}) as place, \
                mock.patch.object(bridge, "answer", return_value={"answer": "Daily.", "sources": [{"id": "hermod"}]}), \
                mock.patch.object(bridge, "log_talk") as log:
            result = bridge.talk("Where is my report?")
        self.assertEqual(place.call_args.args[:2], ("a conversation", "Said to muninn: Where is my report?"))
        self.assertEqual(result["related"], ["Backups"])
        self.assertEqual(log.call_args.args[1]["related"], ["Backups"])


class RetrievalTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        database = str(Path(temporary.name) / "index.db")
        db = bridge.sqlite3.connect(database)
        db.executescript("CREATE TABLE notes (path TEXT PRIMARY KEY, mtime INTEGER, title TEXT, body TEXT, tags TEXT);"
                         "CREATE VIRTUAL TABLE notes_fts USING fts5(path UNINDEXED, title, body);")
        for path, body in (("Areas/hermod.md", "The Hermes agent VM."), ("Resources/Kernel fix.md", "NVIDIA driver and kernel 7.2."),
                           ("Resources/Driver notes.md", "A driver for the printer."), ("Resources/Immich.md", "Phone photos are uploaded here.")):
            db.execute("INSERT INTO notes VALUES (?, 1, '', ?, '')", (path, body))
            db.execute("INSERT INTO notes_fts VALUES (?, '', ?)", (path, body))
        db.commit()
        db.close()
        for name, value in (("DB", database), ("GRAPHIFY", "/nonexistent")):
            patch = mock.patch.object(bridge, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def found(self, question, near):
        with mock.patch.object(bridge.embed, "similar", return_value=near):
            return [note["id"] for note in bridge.retrieve(question)[0]]

    def test_meaning_finds_a_note_that_shares_no_word_with_the_question(self):
        self.assertEqual(self.found("where do my pictures get backed up", [("Resources/Immich.md", 0.52)]), ["Immich"])

    def test_a_note_both_searches_agree_on_comes_first(self):
        # keywords alone would lead with the printer note, meaning alone with hermod
        near = [("Areas/hermod.md", 0.6), ("Resources/Kernel fix.md", 0.5)]
        self.assertEqual(self.found("printer driver", near), ["Kernel fix", "hermod", "Driver notes"])

    def test_without_the_index_or_with_nothing_close_keywords_still_answer(self):
        for near in ([], [("Areas/hermod.md", 0.2)]):
            with self.subTest(near=near):
                self.assertEqual(self.found("kernel", near), ["Kernel fix"])

    def test_logs_of_what_was_said_or_filed_are_not_answer_sources(self):
        db = bridge.sqlite3.connect(bridge.DB)
        for path in ("Resources/Talk logs/Talk 2026-10-03.md", "Resources/Reports/inbox-2026-10-03T18-09-14.md",
                     "Resources/Reports/alert-huginn-inbox-sweep.service.md", "Resources/Reports/Kernel report (1a2b3c4d).md"):
            db.execute("INSERT INTO notes VALUES (?, 1, '', 'kernel kernel kernel', '')", (path,))
            db.execute("INSERT INTO notes_fts VALUES (?, '', 'kernel kernel kernel')", (path,))
        db.commit()
        db.close()
        # an agent's report is a source; the logs are not, however well they match
        self.assertEqual(self.found("kernel", []), ["Kernel report (1a2b3c4d)", "Kernel fix"])


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

    def filed(self, root, meta, status="done"):
        store = JobStore(root / "jobs.db", root, titler=mock.Mock(return_value=meta))
        job = store.create("Review backups", "codex", {"via": "jev"})
        job.update(status=status, answer="Findings.")
        store.finish(job)
        saved = store.get(job["id"])
        return saved["report"], (root / saved["report"]).read_text()

    def test_title_punctuation_is_repaired_instead_of_costing_the_title(self):
        with tempfile.TemporaryDirectory() as d:
            name, text = self.filed(Path(d), {"title": "Best GPUs for Local AI: RTX 5070 Ti vs 3090/4090", "tags": ["gpu"]})
        self.assertTrue(name.startswith("Resources/Reports/Best GPUs for Local AI — RTX 5070 Ti vs 3090 4090 ("))
        self.assertIn("# Best GPUs for Local AI — RTX 5070 Ti vs 3090 4090\n", text)

    def test_minimax_places_the_report_among_notes_that_exist(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for note in ("MOCs/Knowledge MOC.md", "Areas/ComfyUI on mjolnir.md", "Resources/Backups.md"):
                (root / note).parent.mkdir(exist_ok=True)
                (root / note).write_text("A note.")
            meta = {"title": "Chroma in ComfyUI", "tags": ["comfyui"], "moc": "Knowledge MOC",
                    "related": ["ComfyUI on mjolnir", "A note nobody wrote", "../CLAUDE", "Backups", "ComfyUI on mjolnir", 7]}
            _, text = self.filed(root, meta)
            self.assertIn("\n\nUp: [[Knowledge MOC]]\nRelated: [[ComfyUI on mjolnir]] · [[Backups]]\n\n- Worker: codex\n", text)
            self.assertNotIn("nobody wrote", text)
            self.assertNotIn("CLAUDE", text)
            # a hub that does not exist, or a run that failed, stays with the agents
            for meta, status in (({**meta, "moc": "No such MOC", "related": []}, "done"), (meta, "failed")):
                with self.subTest(moc=meta["moc"], status=status):
                    _, text = self.filed(root, meta, status)
                    self.assertIn("\n\nUp: [[Agents MOC]]\n\n- Worker: codex\n", text)

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
