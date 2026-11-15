#!/usr/bin/env python3
"""Native recovery acceptance against the runner's isolated, pinned loopback fixture only."""
import argparse
import importlib.util
import json
import os
import signal
from pathlib import Path
import subprocess
import time
import uuid

spec = importlib.util.spec_from_file_location(
    "acceptance", Path(__file__).with_name("browser-acceptance-client.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
require = base.require
CODE_COUNT = 4


def expected_statuses(posts):
    require(type(posts) is int and 0 <= posts <= CODE_COUNT, "Invalid recovery POST count")
    return ["issued"] * posts + ["available"] * (CODE_COUNT - posts)


def expected_counts(posts):
    expected_statuses(posts)
    return {"available": CODE_COUNT - posts, "used": 0, "needsReview": posts}


def validate_linked_fixture(items, login_id, recovery_id, origin):
    require(set(items) == {login_id, recovery_id}, "Unexpected fixture items")
    require(items[login_id]["kind"] == "login" and
            items[login_id].get("loginURL") == origin + "/login-recovery" and
            items[recovery_id]["kind"] == "recoveryCodes" and
            items[recovery_id].get("linkedLoginID") == login_id and
            items[recovery_id].get("submissionURL") is None,
            "Fixture recovery codes must link to the local login without a destination")


def verify_listing(result, login_id, recovery_id, posts):
    require(not result.get("isError"), "Recovery listing failed")
    lines = base.result_text(result).splitlines()
    matches = [line for line in lines if line.startswith(recovery_id + " | ")]
    require(len(matches) == 1, "Recovery listing item is missing or duplicated")
    fields = matches[0].split(" | ")
    counts = expected_counts(posts)
    require("for_login=" + login_id in fields and
            f"codes=available:{counts['available']},used:0,needs_review:{counts['needsReview']}" in fields and
            any(field in fields for field in ("submission_url=automatic (browser_recover only)",
                                              "submission_url=自動判斷（僅限 browser_recover）")),
            "Recovery listing is missing its linked login, counts or automatic destination")


def verify_ledger(root, posts):
    path = root / "server-event.ledger"
    ledger = json.loads(path.read_text()) if path.exists() else []
    require(isinstance(ledger, list) and all(
        isinstance(entry, dict) and type(entry.get("codeIndex")) is int
        and entry.get("persistedBeforePost") is True and entry.get("duplicate") is False
        for entry in ledger), "Invalid recovery ledger evidence")
    require(ledger == [{"codeIndex": index, "persistedBeforePost": True, "duplicate": False}
                       for index in range(posts)], "Recovery POST was not durable, ordered and unique")


def challenge_result(result, origin, browser_id=None):
    require(not result.get("isError"), "Login did not reach the recovery challenge")
    text = base.result_text(result)
    require("{" in text, "Recovery challenge response is missing")
    page = json.loads(text[text.index("{"):])
    base.check_output(page)
    expected = {
        "sessionID": page.get("sessionID"), "status": "recoveryCodeRequired", "origin": origin,
        "title": "Recovery code required",
        "text": "Request browser_recover with a recovery-code item whose for_login matches this login, or whose "
                "submission URL exactly matches. A separate native approval is required. "
                "No page content is available until verification completes.",
        "links": [],
    }
    chinese = dict(expected, title="需要復原碼",
                   text="請用 for_login 符合這個登入項目，或目的網址完全相符的復原碼項目呼叫 browser_recover，並取得另一次原生核准。驗證完成前不會提供頁面內容。")
    require(page in (expected, chinese), "Challenge exposed non-fixed content or wrong state/origin")
    uuid.UUID(page["sessionID"])
    require(browser_id is None or browser_id == page["sessionID"], "Browser identity changed")
    return page


def verify_reservation(root, before, expect_post, initial_statuses=None, initial_posts=0,
                       edited=False):
    if initial_statuses is None:
        initial_statuses = expected_statuses(initial_posts)
    require(initial_statuses == expected_statuses(initial_posts), "Invalid initial recovery state")
    expected_posts = initial_posts + int(expect_post)
    statuses = json.loads((root / "recovery-statuses.json").read_text())
    require(statuses == expected_statuses(expected_posts),
            "Unexpected persisted recovery-code statuses")
    marker = root / "server-event.recovery"
    posts = int(marker.read_text()) if marker.exists() else 0
    require(posts == expected_posts, "Unexpected number of recovery POSTs")
    verify_ledger(root, posts)
    require(not (root / "server-event").exists(), "A cross-origin sink received a request")
    current = json.loads((root / "metadata.json").read_text())
    base.check_output(current)
    if posts:
        evidence = json.loads((root / "server-event.reservation").read_text())
        require(evidence == {"persistedBeforePost": True}, "Reservation was not durable before POST")
    for item in current["credentials"]:
        if item["kind"] == "recoveryCodes":
            require(item.get("recoveryCodeCounts") == expected_counts(expected_posts),
                    "Recovery metadata counts do not match durable statuses")
            require(item.get("recoveryCodePendingRevision") is None, "Reservation metadata is incomplete")
    if expect_post or edited:
        # A reservation advances revision and timestamp; an edit may also change its label.
        previous_items = {item["id"]: item for item in before["credentials"]}
        for item in current["credentials"]:
            previous = previous_items.get(item["id"])
            require(previous is not None, "Unexpected fixture item")
            if item["kind"] == "recoveryCodes":
                require(item["payloadRevision"] != previous["payloadRevision"], "Revision did not change")
                uuid.UUID(item["payloadRevision"])
                require(item["updatedAt"] > previous["updatedAt"], "Timestamp did not advance")
                item["recoveryCodeCounts"] = previous["recoveryCodeCounts"]
                item["payloadRevision"] = previous["payloadRevision"]
                if edited:
                    require(item["label"] == previous["label"] + " (edited)", "Expected native edit missing")
                    item["label"] = previous["label"]
                item["updatedAt"] = previous["updatedAt"]
    require(current == before, "Operation changed unexpected metadata")


def wait_pending(pending, helpers, env, run_id, browser_id):
    probe = base.CLIClient(helpers, env, run_id)
    probe.session = str(uuid.uuid4())
    deadline = time.monotonic() + 10
    try:
        while True:
            require(pending.poll() is None, "Recovery completed before cancellation")
            result = probe.call("browser_read", {"browser_session_id": browser_id})
            if base.is_pending_result(result):
                break
            require(time.monotonic() < deadline, "Pending recovery approval was not observed")
            time.sleep(0.05)
    finally:
        probe.close()


def close_pending(client, helpers, env, run_id, root, browser_id, arguments, previous,
                  during_auth=False, edit=False):
    phase = root / "recovery-auth-phase"
    old_phase_time = phase.stat().st_mtime_ns if phase.exists() else 0
    operation, options = client.options("browser_recover", arguments)
    pending = client.start(operation, options)
    wait_pending(pending, helpers, env, run_id, browser_id)
    require(not [e for e in base.read_history(root) if e["id"] not in previous],
            "Recovery was decided before cancellation")
    if during_auth:
        print("READY: click Allow Once, but DO NOT complete Touch ID/password; waiting for native auth.", flush=True)
        deadline = time.monotonic() + 110
        while not (phase.exists() and phase.stat().st_mtime_ns > old_phase_time
                   and phase.read_text() == "pending"):
            require(pending.poll() is None and time.monotonic() < deadline,
                    "Native authentication phase was not observed")
            time.sleep(0.02)
    if edit:
        print("READY: save the open native recovery editor with label suffix ' (edited)'.", flush=True)
        deadline = time.monotonic() + 110
        while json.loads((root / "metadata.json").read_text())["credentials"] == \
                json.loads((root / "acceptance-before-edit.json").read_text())["credentials"]:
            require(pending.poll() is None and time.monotonic() < deadline, "Native edit was not observed")
            time.sleep(0.05)
    started = time.monotonic()
    if not edit:
        result = client.call("browser_close", {"browser_session_id": browser_id})
        require(not result.get("isError"), "Could not close pending recovery browser")
    result = client.finish(pending, operation, timeout=10)
    events = [e for e in base.read_history(root) if e["id"] not in previous]
    base.verify_immediate_rejection(result, events, time.monotonic() - started)
    if during_auth:
        deadline = time.monotonic() + 5
        while phase.read_text() != "ended":
            require(time.monotonic() < deadline, "Native authentication did not end after closure")
            time.sleep(0.02)
        print("PASS: native authentication was pending, then cancelled by browser closure.", flush=True)


def restart_submitting(client, root, browser_id, arguments, initial_posts):
    old_boot = (root / "recovery-boot-id").read_text()
    pid = int((root / "app-pid").read_text())
    expected = str(root / "AgentKeyBox QA.app/Contents/MacOS/AgentKeyBox")
    command = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "comm="], text=True).strip()
    require(command == expected, "Refusing to interrupt an unrelated process")
    mode, release = root / "server-event.mode", root / "server-event.release"
    restart = root / "restart-on-exit"
    mode.write_text("hold")
    release.unlink(missing_ok=True)
    operation, options = client.options("browser_recover", arguments)
    pending = client.start(operation, options)
    try:
        deadline = time.monotonic() + 160
        while True:
            path = root / "server-event.ledger"
            ledger = json.loads(path.read_text()) if path.exists() else []
            if len(ledger) == initial_posts + 1:
                verify_ledger(root, initial_posts + 1)
                break
            require(pending.poll() is None and time.monotonic() < deadline, "Held recovery POST was not observed")
            time.sleep(0.02)
        restart.write_text("native recovery lifecycle acceptance")
        os.kill(pid, signal.SIGKILL)
        deadline = time.monotonic() + 30
        while (root / "recovery-boot-id").read_text() == old_boot:
            require(time.monotonic() < deadline, "Same-profile restart was not observed")
            time.sleep(0.05)
        require(int((root / "app-pid").read_text()) != pid, "QA process did not change")
        require(json.loads((root / "recovery-statuses.json").read_text()) ==
                expected_statuses(initial_posts + 1), "Reservation was lost after Keychain readback")
        release.write_text("release held synthetic POST")
        result = client.finish(pending, operation, timeout=15)
        require(result.get("isError") is True, "Interrupted request unexpectedly succeeded")
        # Positive control: the restarted broker responds; an unavailable socket cannot pass.
        client.initialize()
        print("PASS: killed QA process during POST; fresh boot preserved Keychain reservation.", flush=True)
    finally:
        release.write_text("release held synthetic POST")
        mode.unlink(missing_ok=True)
        restart.unlink(missing_ok=True)


