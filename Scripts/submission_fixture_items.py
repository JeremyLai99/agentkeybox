"""Exact synthetic submission-fixture allowlist shared by offline/native QA tools."""
import uuid


def fixture_id(profile, offset):
    data = bytearray(profile.bytes)
    data[-1] ^= offset
    return str(uuid.UUID(bytes=bytes(data))).upper()


def validate_items(profile, credentials, origin):
    card, codes, optional, project = (fixture_id(profile, n) for n in (1, 2, 3, 4))
    items = {item["id"]: item for item in credentials}
    if len(items) != len(credentials) or set(items) not in ({card, codes}, {card, codes, optional}):
        raise RuntimeError("Unexpected fixture items")
    for identity, kind, path, project_id in [
        (card, "creditCard", "/submit/card", None),
        (codes, "recoveryCodes", "/submit/recovery", None),
        (optional, "creditCard", "/submit/card", project),
    ]:
        if identity not in items:
            continue
        item = items[identity]
        if (item["kind"] != kind or item.get("submissionURL") != origin + path
                or item.get("projectID") != project_id):
            raise RuntimeError("Item is not bound to its exact fixture kind, project and destination")
    return items
