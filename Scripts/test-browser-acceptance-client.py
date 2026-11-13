#!/usr/bin/env python3
"""Regression checks for false-positive native acceptance results; no app or secrets needed."""
import importlib.util
from pathlib import Path
import unittest
import tempfile

spec = importlib.util.spec_from_file_location(
    "acceptance", Path(__file__).with_name("browser-acceptance-client.py"))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)

recovery_spec = importlib.util.spec_from_file_location(
    "recovery", Path(__file__).with_name("recovery-acceptance-client.py"))
recovery = importlib.util.module_from_spec(recovery_spec)
recovery_spec.loader.exec_module(recovery)

submission_spec = importlib.util.spec_from_file_location(
    "submission", Path(__file__).with_name("submission-acceptance-client.py"))
submission = importlib.util.module_from_spec(submission_spec)
submission_spec.loader.exec_module(submission)

storage_spec = importlib.util.spec_from_file_location(
    "storage", Path(__file__).with_name("storage-acceptance-client.py"))
storage = importlib.util.module_from_spec(storage_spec)
storage_spec.loader.exec_module(storage)


backup_spec = importlib.util.spec_from_file_location(
    "backup", Path(__file__).with_name("inspect-submission-backup.py"))
backup = importlib.util.module_from_spec(backup_spec)
backup_spec.loader.exec_module(backup)


