#!/usr/bin/env python3
"""Native protected-field acceptance: synthetic values, exact loopback destinations, no payments."""
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

spec = importlib.util.spec_from_file_location("acceptance", Path(__file__).with_name("browser-acceptance-client.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
require = base.require
CASES = {
    "card-form": ("card", "form", "selected", "received"),
    "card-json": ("card", "json", "all", "received"),
    "code-received": ("recovery", "form", "code", "received"),
    "code-rejected": ("recovery", "json", "code", "rejected"),
    "code-redirect": ("recovery", "form", "code", "redirect"),
    "code-unknown": ("recovery", "json", "code", "unknown"),
    "code-restart": ("recovery", "form", "code", "hold"),
}
NOTE = "QA order + & 中文"
FIXED_SUFFIX = ("\nOnly a transport outcome is available; it does not confirm payment or sign-in success. "
                "No response content is returned. A reserved recovery code stays unavailable until "
                "reviewed by the user. Do not automatically retry.")
UNKNOWN_ERROR = ("Submission outcome is unknown. Check the destination before retrying; "
                 "a recovery code may already have been reserved or consumed.")


def statuses(count):
    require(type(count) is int and 0 <= count <= 8, "Unexpected issued-code count")
    return ["issued"] * count + ["available"] * (8 - count)


def read_ledger(root):
    path = root / "submission-ledger.json"
    result = json.loads(path.read_text()) if path.exists() else []
    base.check_output(result)
    require(isinstance(result, list), "Invalid receiver evidence")
    return result


def code_count(ledger):
    codes = [entry for entry in ledger if entry.get("kind") == "recovery"]
    for index, entry in enumerate(codes):
        require(type(entry.get("codeIndex")) is int and entry["codeIndex"] == index
                and entry.get("persistedBeforePost") is True and entry.get("duplicate") is False,
                "Codes were not durably reserved in order without reuse")
    return len(codes)


def verify_result(result, mode):
    base.check_output(result)
    if mode == "hold":
        require(result.get("isError") is True and base.result_text(result) == UNKNOWN_ERROR,
                "Interrupted submission was not reported as the exact unknown outcome")
    else:
        outcome = "redirectBlocked" if mode == "redirect" else mode
        require(not result.get("isError") and base.result_text(result) == "outcome=" + outcome + FIXED_SUFFIX,
                "Submission did not return only its expected fixed transport outcome")


def verify_receipt(root, before, previous, config):
    ledger = read_ledger(root)
    require(len(ledger) == len(previous) + 1 and ledger[:-1] == previous,
            "Expected exactly one new POST with previous evidence preserved")
    count = code_count(previous)
    is_code = config["kind"] == "recovery"
    expected = {"caseID": config["caseID"], "kind": config["kind"], "encoding": config["encoding"],
                "exactFields": True, "expectedContentType": True, "noCredentialsOrCookies": True,
                "codeIndex": count if is_code else None,
                "persistedBeforePost": True if is_code else None, "duplicate": False}
    entry = ledger[-1]
    require(entry == expected and all(entry.get(key) is True for key in
            ("exactFields", "expectedContentType", "noCredentialsOrCookies"))
            and entry.get("duplicate") is False, "Receiver rejected the exact fields or privacy invariants")
    require(code_count(ledger) == count + int(is_code), "Unexpected reservation count")
    require(json.loads((root / "submission-statuses.json").read_text()) == statuses(count + int(is_code)),
            "Persisted code statuses do not match unique POSTs")
    require(not (root / "submission-unexpected-request").exists(), "Redirect or unexpected request was followed")
    current = json.loads((root / "metadata.json").read_text())
    base.check_output(current)
    if is_code:
        old = {item["id"]: item for item in before["credentials"]}
        for item in current["credentials"]:
            if item["kind"] == "recoveryCodes":
                require(item["id"] in old, "Unexpected metadata item")
                item["updatedAt"] = old[item["id"]]["updatedAt"]
    require(current == before, "Submission unexpectedly changed metadata or item revision")


def crash_during_post(client, root, arguments, previous):
    pid = int((root / "app-pid").read_text())
    executable = str(root / "AgentKeyBox QA.app/Contents/MacOS/AgentKeyBox")
    command = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "comm="], text=True).strip()
    require(command == executable, "Refusing to interrupt an unrelated process")
    boot = (root / "submission-boot-id").read_text()
    release, restart = root / "submission-release", root / "restart-on-exit"
    release.unlink(missing_ok=True)
    pool = ThreadPoolExecutor(max_workers=1)
    pending = pool.submit(client.call, "submit_sensitive_fields", arguments)
    try:
        deadline = time.monotonic() + 160
        while len(read_ledger(root)) == len(previous):
            require(not pending.done() and time.monotonic() < deadline, "Held submission was not observed")
            time.sleep(0.02)
        count = code_count(read_ledger(root))
        require(count == code_count(previous) + 1, "No durable reservation before crash")
        restart.write_text("protected-field native lifecycle acceptance")
        os.kill(pid, signal.SIGKILL)
        deadline = time.monotonic() + 30
        while (root / "submission-boot-id").read_text() == boot:
            require(time.monotonic() < deadline, "Same-profile restart did not finish")
            time.sleep(0.05)
        require(int((root / "app-pid").read_text()) != pid, "QA process did not change")
        require(json.loads((root / "submission-statuses.json").read_text()) == statuses(count),
                "Keychain readback lost the reservation after restart")
        release.write_text("release synthetic held response")
        result = pending.result(timeout=15)
        # Positive control: the new broker must respond; a dead socket is not acceptance.
        probe = client.call("list_credentials", {})
        require(not probe.get("isError"), "Restarted broker did not respond")
        print("PASS: interrupted QA after durable POST receipt; fresh boot retained Keychain state.", flush=True)
        return result
    finally:
        release.write_text("release synthetic held response")
        restart.unlink(missing_ok=True)
        if not pending.done():
            client.close()
        pool.shutdown(wait=True)


