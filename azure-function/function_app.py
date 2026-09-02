from __future__ import annotations

import json
import logging
import os
import random
import time
from collections import Counter
from typing import Any
import azure.functions as func
import requests
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()
# Uses the Function App managed identity when deployed in Azure.
credential = DefaultAzureCredential()
session = requests.Session()

GRAPH_SCOPE = "https://graph.microsoft.com/.default"
MDE_QUERY_URL = "https://graph.microsoft.com/v1.0/security/runHuntingQuery"
ALLOWED_TAGS_SETTING = "MDE_ALLOWED_DEVICE_TAGS"
# Read the endpoint system tag reported by each Linux or Windows Server device.
MDE_QUERY = """
DeviceInfo
| where OSPlatform contains "Linux" or OSPlatform startswith "WindowsServer"
| summarize arg_max(Timestamp, *) by DeviceId
| project DeviceName, AadDeviceId, OSPlatform, RegistryDeviceTag, OnboardingStatus
""".strip()
GRAPH_URL = (
    "https://graph.microsoft.com/v1.0/devices"
    "?$select=id,deviceId,displayName,operatingSystem,extensionAttributes"
    "&$top=999"
)


def log_event(event: str, **fields: Any) -> None:
    logging.info(json.dumps({"event": event, **fields}, sort_keys=True))


def access_token(scope: str) -> str:
    # Request a token for the API using the managed identity.
    return credential.get_token(scope).token


def request_json(
    method: str,
    url: str,
    token: str,
    body: dict[str, Any] | None = None,
    expected: tuple[int, ...] = (200,),
) -> dict[str, Any] | None:
    for attempt in range(6):
        response = session.request(
            method,
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
            json=body,
            timeout=60,
        )
        if response.status_code in expected:
            if response.status_code == 204 or not response.content:
                return None
            return response.json()
        if response.status_code == 429 or 500 <= response.status_code < 600:
            retry_after = response.headers.get("Retry-After")
            delay = float(retry_after) if retry_after else min(2**attempt, 30)
            delay += random.uniform(0, 0.5)
            time.sleep(delay)
            continue
        raise RuntimeError(
            f"{method} {url} failed with {response.status_code}: "
            f"{response.text[:1000]}"
        )
    raise RuntimeError(f"{method} {url} exhausted retries")


def fetch_all(url: str, token: str) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    while url:
        page = request_json("GET", url, token)
        if page is None:
            raise RuntimeError("paged GET unexpectedly returned no content")
        items.extend(page.get("value", []))
        url = page.get("@odata.nextLink", "")
    return items


def find_entra_matches(
    mde_device: dict[str, Any], entra_devices: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], str]:
    # Use the Entra device ID when MDE has it.
    aad_device_id = (mde_device.get("AadDeviceId") or "").strip()
    if aad_device_id:
        return (
            [
                device
                for device in entra_devices
                if (device.get("deviceId") or "").casefold()
                == aad_device_id.casefold()
            ],
            "AadDeviceId",
        )

    # Otherwise require one exact full or short host name match.
    device_name = (mde_device.get("DeviceName") or "").strip()
    short_name = device_name.split(".", 1)[0]
    accepted_names = {device_name.casefold(), short_name.casefold()} - {""}
    return (
        [
            device
            for device in entra_devices
            if (device.get("displayName") or "").casefold() in accepted_names
        ],
        "unique exact hostname fallback",
    )


def verify_extension_attribute(
    patch_url: str, token: str, expected_tag: str
) -> tuple[bool, str | None]:
    verified_tag: str | None = None
    for attempt, delay in enumerate((1, 2, 4, 8, 16, 30), start=1):
        verify = request_json(
            "GET",
            f"{patch_url}?$select=id,deviceId,displayName,extensionAttributes",
            token,
        )
        if verify is None:
            raise RuntimeError("Entra verification unexpectedly returned no content")
        verified_tag = (verify.get("extensionAttributes") or {}).get(
            "extensionAttribute1"
        )
        if verified_tag == expected_tag:
            return True, verified_tag
        time.sleep(delay)
    return False, verified_tag


def synchronize() -> Counter[str]:
    counters: Counter[str] = Counter()
    allowed_tags = {
        tag.strip().casefold()
        for tag in os.environ.get(ALLOWED_TAGS_SETTING, "").split(",")
        if tag.strip()
    }
    if not allowed_tags:
        raise RuntimeError(f"{ALLOWED_TAGS_SETTING} must contain at least one tag")
    # Microsoft Graph handles both hunting and device updates.
    graph_token = access_token(GRAPH_SCOPE)

    mde_page = request_json(
        "POST", MDE_QUERY_URL, graph_token, body={"Query": MDE_QUERY}
    )
    if mde_page is None:
        raise RuntimeError("Advanced Hunting unexpectedly returned no content")
    machines = mde_page.get("results", [])
    entra_devices = fetch_all(GRAPH_URL, graph_token)
    counters["mde_devices"] = len(machines)
    counters["entra_devices"] = len(entra_devices)

    for machine in machines:
        tag = (machine.get("RegistryDeviceTag") or "").strip()
        if not tag:
            counters["no_system_tag"] += 1
            continue
        if tag.casefold() not in allowed_tags:
            counters["tag_out_of_scope"] += 1
            continue

        entra_matches, match_method = find_entra_matches(machine, entra_devices)
        if not entra_matches:
            counters["entra_device_not_found"] += 1
            continue
        if len(entra_matches) != 1:
            counters["ambiguous_entra_match"] += 1
            continue

        entra_device = entra_matches[0]
        current = (entra_device.get("extensionAttributes") or {}).get(
            "extensionAttribute1"
        )
        was_untagged = not str(current or "").strip()
        if current == tag:
            counters["unchanged"] += 1
            continue

        # Copy the MDE system tag to the Entra device attribute.
        patch_url = (
            "https://graph.microsoft.com/v1.0/devices/" f"{entra_device['id']}"
        )
        request_json(
            "PATCH",
            patch_url,
            graph_token,
            body={"extensionAttributes": {"extensionAttribute1": tag}},
            expected=(204,),
        )
        verified, verified_tag = verify_extension_attribute(
            patch_url, graph_token, tag
        )
        if not verified:
            counters["verification_pending"] += 1
            continue
        counters["updated"] += 1
        if was_untagged:
            counters["tag_added"] += 1
            log_event(
                "device_tag_added",
                device_name=machine.get("DeviceName"),
                entra_object_id=entra_device.get("id"),
                tag=tag,
            )
        else:
            counters["tag_replaced"] += 1

    return counters


@app.function_name(name="MdeTagToEntraExtension")
@app.timer_trigger(
    schedule="%MDE_TAG_SYNC_SCHEDULE%",
    arg_name="timer",
    run_on_startup=False,
    use_monitor=True,
)
def mde_tag_to_entra_extension(timer: func.TimerRequest) -> None:
    started = time.monotonic()
    try:
        counters = synchronize()
        log_event(
            "sync_completed",
            duration_seconds=round(time.monotonic() - started, 3),
            **dict(counters),
        )
    except Exception:
        logging.exception(json.dumps({"event": "sync_failed"}))
        raise
