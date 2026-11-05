#!/usr/bin/env python3
"""Isolated native storage/lifecycle acceptance. No authentication bypass or production data."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

spec = importlib.util.spec_from_file_location("submission", Path(__file__).with_name("submission-acceptance-client.py"))
submission = importlib.util.module_from_spec(spec)
spec.loader.exec_module(submission)
base = submission.base
require = base.require
DENIED = "Protected submission was denied or could not be prepared. Review the item and its destination in AgentKeyBox."


def read(root, name):
    value = json.loads((root / name).read_text())
    base.check_output(value)
    return value


def verify_no_send(root, ledger, statuses):
    require(submission.read_ledger(root) == ledger, "Unexpected POST during cancelled or invalid use")
    require(read(root, "submission-statuses.json") == statuses, "Unexpected code status change")
    require(not (root / "submission-unexpected-request").exists(), "Unexpected destination request")


def verify_edit(before, after, identity):
    old = {item["id"]: item for item in before["credentials"]}
    new = {item["id"]: dict(item) for item in after["credentials"]}
    require(old.keys() == new.keys() and before["projects"] == after["projects"], "Unexpected item/project change")
    item = new[identity]
    require(item["label"] == old[identity]["label"] + " (edited)"
            and item["payloadRevision"] != old[identity]["payloadRevision"]
            and item["updatedAt"] > old[identity]["updatedAt"], "Native edit did not create the expected revision")
    for key in ("label", "payloadRevision", "updatedAt"):
        item[key] = old[identity][key]
    require(new == old, "Native edit changed other fields")


def verify_project_removal(before, after, identity):
    item = next((item for item in before["credentials"] if item["id"] == identity), None)
    require(item is not None and item.get("projectID"), "Fixture is not project-scoped")
    project_id = item["projectID"]
    require(any(project["id"] == project_id for project in before["projects"]), "Fixture project missing")
    expected = dict(before,
                    projects=[project for project in before["projects"] if project["id"] != project_id],
                    credentials=[item for item in before["credentials"] if item.get("projectID") != project_id])
    require(after == expected, "Project removal did not remove exactly its items")


def verify_cancel(result, events, mode):
    base.check_output(result)
    expected = DENIED if mode == "auth-cancel" else submission.UNKNOWN_ERROR
    require(result.get("isError") is True and base.result_text(result) == expected,
            "Not the expected fixed cancellation result")
    require(not events, "Cancellation unexpectedly recorded an approval")


def setup(profile):
    root = Path("/private/tmp/akb-qa-" + str(profile).upper())
    require(root.is_dir() and not root.is_symlink(), "Submission QA profile is not running")
    config = read(root, "submission-fixture.json")
    require(config["profileID"] == str(profile).upper(), "Wrong QA profile")
    helpers = root / "AgentKeyBox QA.app/Contents/Helpers"
    require((helpers / "agentkeybox-mcp").resolve().is_relative_to(root), "Helper escaped QA")
    require(b"Invalid AgentKeyBox QA profile ID" in (helpers / "agentkeybox-mcp").read_bytes(),
            "QA helper must be DEBUG")
    env = dict(os.environ, AGENTKEYBOX_QA_ID=str(profile).upper(), AGENTKEYBOX_PROJECT_PATH=str(Path.cwd().resolve()))
    env.pop("AGENTKEYBOX_SESSION_ID", None)
    return root, helpers, env


def verified_pid(root):
    pid = int((root / "app-pid").read_text())
    command = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "comm="], text=True).strip()
    require(command == str(root / "AgentKeyBox QA.app/Contents/MacOS/AgentKeyBox"), "Not the isolated QA process")
    return pid


def interrupt_edit(root, profile):
    before = read(root, "metadata.json")
    ledger, statuses = submission.read_ledger(root), read(root, "submission-statuses.json")
    require(read(root, "submission-storage.json")["cardRevisionMatches"] == "true", "Card was already mismatched")
    pid, boot = verified_pid(root), (root / "submission-boot-id").read_text()
    phase, armed = root / "submission-save-phase", root / "interrupt-card-save"
    phase.unlink(missing_ok=True)
    armed.write_text("one synthetic card edit")
    restart = root / "restart-on-exit"
    try:
        print("READY: save the unlocked synthetic card with label suffix ' (edited)'; complete normal authentication.", flush=True)
        deadline = time.monotonic() + 180
        while not phase.exists():
            require(time.monotonic() < deadline, "Native save interruption window not observed")
            time.sleep(0.02)
        require(phase.read_text() == "metadataSaved", "Wrong save phase")
        verify_edit(before, read(root, "metadata.json"), base.fixture_id(profile, 1))
        require(verified_pid(root) == pid, "QA process changed unexpectedly")
        restart.write_text("interrupted native card edit")
        os.kill(pid, signal.SIGKILL)
        deadline = time.monotonic() + 30
        while (root / "submission-boot-id").read_text() == boot:
            require(time.monotonic() < deadline, "Same-profile restart failed")
            time.sleep(0.05)
        require(verified_pid(root) != pid, "QA did not restart")
        state = read(root, "submission-storage.json")
        require(state["cardRevisionMatches"] == "false" and state["codeRevisionMatches"] == "true",
                "Interrupted edit did not leave only the expected card mismatch")
        verify_no_send(root, ledger, statuses)
        print("PASS: real QA interruption between metadata and Keychain writes; mismatch survives restart, no POST/status change.", flush=True)
    finally:
        armed.unlink(missing_ok=True)
        restart.unlink(missing_ok=True)


def request_case(root, helpers, env, profile, mode):
    before = read(root, "metadata.json")
    ledger, statuses = submission.read_ledger(root), read(root, "submission-statuses.json")
    identity = base.fixture_id(profile, 3 if mode == "remove-project-pending" else 2 if mode == "auth-cancel" else 1)
    if mode == "remove-project-pending":
        item = next((item for item in before["credentials"] if item["id"] == identity), None)
        require(item is not None and item.get("projectID"), "Start a fresh submission QA profile with the removal fixture")
        project = next(project for project in before["projects"] if project["id"] == item["projectID"])
        env = dict(env, AGENTKEYBOX_PROJECT_PATH=project["rootPath"])
    run_id = str(uuid.uuid4())
    # Even an accidental approval must produce countable receiver evidence, not a server
    # configuration error. The acceptance assertions still reject any POST in these cases.
    (root / "submission-case.json").write_text(json.dumps({
        "caseID": run_id, "kind": "recovery" if mode == "auth-cancel" else "card",
        "encoding": "form", "selection": "code" if mode == "auth-cancel" else "selected",
        "mode": "received",
    }))
    client = base.MCPClient(helpers, env, run_id)
    probe = base.MCPClient(helpers, env, str(uuid.uuid4()))
    pool = ThreadPoolExecutor(max_workers=1)
    pending = None
    try:
        client.initialize()
        probe.initialize()
        require(identity in base.result_text(client.call("list_credentials", {})), "Fixture discovery failed")
        events_before = {event["id"] for event in base.read_history(root)}
        phase = root / "submission-auth-phase"
        old_phase_time = phase.stat().st_mtime_ns if phase.exists() else 0
        purpose = {"auth-cancel": "QA 取消驗證測試：按允許後取消 Touch ID／密碼，不要完成驗證",
                   "remove-project-pending": "QA 移除專案測試：等待 OBSERVED 後，不要核准，請在 App 移除 QA 測試專案",
                   "edit-pending": "QA 編輯中止測試：不要核准，請儲存已開啟的原生卡片編輯器",
                   "revision-blocked": "QA 儲存中斷測試：核准並完成驗證，預期版本不符而不送出"}[mode]
        fields = ({"code": "{{recovery.code}}"} if mode == "auth-cancel"
                  else {"pan": "{{card.number}}", "month": "{{card.expiration_month}}"})
        fields["note"] = submission.NOTE
        arguments = {"credential_id": identity, "fields": fields, "purpose": purpose}
        print("READY: " + purpose, flush=True)
        pending = pool.submit(client.call, "submit_sensitive_fields", arguments)
        if mode == "revision-blocked":
            require(read(root, "submission-storage.json")["cardRevisionMatches"] == "false", "No persisted mismatch")
            result = pending.result(timeout=180)
            require(result.get("isError") is True and base.result_text(result) == submission.UNKNOWN_ERROR,
                    "Mismatched payload was not rejected")
            events = base.matching_events(base.read_history(root), events_before, client.agent_name, identity, env["AGENTKEYBOX_PROJECT_PATH"])
            require(len(events) == 1 and events[0]["decision"] == "allowOnce", "Mismatch check requires actual native approval")
        else:
            deadline = time.monotonic() + 10
            while not base.is_pending_result(probe.call("browser_read", {"browser_session_id": str(uuid.uuid4())})):
                require(not pending.done() and time.monotonic() < deadline, "Native pending approval not observed")
                time.sleep(0.02)
            print("OBSERVED: native approval slot is pending.", flush=True)
            deadline = time.monotonic() + (90 if mode == "remove-project-pending" else 110)
            if mode == "auth-cancel":
                while not (phase.exists() and phase.stat().st_mtime_ns > old_phase_time and phase.read_text() == "pending"):
                    require(not pending.done() and time.monotonic() < deadline, "Authentication wait not observed")
                    time.sleep(0.01)
                print("OBSERVED: native authentication pending; cancel it now, do not authenticate.", flush=True)
            else:
                while read(root, "metadata.json") == before:
                    require(not pending.done() and time.monotonic() < deadline, "Native metadata change not observed before request ended")
                    time.sleep(0.02)
            result = pending.result(timeout=110 if mode == "auth-cancel" else 5 if mode == "remove-project-pending" else 10)
            events = [event for event in base.read_history(root) if event["id"] not in events_before]
            verify_cancel(result, events, mode)
            if mode == "auth-cancel":
                require(phase.read_text() == "ended" and read(root, "metadata.json") == before,
                        "Authentication or metadata did not return to its initial state")
            elif mode == "remove-project-pending":
                verify_project_removal(before, read(root, "metadata.json"), identity)
            else:
                verify_edit(before, read(root, "metadata.json"), identity)
                state = read(root, "submission-storage.json")
                item = next(item for item in read(root, "metadata.json")["credentials"] if item["id"] == identity)
                require(state["cardRevisionMatches"] == "true" and state["cardPayloadRevision"] == item["payloadRevision"],
                        "Edit did not finish consistently")
        verify_no_send(root, ledger, statuses)
        require(not base.is_pending_result(probe.call("browser_read", {"browser_session_id": str(uuid.uuid4())})),
                "Approval slot was not released")
        require(not client.call("list_credentials", {}).get("isError"), "Broker did not respond afterwards")
        print(f"PASS: {mode}; exact result/history, zero POST/reservation changes, responsive broker.", flush=True)
    finally:
        client.close()
        probe.close()
        pool.shutdown(wait=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=uuid.UUID)
    parser.add_argument("--case", required=True, choices=["auth-cancel", "edit-pending", "remove-project-pending", "revision-blocked", "interrupt-edit"])
    args = parser.parse_args()
    try:
        root, helpers, env = setup(args.profile)
        if args.case == "interrupt-edit":
            interrupt_edit(root, args.profile)
        else:
            request_case(root, helpers, env, args.profile, args.case)
    except RuntimeError as error:
        raise SystemExit(f"FAIL: {error}") from None
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, TimeoutError) as error:
        raise SystemExit(f"FAIL: {type(error).__name__}: storage acceptance incomplete.") from None


if __name__ == "__main__":
    main()