def run(args):
    profile = str(args.profile).upper()
    root = Path("/private/tmp") / ("akb-qa-" + profile)
    require(root.is_dir() and not root.is_symlink(), "Isolated recovery fixture is not running")
    config = json.loads((root / "recovery-fixture.json").read_text())
    require(config.get("profileID") == profile and type(config.get("port")) is int
            and 1024 <= config["port"] <= 65535, "Invalid loopback fixture configuration")
    origin = "https://127.0.0.1:" + str(config["port"])
    helpers = root / "AgentKeyBox QA.app/Contents/Helpers"
    for name in ("agentkeybox-mcp", "akb"):
        require((helpers / name).resolve().is_relative_to(root), "Helper escaped isolated profile")
        require(b"Invalid AgentKeyBox QA profile ID" in (helpers / name).read_bytes(),
                "Release helpers cannot run this fixture")
    before = json.loads((root / "metadata.json").read_text())
    base.check_output(before)
    items = {item["id"]: item for item in before["credentials"]}
    recovery_id = base.fixture_id(args.profile, 2)
    validate_linked_fixture(items, profile, recovery_id, origin)
    initial_statuses = json.loads((root / "recovery-statuses.json").read_text())
    marker = root / "server-event.recovery"
    initial_posts = int(marker.read_text()) if marker.exists() else 0
    require(initial_statuses == expected_statuses(initial_posts),
            "Fixture has an unexpected prior result")
    sends_post = args.expect in ("allowed", "restart-submitting")
    require(not sends_post or initial_posts < CODE_COUNT, "No unused synthetic code remains")
    verify_reservation(root, before, False, initial_statuses, initial_posts)
    run_id = str(uuid.uuid4())
    project = str(Path.cwd().resolve())
    env = dict(os.environ, AGENTKEYBOX_QA_ID=profile, AGENTKEYBOX_PROJECT_PATH=project)
    env.pop("AGENTKEYBOX_SESSION_ID", None)
    client = (base.MCPClient if args.transport == "mcp" else base.CLIClient)(helpers, env, run_id)
    browser_id = None
    try:
        client.initialize()
        if args.transport == "mcp":
            verify_listing(client.call("list_credentials", {}), profile, recovery_id, initial_posts)
        previous = {e["id"] for e in base.read_history(root)}
        print(f"READY: {args.transport} recovery/{args.expect}; first approve QA local login "
              "and complete normal local authentication.", flush=True)
        result = client.call("browser_login", {
            "credential_id": profile,
            "purpose": "QA 本機復原碼測試：先核准合成帳號登入並完成本機驗證"})
        # Keep a handle for cleanup even when the returned page fails the challenge assertion.
        if not result.get("isError"):
            text = base.result_text(result)
            require("{" in text, "Login response has no browser identity")
            browser_id = str(uuid.UUID(json.loads(text[text.index("{"):])["sessionID"]))
        page = challenge_result(result, origin)
        browser_id = page["sessionID"]
        events = base.matching_events(base.read_history(root), previous, client.agent_name, profile, project)
        require(len(events) == 1 and events[0]["decision"] == "allowOnce", "Login approval evidence missing")
        challenge_result(client.call("browser_read", {"browser_session_id": browser_id}), origin, browser_id)
        verify_reservation(root, before, False, initial_statuses, initial_posts)
        print("PASS: native-approved login returns only fixed recovery challenge; no code POST.", flush=True)
        # Let the operator finish UI inspection before opening the separately approved step.
        require(input("READY: type START to request the recovery step: ").strip() == "START",
                "Recovery step was not started")
        purposes = {
            "allowed": "QA 復原碼成功測試：請核准使用一組合成碼並完成本機驗證",
            "denied": "QA 復原碼拒絕測試：請按拒絕，不要核准",
            "timeout": "QA 復原碼逾時測試：請不要操作，等待 120 秒自動結束",
            "close-pending": "QA 復原碼終止測試：請不要操作，測試端會關閉瀏覽器",
            "close-auth": "QA 驗證中止測試：按核准後不要完成 Touch ID，測試端將取消",
            "edit-pending": "QA 編輯中止測試：不要核准此要求，請儲存原生編輯視窗",
            "restart-submitting": "QA 復原碼重啟測試：請核准並完成驗證，送出後將重啟 QA App",
        }
        arguments = {"browser_session_id": browser_id, "credential_id": recovery_id,
                     "purpose": purposes[args.expect]}
        previous = {e["id"] for e in base.read_history(root)}
        started = time.monotonic()
        if args.expect in ("close-pending", "close-auth", "edit-pending"):
            if args.expect == "edit-pending":
                (root / "acceptance-before-edit.json").write_text(json.dumps(before))
            close_pending(client, helpers, env, run_id, root, browser_id, arguments, previous,
                          during_auth=args.expect == "close-auth", edit=args.expect == "edit-pending")
        elif args.expect == "restart-submitting":
            restart_submitting(client, root, browser_id, arguments, initial_posts)
            events = base.matching_events(base.read_history(root), previous, client.agent_name,
                                         recovery_id, project)
            require(len(events) == 1 and events[0]["decision"] == "allowOnce",
                    "Interrupted submission lacks its separate native approval")
        else:
            result = client.call("browser_recover", arguments)
            elapsed = time.monotonic() - started
            events = base.matching_events(base.read_history(root), previous, client.agent_name,
                                         recovery_id, project)
            if args.expect in ("denied", "timeout"):
                base.verify_refusal(args.expect, result, events, elapsed)
                print(f"PASS: native {args.expect} decision after {elapsed:.2f} seconds.", flush=True)
            else:
                require(len(events) == 1 and events[0]["decision"] == "allowOnce",
                        "Separate recovery approval evidence missing")
                base.page_result(result, browser_id, "Recovery verified. Task result: 7 open issues.")
                base.page_result(client.call("browser_read", {"browser_session_id": browser_id}),
                                 browser_id, "Recovery verified.")
                result = client.call("browser_close", {"browser_session_id": browser_id})
                require(not result.get("isError"), "Could not close completed browser")
        verify_reservation(root, before, sends_post, initial_statuses, initial_posts,
                           edited=args.expect == "edit-pending")
        result = client.call("browser_read", {"browser_session_id": browser_id})
        require(result.get("isError") is True and not base.is_pending_result(result),
                "Closed recovery browser still readable or approval slot remained occupied")
        browser_id = None
        print(f"PASS: {args.transport} recovery {args.expect}; exact native evidence, "
              f"{'one durable reservation before one POST' if sends_post else 'no additional reservation or POST'}, "
              "no synthetic secret in output/history; session closed.", flush=True)
    finally:
        try:
            if browser_id:
                client.call("browser_close", {"browser_session_id": browser_id})
        finally:
            client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=uuid.UUID)
    parser.add_argument("--transport", choices=["mcp", "cli"], default="mcp")
    parser.add_argument("--expect", choices=["allowed", "denied", "timeout", "close-pending",
                                             "close-auth", "edit-pending", "restart-submitting"],
                        default="allowed")
    args = parser.parse_args()
    if args.expect in ("close-pending", "close-auth", "edit-pending", "restart-submitting") and args.transport != "cli":
        parser.error("Lifecycle cases require separate CLI processes")
    try:
        run(args)
    except RuntimeError as error:
        print(f"FAIL: {error}", flush=True)
        raise SystemExit(1) from None
    except (ValueError, KeyError, OSError, EOFError, subprocess.SubprocessError) as error:
        print(f"FAIL: {type(error).__name__}: native recovery acceptance incomplete.", flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