class AcceptanceResultTests(unittest.TestCase):
    def test_submission_allowlist_and_backup_with_optional_project_card(self):
        profile = acceptance.uuid.uuid4()
        origin = "https://127.0.0.1:45678"
        identities = [acceptance.fixture_id(profile, n) for n in (1, 2, 3, 4)]
        items = [dict(id=identity, kind=kind, submissionURL=origin + path, payloadRevision="revision")
                 for identity, kind, path in [(identities[0], "creditCard", "/submit/card"),
                                              (identities[1], "recoveryCodes", "/submit/recovery"),
                                              (identities[2], "creditCard", "/submit/card")]]
        items[2]["projectID"] = identities[3]
        for count in (2, 3):
            selected = items[:count]
            self.assertEqual(set(submission.validate_items(profile, selected, origin)), set(identities[:count]))
            contents = {"credentials": selected, "secrets": {}}
            files = []
            for item in selected:
                payload = {"revision": "revision"}
                if item["kind"] == "creditCard":
                    payload["card"] = dict(number="4242424242424242", cardholder="AKB synthetic card fixture",
                                           expirationMonth=12, expirationYear=2099)
                    files.append(Path(item["id"] + ".card.json"))
                else:
                    payload["recoveryCodes"] = {"entries": [dict(value=f"fixture-submit-code-{n:03}",
                                                               status="available") for n in range(1, 9)]}
                    files.append(Path(item["id"] + ".recovery-codes.json"))
                contents["secrets"][item["id"]] = backup.base64.b64encode(acceptance.json.dumps(payload).encode()).decode()
            backup.verify_contents(profile, origin, contents, submission.statuses(0), files)
            with self.assertRaises(RuntimeError):
                backup.verify_contents(profile, origin, contents, submission.statuses(0), files[:-1])
        for invalid in [items + [dict(items[0], id=str(acceptance.uuid.uuid4()))],
                        items + [items[0]], items[:1],
                        items[:2] + [dict(items[2], projectID=None)],
                        items[:2] + [dict(items[2], kind="recoveryCodes")],
                        items[:2] + [dict(items[2], submissionURL=origin + "/other")]]:
            with self.assertRaises(RuntimeError):
                submission.validate_items(profile, invalid, origin)
            with self.assertRaises(RuntimeError):
                backup.verify_contents(profile, origin, dict(contents, credentials=invalid),
                                       submission.statuses(0), files)

    def advance_reservation(self, root, before):
        current = acceptance.json.loads(acceptance.json.dumps(before))
        current["credentials"][0].update(updatedAt=2, payloadRevision=str(acceptance.uuid.uuid4()))
        (root / "metadata.json").write_text(acceptance.json.dumps(current))
        return current

    def test_storage_cancellation_distinguishes_native_auth_from_transport_failures(self):
        for mode, expected in [("auth-cancel", storage.DENIED), ("edit-pending", submission.UNKNOWN_ERROR),
                               ("remove-project-pending", submission.UNKNOWN_ERROR)]:
            result = {"isError": True, "content": [{"text": expected}]}
            storage.verify_cancel(result, [], mode)
            for invalid in [dict(result, isError=False),
                            {"isError": True, "content": [{"text": "Approval timed out."}]},
                            {"isError": True, "content": [{"text": expected + " extra"}]}]:
                with self.assertRaises(RuntimeError):
                    storage.verify_cancel(invalid, [], mode)
            with self.assertRaises(RuntimeError):
                storage.verify_cancel(result, [{"decision": "allowOnce"}], mode)

    def test_project_removal_requires_exact_project_and_all_its_items(self):
        before = {"projects": [{"id": "removed"}, {"id": "kept"}], "credentials": [
            {"id": "card", "projectID": "removed"}, {"id": "codes", "projectID": "removed"},
            {"id": "global"}, {"id": "other", "projectID": "kept"}]}
        after = {"projects": [{"id": "kept"}], "credentials": before["credentials"][2:]}
        storage.verify_project_removal(before, after, "card")
        for invalid in [before, dict(after, projects=[]), dict(after, credentials=[]),
                        dict(after, credentials=before["credentials"][1:])]:
            with self.assertRaises(RuntimeError):
                storage.verify_project_removal(before, invalid, "card")
        with self.assertRaises(RuntimeError):
            storage.verify_project_removal(before, after, "global")

    def test_native_edit_evidence_requires_new_revision_and_preserves_other_metadata(self):
        before = {"projects": [], "credentials": [{"id": "card", "label": "Card", "payloadRevision": "old",
                                                    "updatedAt": 1, "submissionURL": "https://example.com/post"}]}
        item = dict(before["credentials"][0], label="Card (edited)", payloadRevision="new", updatedAt=2)
        storage.verify_edit(before, {"projects": [], "credentials": [item]}, "card")
        for bad in [dict(item, payloadRevision="old"), dict(item, label="Other"), dict(item, updatedAt=1),
                    dict(item, submissionURL="https://other.example/post")]:
            with self.assertRaises(RuntimeError):
                storage.verify_edit(before, {"projects": [], "credentials": [bad]}, "card")

    def test_cancelled_storage_request_cannot_change_receipts_or_code_statuses(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "submission-statuses.json"
            path.write_text(acceptance.json.dumps(submission.statuses(0)))
            storage.verify_no_send(root, [], submission.statuses(0))
            path.write_text(acceptance.json.dumps(submission.statuses(1)))
            with self.assertRaises(RuntimeError):
                storage.verify_no_send(root, [], submission.statuses(0))
            path.write_text(acceptance.json.dumps(submission.statuses(0)))
            (root / "submission-ledger.json").write_text('[{"kind":"card"}]')
            with self.assertRaises(RuntimeError):
                storage.verify_no_send(root, [], submission.statuses(0))

    def test_submission_results_are_exact_fixed_outcomes_including_unknown(self):
        for mode in ("received", "rejected", "redirect", "unknown"):
            outcome = "redirectBlocked" if mode == "redirect" else mode
            result = {"content": [{"text": "outcome=" + outcome + submission.FIXED_SUFFIX}]}
            submission.verify_result(result, mode)
            for wrong in [dict(result, isError=True), {"content": [{"text": "outcome=" + outcome}]},
                          {"content": [{"text": "outcome=" + outcome + submission.FIXED_SUFFIX + " extra"}]}]:
                with self.assertRaises(RuntimeError):
                    submission.verify_result(wrong, mode)
        interrupted = {"isError": True, "content": [{"text": submission.UNKNOWN_ERROR}]}
        submission.verify_result(interrupted, "hold")
        with self.assertRaises(RuntimeError):
            submission.verify_result({"isError": True, "content": [{"text": "Approval timed out."}]}, "hold")

    def test_submission_receipt_requires_exact_fields_headers_and_single_post(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            before = {"credentials": [{"id": "card", "kind": "creditCard", "updatedAt": 1}]}
            config = {"caseID": "case", "kind": "card", "encoding": "form"}
            entry = dict(config, exactFields=True, expectedContentType=True, noCredentialsOrCookies=True,
                         codeIndex=None, persistedBeforePost=None, duplicate=False)
            (root / "metadata.json").write_text(acceptance.json.dumps(before))
            (root / "submission-statuses.json").write_text(acceptance.json.dumps(submission.statuses(0)))
            ledger = root / "submission-ledger.json"
            ledger.write_text(acceptance.json.dumps([entry]))
            submission.verify_receipt(root, before, [], config)
            for wrong in [dict(entry, exactFields=False), dict(entry, noCredentialsOrCookies=False),
                          dict(entry, expectedContentType=False), dict(entry, exactFields=1),
                          dict(entry, caseID="other"), dict(entry, encoding="json")]:
                ledger.write_text(acceptance.json.dumps([wrong]))
                with self.assertRaises(RuntimeError):
                    submission.verify_receipt(root, before, [], config)
            ledger.write_text(acceptance.json.dumps([entry, entry]))
            with self.assertRaises(RuntimeError):
                submission.verify_receipt(root, before, [], config)

    def test_submission_recovery_requires_persisted_next_code_and_no_redirect(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            before = {"credentials": [{"id": "code", "kind": "recoveryCodes", "updatedAt": 1,
                                       "payloadRevision": str(acceptance.uuid.uuid4())}]}
            config = {"caseID": "case", "kind": "recovery", "encoding": "json"}
            entry = dict(config, exactFields=True, expectedContentType=True, noCredentialsOrCookies=True,
                         codeIndex=0, persistedBeforePost=True, duplicate=False)
            (root / "metadata.json").write_text(acceptance.json.dumps(before))
            path = root / "submission-statuses.json"
            path.write_text(acceptance.json.dumps(submission.statuses(1)))
            ledger = root / "submission-ledger.json"
            ledger.write_text(acceptance.json.dumps([entry]))
            self.advance_reservation(root, before)
            submission.verify_receipt(root, before, [], config)
            (root / "metadata.json").write_text(acceptance.json.dumps(before))
            with self.assertRaises(RuntimeError):
                submission.verify_receipt(root, before, [], config)
            self.advance_reservation(root, before)
            for bad in [dict(entry, codeIndex=1), dict(entry, codeIndex=False),
                        dict(entry, persistedBeforePost=False), dict(entry, duplicate=True)]:
                ledger.write_text(acceptance.json.dumps([bad]))
                with self.assertRaises(RuntimeError):
                    submission.verify_receipt(root, before, [], config)
            ledger.write_text(acceptance.json.dumps([entry]))
            path.write_text(acceptance.json.dumps(submission.statuses(0)))
            with self.assertRaises(RuntimeError):
                submission.verify_receipt(root, before, [], config)
            path.write_text(acceptance.json.dumps(submission.statuses(1)))
            (root / "submission-unexpected-request").write_text("unexpected request")
            with self.assertRaises(RuntimeError):
                submission.verify_receipt(root, before, [], config)

    def test_recovery_challenge_must_be_fixed_and_bound_to_the_session(self):
        browser = str(acceptance.uuid.uuid4())
        page = {"sessionID": browser, "status": "recoveryCodeRequired", "origin": "https://127.0.0.1:45678",
                "title": "Recovery code required", "links": [],
                "text": "Request browser_recover with a stored recovery-code item. A separate native approval "
                        "is required. No page content is available until verification completes."}
        result = lambda p: {"content": [{"text": acceptance.json.dumps(p)}]}
        self.assertEqual(recovery.challenge_result(result(page), page["origin"], browser), page)
        for changed in [dict(page, text="Website content"), dict(page, status="pageReady"),
                        dict(page, links=[{"text": "Private link"}]), dict(page, extra="private"),
                        dict(page, sessionID=str(acceptance.uuid.uuid4()))]:
            with self.assertRaises(RuntimeError):
                recovery.challenge_result(result(changed), page["origin"], browser)

    def test_native_recovery_requires_one_post_after_durable_reservation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            before = {"credentials": [{"id": "codes", "kind": "recoveryCodes", "updatedAt": 1,
                                       "payloadRevision": str(acceptance.uuid.uuid4())}]}
            (root / "metadata.json").write_text(acceptance.json.dumps(before))
            (root / "recovery-statuses.json").write_text(acceptance.json.dumps(recovery.expected_statuses(0)))
            recovery.verify_reservation(root, before, False)
            (root / "recovery-statuses.json").write_text(acceptance.json.dumps(recovery.expected_statuses(1)))
            (root / "server-event.recovery").write_text('1')
            (root / "server-event.reservation").write_text('{"persistedBeforePost": true}')
            (root / "server-event.ledger").write_text(acceptance.json.dumps([
                {"codeIndex": 0, "persistedBeforePost": True, "duplicate": False}]))
            after = self.advance_reservation(root, before)
            recovery.verify_reservation(root, before, True)
            (root / "metadata.json").write_text(acceptance.json.dumps(before))
            with self.assertRaises(RuntimeError):
                recovery.verify_reservation(root, before, True)
            (root / "metadata.json").write_text(acceptance.json.dumps(after))
            recovery.verify_reservation(root, after, False, recovery.expected_statuses(1), 1)
            (root / "recovery-statuses.json").write_text(acceptance.json.dumps(recovery.expected_statuses(2)))
            with self.assertRaises(RuntimeError):
                recovery.verify_reservation(root, before, False, recovery.expected_statuses(1), 1)
            (root / "recovery-statuses.json").write_text(acceptance.json.dumps(recovery.expected_statuses(1)))
            for evidence in ('false', 'null'):
                (root / "server-event.reservation").write_text('{"persistedBeforePost": ' + evidence + '}')
                with self.assertRaises(RuntimeError):
                    recovery.verify_reservation(root, before, True)
            (root / "server-event.reservation").write_text('{"persistedBeforePost": true}')
            (root / "server-event.recovery").write_text('2')
            with self.assertRaises(RuntimeError):
                recovery.verify_reservation(root, before, True)
            with self.assertRaises(RuntimeError):
                recovery.verify_reservation(root, before, False)

    def test_native_recovery_advances_to_next_code_and_rejects_reuse(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            before = {"credentials": [{"id": "codes", "kind": "recoveryCodes", "updatedAt": 1,
                                       "payloadRevision": str(acceptance.uuid.uuid4())}]}
            (root / "metadata.json").write_text(acceptance.json.dumps(before))
            (root / "recovery-statuses.json").write_text(acceptance.json.dumps(recovery.expected_statuses(2)))
            (root / "server-event.recovery").write_text('2')
            (root / "server-event.reservation").write_text('{"persistedBeforePost": true}')
            entries = [{"codeIndex": i, "persistedBeforePost": True, "duplicate": False} for i in range(2)]
            ledger = root / "server-event.ledger"
            ledger.write_text(acceptance.json.dumps(entries))
            self.advance_reservation(root, before)
            recovery.verify_reservation(root, before, True, recovery.expected_statuses(1), 1)
            for bad in [dict(entries[1], codeIndex=0), dict(entries[1], duplicate=True),
                        dict(entries[1], persistedBeforePost=False), dict(entries[1], codeIndex=True),
                        dict(entries[1], persistedBeforePost=1), dict(entries[1], duplicate=0)]:
                ledger.write_text(acceptance.json.dumps([entries[0], bad]))
                with self.assertRaises(RuntimeError):
                    recovery.verify_reservation(root, before, True, recovery.expected_statuses(1), 1)

    def test_pending_edit_requires_a_new_revision_without_scope_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            item = {"id": "codes", "kind": "recoveryCodes", "updatedAt": 1, "label": "QA",
                    "payloadRevision": str(acceptance.uuid.uuid4()), "submissionURL": "https://127.0.0.1/recover"}
            before = {"credentials": [item]}
            changed = dict(item, label="QA (edited)", updatedAt=2, payloadRevision=str(acceptance.uuid.uuid4()))
            (root / "recovery-statuses.json").write_text(acceptance.json.dumps(recovery.expected_statuses(0)))
            for update, passes in [(changed, True), (item, False),
                                   (dict(changed, payloadRevision=item["payloadRevision"]), False),
                                   (dict(changed, submissionURL="https://elsewhere.invalid"), False)]:
                (root / "metadata.json").write_text(acceptance.json.dumps({"credentials": [update]}))
                if passes:
                    recovery.verify_reservation(root, before, False, edited=True)
                else:
                    with self.assertRaises(RuntimeError):
                        recovery.verify_reservation(root, before, False, edited=True)

    def test_cli_recovery_keeps_original_session_and_selected_code_set(self):
        client = acceptance.CLIClient(Path("/fixture"), {"AGENTKEYBOX_PROJECT_PATH": "/project"}, "run")
        client.session = "original-session"
        operation, options = client.options("browser_recover", {
            "browser_session_id": "browser", "credential_id": "codes", "purpose": "QA recovery"})
        self.assertEqual(operation, "recover")
        self.assertEqual(options, {"session": "original-session", "browser": "browser",
                                   "credential": "codes", "purpose": "QA recovery"})

    def test_page_checks_require_same_session_and_expected_content(self):
        page = {"sessionID": "browser", "status": "pageReady", "text": "Welcome to the Secure Area"}
        result = {"content": [{"text": "Untrusted content\n" + acceptance.json.dumps(page)}]}
        self.assertEqual(acceptance.page_result(result, "browser", "Secure Area"), page)
        for browser, marker in [("other", "Secure Area"), ("browser", "Login Page")]:
            with self.subTest(browser=browser, marker=marker), self.assertRaises(RuntimeError):
                acceptance.page_result(result, browser, marker)
        with self.assertRaises(RuntimeError):
            acceptance.page_result(dict(result, isError=True), "browser", "Secure Area")
        with self.assertRaises(RuntimeError):
            acceptance.page_result({"content": [{"text": "No controlled page is available."}]})

    def test_follow_only_uses_the_known_fixture_link(self):
        link_id = str(acceptance.uuid.uuid4())
        link = {"id": link_id, "text": " Logout "}
        self.assertEqual(acceptance.logout_link({"links": [link]}), link_id)
        for links in ([], [link, link], [{"id": link_id, "text": "Delete account"}]):
            with self.subTest(count=len(links)), self.assertRaises(RuntimeError):
                acceptance.logout_link({"links": links})

    def test_prompt_cancellation_cannot_pass_on_timeout_or_decision(self):
        acceptance.verify_immediate_rejection({"isError": True}, [], 0.5)
        for result, events, elapsed in [({}, [], 0.5), ({"isError": True}, [], 120),
                                       ({"isError": True}, [{"decision": "deny"}], 0.5),
                                       ({"isError": True}, [{"decision": "allowOnce"}], 0.5)]:
            with self.subTest(elapsed=elapsed, events=events), self.assertRaises(RuntimeError):
                acceptance.verify_immediate_rejection(result, events, elapsed)

    def test_only_exact_native_busy_result_proves_a_pending_request(self):
        result = {"isError": True, "content": [
            {"text": "Another AgentKeyBox approval is already pending.\n"}]}
        self.assertTrue(acceptance.is_pending_result(result))
        self.assertFalse(acceptance.is_pending_result(dict(result, isError=False)))
        for message in ("Approval timed out.", "No result received.",
                        "Another AgentKeyBox approval is already pending. diagnostic"):
            self.assertFalse(acceptance.is_pending_result({"isError": True, "content": [{"text": message}]}))

    def test_cli_follow_preserves_original_session_and_exact_link(self):
        client = acceptance.CLIClient(Path("/fixture"), {"AGENTKEYBOX_PROJECT_PATH": "/project"}, "run")
        client.session = "original-session"
        operation, options = client.options("browser_follow", {
            "browser_session_id": "browser", "link_id": "current-link", "purpose": "QA navigation"})
        self.assertEqual(operation, "follow")
        self.assertEqual(options, {"session": "original-session", "browser": "browser",
                                   "link": "current-link", "purpose": "QA navigation"})

    def test_denial_and_timeout_require_their_own_history_decision(self):
        acceptance.verify_refusal("denied", {"isError": True}, [{"decision": "deny"}], 2)
        acceptance.verify_refusal("timeout", {"isError": True, "content": [{"text": "Approval timed out."}]},
                                  [{"decision": "timedOut"}], 121)
        for expected, decision in [("denied", "timedOut"), ("timeout", "deny"),
                                   ("denied", "allowOnce"), ("timeout", "allowSession")]:
            with self.subTest(expected=expected, decision=decision), self.assertRaises(RuntimeError):
                acceptance.verify_refusal(expected, {"isError": True}, [{"decision": decision}], 121)

    def test_transport_or_preflight_failure_cannot_count_as_refusal(self):
        for expected in ("denied", "timeout"):
            with self.subTest(expected=expected), self.assertRaises(RuntimeError):
                acceptance.verify_refusal(expected, {"isError": True}, [], 121)

    def test_accidental_approval_never_passes_a_denial_run(self):
        with self.assertRaises(RuntimeError):
            acceptance.verify_refusal("denied", {"content": []}, [{"decision": "deny"}], 2)

    def test_early_or_duplicate_timeout_evidence_is_rejected(self):
        with self.assertRaises(RuntimeError):
            acceptance.verify_refusal("timeout", {"isError": True}, [{"decision": "timedOut"}], 2)
        with self.assertRaises(RuntimeError):
            acceptance.verify_refusal("timeout", {"isError": True},
                                      [{"decision": "timedOut"}] * 2, 121)

    def test_unknown_transport_outcome_is_not_a_native_approval_timeout(self):
        with self.assertRaises(RuntimeError):
            acceptance.verify_refusal(
                "timeout", {"isError": True, "content": [{"text": "Submission outcome is unknown."}]},
                [{"decision": "timedOut"}], 201)

    def test_history_from_other_runs_items_and_projects_is_excluded(self):
        event = {"id": "new", "agentDisplayName": "QA run", "credentialIDs": ["item"],
                 "projectPath": "/project", "decision": "deny"}
        events = [event, dict(event, id="old"), dict(event, id="other", agentDisplayName="QA other"),
                  dict(event, id="wrong-item", credentialIDs=["other"]),
                  dict(event, id="wrong-project", projectPath="/other")]
        self.assertEqual(acceptance.matching_events(events, {"old"}, "QA run", "item", "/project"),
                         [event])

    def test_raw_and_common_encoded_fixture_values_fail_observation_checks(self):
        acceptance.check_output({"decision": "deny", "label": "QA fixture"})
        for secret in acceptance.SYNTHETIC_VALUES:
            variants = [secret, acceptance.urllib.parse.quote(secret, safe=""),
                        acceptance.urllib.parse.quote_plus(secret),
                        acceptance.base64.b64encode(secret.encode()).decode()]
            for value in variants:
                with self.subTest(value_kind="synthetic variant"), self.assertRaises(RuntimeError):
                    acceptance.check_output({"text": value})


if __name__ == "__main__":
    unittest.main()
