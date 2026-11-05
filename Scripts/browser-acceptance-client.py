#!/usr/bin/env python3
"""Exercise the isolated native app; never automate approval or authentication.

Refusal requires both a tool error and this request's matching native history decision.
Transport errors, unrelated events, and accidental approvals must not pass.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import select
import subprocess
import time
import urllib.parse
import uuid

SYNTHETIC_VALUES = (
    "tomsmith", "SuperSecretPassword!", "4242424242424242",
    "AKB synthetic card fixture", "akb-qa-code-one", "akb-qa-code-two",
    "fixture-user", "synthetic-password-42!", "fixture-recovery-001", "fixture-recovery-002",
    "fixture-recovery-003", "fixture-recovery-004",
    *(f"fixture-submit-code-{index:03}" for index in range(1, 9)), "fixture-submit-cookie",
    "fixture-session-cookie", "verified-cookie", "private-recovery-csrf", "CHALLENGE_PRIVATE_TEXT",
)
KINDS = {"login": (0, "login"), "card": (1, "creditCard"), "recovery": (2, "recoveryCodes")}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def check_output(value):
    text = value if isinstance(value, str) else json.dumps(value)
    for secret in SYNTHETIC_VALUES:
        variants = {secret, urllib.parse.quote(secret, safe=""),
                    urllib.parse.quote_plus(secret), base64.b64encode(secret.encode()).decode()}
        require(not any(candidate in text for candidate in variants),
                "Synthetic secret appeared in an observation surface")


def fixture_id(profile, offset):
    data = bytearray(profile.bytes)
    data[-1] ^= offset
    return str(uuid.UUID(bytes=bytes(data))).upper()


def result_text(result):
    return "\n".join(block.get("text", "") for block in result.get("content", []))


def page_result(result, browser_id=None, marker=None):
    require(not result.get("isError"), "Expected a controlled page, received an error")
    text = result_text(result)
    require("{" in text, "Controlled page result is missing")
    page = json.loads(text[text.index("{"):])
    check_output(page)
    require(page.get("status") == "pageReady", "Controlled page is not ready")
    require(browser_id is None or page.get("sessionID") == browser_id,
            "Result belongs to a different browser")
    require(marker is None or marker in page.get("text", ""), "Expected page was not reached")
    return page


def logout_link(page):
    links = [link for link in page["links"] if link["text"].strip() == "Logout"]
    require(len(links) == 1, "Expected the public fixture's single Logout link")
    return str(uuid.UUID(links[0]["id"]))


def verify_immediate_rejection(result, events, elapsed):
    require(result.get("isError") is True, "Expected the request to be rejected")
    require(elapsed < 10, "Request was not rejected promptly")
    require(not events, "Rejected request unexpectedly recorded an approval decision")


def is_pending_result(result):
    return (result.get("isError") is True and result_text(result).strip() ==
            "Another AgentKeyBox approval is already pending.")


def read_history(root):
    path = root / "access-log.json"
    events = json.loads(path.read_text()) if path.exists() else []
    check_output(events)
    return events


def matching_events(events, previous_ids, agent_name, credential_id, project):
    return [event for event in events
            if event["id"] not in previous_ids and event.get("agentDisplayName") == agent_name
            and event.get("credentialIDs") == [credential_id]
            and event.get("projectPath") == project]


def verify_refusal(expected, result, events, elapsed):
    require(result.get("isError") is True, "Expected refusal, but operation was approved")
    require(len(events) == 1, "Expected exactly one matching native approval-history event")
    decision = "deny" if expected == "denied" else "timedOut"
    require(events[0].get("decision") == decision,
            "Native decision differs from the requested test case")
    if expected == "timeout":
        require(elapsed >= 119, "Timeout completed before the real 120-second approval deadline")
        require(result_text(result).strip() == "Approval timed out.",
                "Native approval timeout was not reported distinctly from transport failure")


class MCPClient:
    def __init__(self, helpers, env, run_id):
        self.agent_name = "QA " + run_id[:8]
        env = dict(env, AGENTKEYBOX_AGENT_ID="native-qa-" + run_id,
                   AGENTKEYBOX_AGENT_NAME=self.agent_name,
                   AGENTKEYBOX_SESSION_ID=env.get("AGENTKEYBOX_SESSION_ID", run_id))
        self.process = subprocess.Popen(
            [str(helpers / "agentkeybox-mcp")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, env=env, bufsize=0)
        self.sequence = 0
        self.buffer = b""

    def rpc(self, method, params):
        self.sequence += 1
        message = json.dumps({"jsonrpc": "2.0", "id": self.sequence,
                              "method": method, "params": params}) + "\n"
        self.process.stdin.write(message.encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 210
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            require(remaining > 0 and select.select([self.process.stdout], [], [], remaining)[0],
                    "QA helper response timed out")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            require(bool(chunk), "QA helper ended before responding")
            self.buffer += chunk
            require(len(self.buffer) <= 2 * 1024 * 1024, "QA response exceeded its size limit")
        line, self.buffer = self.buffer.split(b"\n", 1)
        response = json.loads(line)
        check_output(response)
        require(response.get("id") == self.sequence and "error" not in response,
                "MCP protocol failure")
        return response["result"]

    def initialize(self):
        self.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                 "clientInfo": {"name": "isolated-native-qa", "version": "2"}})
        self.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.process.stdin.flush()
        tools = self.rpc("tools/list", {})
        required = {"browser_login", "browser_read", "browser_follow", "browser_close",
                    "browser_recover", "submit_sensitive_fields"}
        require(required.issubset({tool["name"] for tool in tools["tools"]}),
                "Expected protected tools were not discovered")

    def call(self, name, arguments):
        return self.rpc("tools/call", {"name": name, "arguments": arguments})

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


class CLIClient:
    agent_name = "Local agent (akb browser)"

    def __init__(self, helpers, env, run_id):
        self.executable = helpers / "akb"
        self.env = env
        self.project = env["AGENTKEYBOX_PROJECT_PATH"]
        self.session = None
        self.processes = set()

    def initialize(self):
        result = self.invoke("list", {})
        require(not result.get("isError"), "QA CLI could not list fixture logins")

    def start(self, operation, options):
        arguments = [str(self.executable), "browser", operation, "--project", self.project]
        for name, value in options.items():
            arguments.extend(["--" + name, value])
        process = subprocess.Popen(arguments, env=self.env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        self.processes.add(process)
        return process

    def finish(self, process, operation, timeout=210):
        stdout, stderr = process.communicate(timeout=timeout)
        self.processes.discard(process)
        check_output(stdout)
        check_output(stderr)
        if process.returncode:
            require(process.returncode == 1, "CLI failed outside the operation-result path")
            return {"isError": True, "content": [{"text": stderr}]}
        value = json.loads(stdout)
        if operation == "login":
            self.session = value["clientSessionID"]
        return {"content": [{"text": json.dumps(value.get("page", value))}]}

    def invoke(self, operation, options):
        return self.finish(self.start(operation, options), operation)

    def options(self, name, arguments):
        operation = name.removeprefix("browser_")
        if operation == "login":
            options = {"credential": arguments["credential_id"], "purpose": arguments["purpose"]}
        else:
            options = {"session": self.session, "browser": arguments["browser_session_id"]}
        if operation == "follow":
            options.update(link=arguments["link_id"], purpose=arguments["purpose"])
        if operation == "recover":
            options.update(credential=arguments["credential_id"], purpose=arguments["purpose"])
        return operation, options

    def call(self, name, arguments):
        operation, options = self.options(name, arguments)
        return self.invoke(operation, options)

    def close(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
        self.processes.clear()


def verify_ownership(client, helpers, env, run_id, root, page):
    browser_id = page["sessionID"]
    variants = [dict(env), dict(env, AGENTKEYBOX_PROJECT_PATH=env["AGENTKEYBOX_PROJECT_PATH"] + "/other")]
    for index, peer_env in enumerate(variants):
        peer_env["AGENTKEYBOX_SESSION_ID"] = str(uuid.uuid4()) if index == 0 else run_id
        peer = type(client)(helpers, peer_env, run_id)
        if isinstance(peer, CLIClient):
            peer.session = str(uuid.uuid4()) if index == 0 else client.session
        try:
            peer.initialize()
            previous_ids = {event["id"] for event in read_history(root)}
            for operation in ("read", "follow", "close"):
                arguments = {"browser_session_id": browser_id}
                if operation == "follow":
                    arguments.update(link_id=logout_link(page), purpose="QA owner isolation: reject")
                started = time.monotonic()
                result = peer.call("browser_" + operation, arguments)
                events = [e for e in read_history(root) if e["id"] not in previous_ids]
                verify_immediate_rejection(result, events, time.monotonic() - started)
            # Positive control: a transport failure or a broken close must not count as isolation.
            page = page_result(client.call("browser_read", {"browser_session_id": browser_id}),
                               browser_id, "Welcome to the Secure Area")
        finally:
            peer.close()
    print("PASS: wrong session/project cannot read, follow or close; original owner still reads.",
          flush=True)
    return page


def close_pending_flow(client, root, helpers, env, run_id, page):
    browser_id = page["sessionID"]
    page = verify_ownership(client, helpers, env, run_id, root, page)
    old_link = logout_link(page)
    page = page_result(client.call("browser_read", {"browser_session_id": browser_id}),
                       browser_id, "Welcome to the Secure Area")
    before = {event["id"] for event in read_history(root)}
    arguments = {"browser_session_id": browser_id, "link_id": old_link,
                 "purpose": "QA stale link: reject without approval"}
    started = time.monotonic()
    rejected = client.call("browser_follow", arguments)
    verify_immediate_rejection(rejected, [e for e in read_history(root) if e["id"] not in before],
                               time.monotonic() - started)
    print("PASS: stale link rejected without approval.", flush=True)
    arguments.update(link_id=logout_link(page))
    arguments["purpose"] = "QA 終止測試：請不要核准；測試端將關閉這個瀏覽器"
    operation, options = client.options("browser_follow", arguments)
    require(input("READY: next prompt must stay unanswered; type START to open it: ").strip()
            == "START", "Pending-close test was not started")
    pending = client.start(operation, options)
    # A read by a different owner cannot create a prompt or alter this browser. The
    # exact busy response proves that the only other in-flight call holds the approval
    # slot. Do not assume a sleep or a still-running subprocess proves a pending prompt.
    probe = CLIClient(helpers, env, run_id)
    probe.session = str(uuid.uuid4())
    deadline = time.monotonic() + 10
    try:
        while True:
            require(pending.poll() is None, "Follow completed before cancellation")
            observed = probe.call("browser_read", {"browser_session_id": browser_id})
            if is_pending_result(observed):
                break
            require(time.monotonic() < deadline, "Pending approval was not observed")
            time.sleep(0.05)
    finally:
        probe.close()
    require(not [e for e in read_history(root) if e["id"] not in before],
            "Follow was decided before cancellation")
    print("OBSERVED: pending approval slot; closing the same browser now.", flush=True)
    started = time.monotonic()
    closed = client.call("browser_close", {"browser_session_id": browser_id})
    require(not closed.get("isError"), "Closing the pending browser failed")
    try:
        result = client.finish(pending, "follow", timeout=10)
    except subprocess.TimeoutExpired:
        raise RuntimeError("Closing the browser left its approval request pending") from None
    verify_immediate_rejection(result, [e for e in read_history(root) if e["id"] not in before],
                               time.monotonic() - started)
    print("PASS: closing the browser cancels its pending approval immediately.", flush=True)


def run(args):
    profile = str(args.profile).upper()
    root = Path("/private/tmp") / ("akb-qa-" + profile)
    helpers = root / "AgentKeyBox QA.app/Contents/Helpers"
    require(root.is_dir() and not root.is_symlink(), "Isolated QA profile is not running")
    for product in ("agentkeybox-mcp", "akb"):
        require((helpers / product).resolve().is_relative_to(root),
                "Refusing a helper outside the isolated QA directory")
        require(b"Invalid AgentKeyBox QA profile ID" in (helpers / product).read_bytes(),
                "Refusing a release helper that cannot select the QA profile")
    metadata_path = root / "metadata.json"
    metadata_before = metadata_path.read_bytes()
    check_output(metadata_before.decode())
    metadata = json.loads(metadata_before)
    offset, kind = KINDS[args.kind]
    credential_id = fixture_id(args.profile, offset)
    items = [item for item in metadata["credentials"] if item["id"] == credential_id]
    require(len(items) == 1 and items[0]["kind"] == kind, "Expected QA fixture is missing")
    item = items[0]
    if args.kind == "login":
        require(item.get("loginURL") == "https://the-internet.herokuapp.com/login",
                "Refusing a non-fixture sign-in destination")
    else:
        suffix = "card" if args.kind == "card" else "recovery"
        require(item.get("submissionURL") == "https://akb-acceptance.invalid/" + suffix,
                "Refusing a reachable card/recovery-code destination")

    run_id = str(uuid.uuid4())
    project = str(Path.cwd().resolve())
    env = dict(os.environ, AGENTKEYBOX_QA_ID=profile, AGENTKEYBOX_PROJECT_PATH=project)
    env.pop("AGENTKEYBOX_SESSION_ID", None)
    client = (MCPClient if args.transport == "mcp" else CLIClient)(helpers, env, run_id)
    browser_id = None
    try:
        client.initialize()
        previous_ids = {event["id"] for event in read_history(root)}
        purpose = {
            "allowed": "QA 登入測試：請核准公開示範帳號登入，並完成本機驗證",
            "denied": "QA 拒絕測試：請按拒絕，不要核准",
            "timeout": "QA 逾時測試：請不要操作，等待 120 秒自動結束",
            "busy": "QA: concurrent request must be rejected without another prompt",
        }[args.expect]
        arguments = {"credential_id": credential_id, "purpose": purpose}
        if args.kind != "login":
            arguments["fields"] = ({"number": "{{card.number}}"} if args.kind == "card"
                                   else {"code": "{{recovery.code}}"})
        print(f"READY: {args.transport} {args.kind} / {args.expect}; agent {client.agent_name}",
              flush=True)
        started = time.monotonic()
        result = client.call("browser_login" if args.kind == "login" else
                             "submit_sensitive_fields", arguments)
        elapsed = time.monotonic() - started
        check_output(result)
        # Close any accidentally approved browser before failing the requested refusal test.
        if args.kind == "login" and not result.get("isError"):
            page = page_result(result)
            browser_id = page["sessionID"]
        events = matching_events(read_history(root), previous_ids, client.agent_name,
                                 credential_id, project)
        if args.expect in ("denied", "timeout"):
            verify_refusal(args.expect, result, events, elapsed)
            require(metadata_path.read_bytes() == metadata_before,
                    "Refusal unexpectedly changed fixture metadata")
            print(f"PASS: {args.transport} {args.kind} {args.expect}; "
                  f"native history={events[0]['decision']}; {elapsed:.1f}s; metadata unchanged.",
                  flush=True)
        elif args.expect == "busy":
            require(result.get("isError") is True and
                    "Another AgentKeyBox approval is already pending." in result_text(result),
                    "Expected explicit concurrent-approval rejection")
            require(not events and elapsed < 15, "Concurrent request entered an approval flow")
            print("PASS: concurrent helper rejected before a second approval.", flush=True)
        else:
            require(browser_id is not None, "Approved login did not return a browser session")
            require(len(events) == 1 and events[0]["decision"] == "allowOnce",
                    "Expected one matching native allow-once event")
            require("Welcome to the Secure Area" in page["text"], "Protected page not reached")
            page = page_result(client.call("browser_read", {"browser_session_id": browser_id}),
                               browser_id, "Welcome to the Secure Area")
            print(f"PASS: {args.transport} native-approved login reaches and reads protected page.",
                  flush=True)
            if args.flow != "login":
                close_pending_flow(client, root, helpers, env, run_id, page)
            if args.flow == "login":
                closed = client.call("browser_close", {"browser_session_id": browser_id})
                require(not closed.get("isError"), "Close failed")
            rejected = client.call("browser_read", {"browser_session_id": browser_id})
            require(rejected.get("isError") is True, "Closed session still readable")
            require(not is_pending_result(rejected), "Closing did not release the approval slot")
            require(metadata_path.read_bytes() == metadata_before,
                    "Browser operations unexpectedly changed fixture metadata")
            browser_id = None
            print("PASS: close ends access and later read is rejected.", flush=True)
    finally:
        try:
            if browser_id:
                client.call("browser_close", {"browser_session_id": browser_id})
        finally:
            client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=uuid.UUID)
    parser.add_argument("--expect", choices=["allowed", "denied", "timeout", "busy"],
                        default="allowed")
    parser.add_argument("--kind", choices=KINDS, default="login")
    parser.add_argument("--transport", choices=["mcp", "cli"], default="mcp")
    parser.add_argument("--flow", choices=["login", "close-pending"], default="login")
    args = parser.parse_args()
    if args.kind != "login" and (args.transport != "mcp" or args.expect not in ("denied", "timeout")):
        parser.error("Card/recovery fixtures support only MCP denial and timeout checks")
    if args.expect == "busy" and args.transport != "mcp":
        parser.error("The busy probe requires MCP's explicit rejection message")
    if args.flow != "login" and (args.kind != "login" or args.expect != "allowed"):
        parser.error("The close-pending flow requires an allowed login fixture")
    if args.flow == "close-pending" and args.transport != "cli":
        parser.error("Concurrent close requires separate CLI processes in the same owner session")
    try:
        run(args)
    except RuntimeError as error:
        # RuntimeError messages are our fixed assertions, never upstream diagnostics.
        print(f"FAIL: {error}", flush=True)
        raise SystemExit(1) from None
    except (ValueError, KeyError, OSError, EOFError, subprocess.SubprocessError) as error:
        # Do not print subprocess output, decoded payloads, or fixture values on failure.
        print(f"FAIL: {type(error).__name__}: acceptance did not meet its requested outcome.",
              flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
