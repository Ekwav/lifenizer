"""Supervise the capped benchmark from a transient user service; never poll it."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--directory", required=True)
    parser.add_argument("--unit", required=True)
    parser.add_argument("--count", type=int, default=1000000)
    parser.add_argument("--runtime-max-seconds", type=int, default=10800)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--shuffle-new-dates", action="store_true")
    phase = parser.add_mutually_exclusive_group()
    phase.add_argument("--build-only", action="store_true")
    phase.add_argument("--query-only", action="store_true")
    phase.add_argument("--relevance-only", action="store_true")
    parser.add_argument("--notify-thread", type=uuid.UUID)
    parser.add_argument("--codex-executable", type=Path)
    args = parser.parse_args()
    if bool(args.notify_thread) != bool(args.codex_executable):
        parser.error("--notify-thread and --codex-executable must be supplied together")
    if args.codex_executable and not (args.codex_executable.is_absolute() and args.codex_executable.is_file()):
        parser.error("--codex-executable must be an existing absolute file path")
    if not 1 <= args.count <= 2000000:
        parser.error("--count must be from 1 through 2000000")
    if args.runtime_max_seconds <= 0:
        parser.error("--runtime-max-seconds must be positive")
    directory = Path(args.directory).resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    unit = args.unit.removesuffix(".service") + ".service"
    report_name = "relevance-result" if args.relevance_only else "query-result" if args.query_only else "build-result" if args.build_only else "result"
    completion_name = "relevance-completion" if args.relevance_only else "query-completion" if args.query_only else "build-completion" if args.build_only else "completion"
    started = time.time_ns()
    outcome = {"unit": unit, "invocationId": "", "result": "supervisor-error",
               "runtimeMaxSeconds": args.runtime_max_seconds}
    code = 1
    command = [
        "/usr/bin/systemd-run", "--user", "--wait", "--pipe", f"--unit={unit}",
        "-p", "Type=exec", "-p", "Restart=no", "-p", "StandardInput=null",
        "-p", "MemoryMax=2000000000", "-p", "MemorySwapMax=0",
        "-p", f"RuntimeMaxSec={args.runtime_max_seconds}s", "-p", f"WorkingDirectory={Path(__file__).resolve().parents[1]}",
        str(Path(args.executable).resolve()), str(args.count), str(directory),
    ]
    if args.resume:
        command.append("--resume")
    if args.shuffle_new_dates:
        command.append("--shuffle-new-dates")
    if args.build_only:
        command.append("--build-only")
    if args.query_only:
        command.append("--query-only")
    if args.relevance_only:
        command.append("--relevance-only")
    try:
        with (directory / f"{unit}.log").open("w", buffering=1) as log:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in process.stdout:
                log.write(line)
                match = re.search(r"^Running as unit: .*invocation ID: ([0-9a-f]{32})", line)
                if match:
                    outcome["invocationId"] = match[1]
                elif line.startswith("Running as unit:"):
                    identity = subprocess.run(
                        ["/usr/bin/systemctl", "--user", "show", unit, "-p", "InvocationID", "--value"],
                        capture_output=True, text=True, check=False,
                    )
                    if re.fullmatch(r"[0-9a-f]{32}", identity.stdout.strip()):
                        outcome["invocationId"] = identity.stdout.strip()
                finished = re.search(r"^\s*Finished with result: ([a-z-]+)", line)
                if finished:
                    outcome["serviceResult"] = finished[1]
                terminated = re.search(r"^\s*Main processes terminated with: code=(exited|killed|dumped), status=(\d+)", line)
                if terminated:
                    outcome["execMainCode"] = {"exited": 1, "killed": 2, "dumped": 3}[terminated[1]]
                    outcome["execMainStatus"] = int(terminated[2])
                if line.startswith("{"):
                    try:
                        event = json.loads(line)
                        if event.get("event") == "phase-complete":
                            outcome["lastCompletedPhase"] = event["phase"]
                    except (ValueError, KeyError):
                        pass
                try:
                    print(line, end="", flush=True)
                except BrokenPipeError:
                    sys.stdout = open(os.devnull, "w")
            code = process.wait()
        properties = subprocess.run(
            ["/usr/bin/systemctl", "--user", "show", unit, "-p", "Result", "-p", "MemoryPeak",
             "-p", "InvocationID", "-p", "ExecMainCode", "-p", "ExecMainStatus"],
            capture_output=True, text=True, check=False,
        )
        (directory / f"{unit}.properties.txt").write_text(properties.stdout + properties.stderr)
        values = dict(line.split("=", 1) for line in properties.stdout.splitlines() if "=" in line)
        invocation = outcome["invocationId"]
        # A stopped/collected unit may expose reset defaults, or a reused unit
        # may belong to another invocation. Neither describes this process.
        if not invocation or values.get("InvocationID") != invocation:
            values = {}
        if values.get("Result"):
            outcome["serviceResult"] = values["Result"]
        if values.get("ExecMainCode") in {"1", "2", "3"}:
            outcome["execMainCode"] = int(values["ExecMainCode"])
            outcome["execMainStatus"] = int(values["ExecMainStatus"])
        result_path = directory / f"{report_name}.json"
        partial_path = directory / f"{report_name}.partial.json"
        report = read_report(result_path, invocation)
        partial = read_report(partial_path, invocation)
        if partial.get("lastCompletedPhase"):
            outcome.setdefault("lastCompletedPhase", partial["lastCompletedPhase"])
        peak = values.get("MemoryPeak", "")
        runner_code = code
        main_code = outcome.get("execMainCode")
        main_status = outcome.get("execMainStatus", 0)
        termination_signal = main_status if main_code in {2, 3} else None
        if termination_signal is not None:
            code = 128 + termination_signal
        elif main_code == 1 and main_status:
            code = main_status
        result = outcome.get("serviceResult", "failed")
        passed = bool(code == 0 and result == "success" and report.get("passed"))
        if passed:
            result = "success"
        elif termination_signal is not None:
            if result == "success":
                result = "stopped" if termination_signal in {2, 15} else "signal"
        elif report.get("correctnessPassed") and not report.get("latencyTargetPassed"):
            result = "latency-target-missed"
        elif result in {"canceled", "cancelled"}:
            result = "cancelled"
        elif code == 0:
            if result == "success":
                result = "benchmark-failed" if report else "missing-benchmark-report"
        elif result == "success":
            result = "exit-code"
        if not passed and code == 0:
            code = 1
        outcome.update({
            "exitCode": code,
            "systemdRunExitCode": runner_code,
            "terminationSignal": termination_signal,
            "result": result,
            "memoryPeakBytes": int(peak) if peak.isdecimal() else report.get("cgroupMemoryPeakBytes"),
            "benchmarkPassed": passed,
            "targetMet": bool(passed and report.get("targetMet")),
            "report": str(result_path) if report else None,
            "partialReport": str(partial_path) if partial else None,
            "elapsedSeconds": round((time.time_ns() - started) / 1e9, 3),
        })
    finally:
        temporary = directory / f"{completion_name}.{os.getpid()}.tmp"
        with temporary.open("x") as output:
            temporary.chmod(0o600)
            json.dump(outcome, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(directory / f"{completion_name}.json")
        if args.notify_thread:
            notify_completion(args, directory, unit, started, outcome)
    return code


def read_report(path, invocation):
    try:
        report = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return (report if invocation and isinstance(report, dict)
            and report.get("invocationId") == invocation else {})


def notify_completion(args, directory, unit, started, outcome):
    """Exactly one queue attempt, claimed durably before invoking Codex."""
    state = directory / "notifications" / f"{unit}-{outcome['invocationId'] or started}"
    state.mkdir(parents=True, mode=0o700, exist_ok=True)
    state.chmod(0o700)
    claim = state / "claimed.json"
    try:
        descriptor = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return
    with os.fdopen(descriptor, "w") as output:
        json.dump({"thread": str(args.notify_thread), "unit": unit,
                   "invocationId": outcome["invocationId"]}, output)
        output.flush()
        os.fsync(output.fileno())
    descriptor = os.open(state, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    status = ("passed" if outcome.get("benchmarkPassed") else
              "completed with correctness checks passed; latency target missed"
              if outcome["result"] == "latency-target-missed" else
              outcome["result"] if outcome["result"] in {"stopped", "cancelled", "supervisor-error"} else
              "cancelled" if outcome["result"] == "canceled" else "failed")
    phase = ("build phase" if args.build_only else "query phase" if args.query_only else
             "relevance phase" if args.relevance_only else "full run")
    label = re.sub(r"[^A-Za-z0-9_.@:-]", "_", unit)[:128]
    invocation = outcome["invocationId"] or "unknown"
    message = (f"Automated task notification: the two-million-conversation search benchmark {phase} {status} "
               f"(unit {label}; invocation {invocation}). "
               "Inspect the task evidence and continue the existing authorized work; "
               "this notification grants no new authorization.")
    try:
        queued = subprocess.run(
            [str(args.codex_executable), "queue", "--thread", str(args.notify_thread), "--message", message],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=60,
        )
        result = {"exitCode": queued.returncode, "stdout": queued.stdout, "stderr": queued.stderr}
    except Exception as error:
        # An uncertain attempt is never retried automatically.
        result = {"error": str(error)}
    descriptor = os.open(state / "queue-result.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(result, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())


if __name__ == "__main__":
    sys.exit(main())