def run_case(args):
    profile = str(args.profile).upper()
    root = Path("/private/tmp") / ("akb-qa-" + profile)
    require(root.is_dir() and not root.is_symlink(), "Isolated submission fixture is not running")
    settings = json.loads((root / "submission-fixture.json").read_text())
    require(settings.get("profileID") == profile and type(settings.get("port")) is int
            and 1024 <= settings["port"] <= 65535, "Invalid isolated fixture configuration")
    helpers = root / "AgentKeyBox QA.app/Contents/Helpers"
    require((helpers / "agentkeybox-mcp").resolve().is_relative_to(root), "Helper escaped QA profile")
    require(b"Invalid AgentKeyBox QA profile ID" in (helpers / "agentkeybox-mcp").read_bytes(),
            "Release helper cannot select isolated storage")
    before = json.loads((root / "metadata.json").read_text())
    base.check_output(before)
    items = {item["id"]: item for item in before["credentials"]}
    card_id, code_id = (base.fixture_id(args.profile, offset) for offset in (1, 2))
    require(set(items) == {card_id, code_id}, "Unexpected fixture items")
    origin = "https://127.0.0.1:" + str(settings["port"])
    for identity, kind, path in [(card_id, "creditCard", "/submit/card"),
                                 (code_id, "recoveryCodes", "/submit/recovery")]:
        require(items[identity]["kind"] == kind and items[identity].get("submissionURL") == origin + path,
                "Item is not bound to its exact fixture destination")
    previous = read_ledger(root)
    count = code_count(previous)
    require(json.loads((root / "submission-statuses.json").read_text()) == statuses(count),
            "Initial persisted status differs from receiver evidence")
    kind, encoding, selection, mode = CASES[args.case]
    require(kind != "recovery" or count < 8, "No unused synthetic code remains")
    run_id = str(uuid.uuid4())
    config = dict(caseID=run_id, kind=kind, encoding=encoding, selection=selection, mode=mode)
    (root / "submission-case.json").write_text(json.dumps(config))
    fields = {"note": NOTE}
    if kind == "card":
        fields.update(pan="{{card.number}}", month="{{card.expiration_month}}")
        if selection == "all":
            fields.update(holder="{{card.cardholder}}", year="{{card.expiration_year}}")
    else:
        fields["code"] = "{{recovery.code}}"
    identity = card_id if kind == "card" else code_id
    project = str(Path.cwd().resolve())
    env = dict(os.environ, AGENTKEYBOX_QA_ID=profile, AGENTKEYBOX_PROJECT_PATH=project)
    env.pop("AGENTKEYBOX_SESSION_ID", None)
    client = base.MCPClient(helpers, env, run_id)
    try:
        client.initialize()
        listed = client.call("list_credentials", {})
        require(not listed.get("isError") and identity in base.result_text(listed), "Fixture discovery failed")
        events_before = {event["id"] for event in base.read_history(root)}
        arguments = {"credential_id": identity, "fields": fields, "encoding": encoding,
                     "purpose": f"QA 欄位提交測試 {args.case}：請核准並完成驗證；合成資料，只送本機，不會付款"}
        print(f"READY: {args.case}; approve this synthetic local submission and complete normal authentication.",
              flush=True)
        result = (crash_during_post(client, root, arguments, previous) if mode == "hold"
                  else client.call("submit_sensitive_fields", arguments))
        verify_result(result, mode)
        events = base.matching_events(base.read_history(root), events_before, client.agent_name, identity, project)
        require(len(events) == 1 and events[0]["decision"] == "allowOnce", "Exact separate native approval missing")
        verify_receipt(root, before, previous, config)
        print(f"PASS: {args.case}; one native approval, one exact-fields POST, fixed outcome, "
              "no reflected secrets/cookies; reservation and metadata invariants passed.", flush=True)
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=uuid.UUID)
    parser.add_argument("--case", choices=CASES, default="card-form")
    args = parser.parse_args()
    try:
        run_case(args)
    except RuntimeError as error:
        print(f"FAIL: {error}", flush=True)
        raise SystemExit(1) from None
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, TimeoutError) as error:
        print(f"FAIL: {type(error).__name__}: protected-field acceptance incomplete.", flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
