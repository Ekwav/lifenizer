"""Supervisor reporting regressions; subprocesses and notifications are fakes."""
import contextlib
import io
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest.mock import patch

import run_million_search_benchmark as supervisor


CURRENT = "a" * 32
OTHER = "b" * 32
THREAD = "00000000-0000-0000-0000-000000000001"


class ReportingTest(unittest.TestCase):
    def run_fixture(self, output, properties="", report=None, partial=None, runner_code=0, runtime=None):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for filename, contents in [("result.json", report), ("result.partial.json", partial)]:
                if contents is not None:
                    (directory / filename).write_text(json.dumps(contents))
            process = SimpleNamespace(
                stdout=io.StringIO(f"Running as unit: test.service; invocation ID: {CURRENT}\n{output}"),
                wait=lambda: runner_code,
            )
            notifications = []

            def run(command, **kwargs):
                if command[0] == "/usr/bin/systemctl":
                    return SimpleNamespace(stdout=properties, stderr="", returncode=0)
                notifications.append(command)
                return SimpleNamespace(stdout="queued", stderr="", returncode=0)

            arguments = ["supervisor", "--executable", "/bin/true", "--directory", temporary,
                         "--unit", "test", "--notify-thread", THREAD, "--codex-executable", "/bin/true"]
            if runtime is not None:
                arguments.extend(["--runtime-max-seconds", str(runtime)])
            with patch.object(sys, "argv", arguments), \
                    patch.object(supervisor.subprocess, "Popen", return_value=process) as start, \
                    patch.object(supervisor.subprocess, "run", side_effect=run), \
                    contextlib.redirect_stdout(io.StringIO()):
                code = supervisor.main()
            outcome = json.loads((directory / "completion.json").read_text())
            limit = 10800 if runtime is None else runtime
            self.assertIn(f"RuntimeMaxSec={limit}s", start.call_args.args[0])
            self.assertIn("MemoryMax=2000000000", start.call_args.args[0])
            self.assertIn("MemorySwapMax=0", start.call_args.args[0])
            self.assertEqual(outcome["runtimeMaxSeconds"], limit)
            self.assertEqual(len(notifications), 1)
            self.assertEqual(notifications[0][:4], ["/bin/true", "queue", "--thread", THREAD])
            message = notifications[0][-1]
            self.assertIn(f"unit test.service; invocation {CURRENT}", message)
            return code, outcome, message

    def test_explicit_runtime_limit_is_forwarded_and_recorded(self):
        self.run_fixture("Finished with result: success\n", runtime=21600)

    def test_nonpositive_runtime_is_rejected_before_start(self):
        for limit in (0, -1):
            with self.subTest(limit=limit), \
                    patch.object(sys, "argv", ["supervisor", "--executable", "/bin/true",
                                               "--directory", "/unused", "--unit", "test",
                                               "--runtime-max-seconds", str(limit)]), \
                    patch.object(supervisor.subprocess, "Popen") as start, \
                    contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as error:
                supervisor.main()
            self.assertEqual(error.exception.code, 2)
            start.assert_not_called()

    def test_sigterm_uses_stream_evidence_and_rejects_other_reports(self):
        code, outcome, message = self.run_fixture(
            "Finished with result: success\nMain processes terminated with: code=killed, status=15/TERM\n",
            "InvocationID=\nResult=success\nExecMainCode=0\nExecMainStatus=0\n",
            {"invocationId": OTHER, "passed": True, "targetMet": True},
            {"invocationId": OTHER, "lastCompletedPhase": "another-run"},
        )
        self.assertEqual((code, outcome["exitCode"], outcome["systemdRunExitCode"]), (143, 143, 0))
        self.assertEqual((outcome["execMainCode"], outcome["execMainStatus"], outcome["terminationSignal"]), (2, 15, 15))
        self.assertEqual(outcome["result"], "stopped")
        self.assertIsNone(outcome["report"])
        self.assertIsNone(outcome["partialReport"])
        self.assertNotIn("lastCompletedPhase", outcome)
        self.assertFalse(outcome["benchmarkPassed"])
        self.assertIn("full run stopped", message)

    def test_reused_unit_cannot_supply_another_invocation(self):
        code, outcome, _ = self.run_fixture(
            "Finished with result: success\nMain processes terminated with: code=exited, status=0/SUCCESS\n",
            f"InvocationID={OTHER}\nResult=success\nExecMainCode=1\nExecMainStatus=0\nMemoryPeak=999\n",
            {"invocationId": OTHER, "passed": True},
        )
        self.assertEqual(code, 1)
        self.assertEqual(outcome["invocationId"], CURRENT)
        self.assertEqual(outcome["result"], "missing-benchmark-report")
        self.assertIsNone(outcome["memoryPeakBytes"])

    def test_matching_report_and_partial_are_accepted(self):
        code, outcome, message = self.run_fixture(
            "Finished with result: success\n",
            f"InvocationID={CURRENT}\nResult=success\nExecMainCode=1\nExecMainStatus=0\n",
            {"invocationId": CURRENT, "passed": True, "targetMet": True},
            {"invocationId": CURRENT, "lastCompletedPhase": "complete"},
        )
        self.assertEqual(code, 0)
        self.assertTrue(outcome["benchmarkPassed"])
        self.assertTrue(outcome["targetMet"])
        self.assertEqual(outcome["lastCompletedPhase"], "complete")
        self.assertIn("full run passed", message)

    def test_matched_unit_failure_overrides_wrapper_success_and_report(self):
        code, outcome, _ = self.run_fixture(
            "Finished with result: success\n",
            f"InvocationID={CURRENT}\nResult=oom-kill\nExecMainCode=2\nExecMainStatus=9\n",
            {"invocationId": CURRENT, "passed": True, "targetMet": True},
        )
        self.assertEqual(code, 137)
        self.assertEqual(outcome["result"], "oom-kill")
        self.assertFalse(outcome["benchmarkPassed"])
        self.assertFalse(outcome["targetMet"])

    def test_latency_failure_still_returns_failure_when_wrapper_returns_zero(self):
        code, outcome, message = self.run_fixture(
            "Finished with result: success\n",
            report={"invocationId": CURRENT, "passed": False,
                    "correctnessPassed": True, "latencyTargetPassed": False},
        )
        self.assertEqual((code, outcome["result"]), (1, "latency-target-missed"))
        self.assertIn("correctness checks passed; latency target missed", message)
        self.assertNotIn("full run failed", message)

    def test_exit_status_and_cancellation_survive_zero_wrapper_status(self):
        code, outcome, _ = self.run_fixture(
            "Finished with result: success\nMain processes terminated with: code=exited, status=7\n")
        self.assertEqual((code, outcome["result"]), (7, "exit-code"))
        code, outcome, message = self.run_fixture("Finished with result: canceled\n")
        self.assertEqual((code, outcome["result"]), (1, "cancelled"))
        self.assertIn("full run cancelled", message)


if __name__ == "__main__":
    unittest.main()
