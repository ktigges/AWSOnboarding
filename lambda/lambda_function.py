from __future__ import annotations

import json
import logging
import os
import random
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from typing import Any

import boto3

SECRET_ID = os.environ["SECRET_ID"]
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


def load_secret():
    # Lambda uses an Entra app credential stored in AWS Secrets Manager.
    value = boto3.client("secretsmanager").get_secret_value(SecretId=SECRET_ID)
    return json.loads(value["SecretString"])


def get_token(secret, scope):
    # Exchange the app credential for a token scoped to the requested API.
    body = urllib.parse.urlencode(
        {
            "client_id": secret["client_id"],
            "client_secret": secret["client_secret"],
            "grant_type": "client_credentials",
            "scope": scope,
        }
    ).encode()
    request = urllib.request.Request(
        f"https://login.microsoftonline.com/{secret['tenant_id']}/oauth2/v2.0/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)["access_token"]


def request_json(method, url, token, body=None, expected=(200,)):
    encoded_body = json.dumps(body).encode() if body is not None else None
    for attempt in range(6):
        request = urllib.request.Request(
            url,
            data=encoded_body,
            method=method,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                if response.status not in expected:
                    raise RuntimeError(f"unexpected HTTP status {response.status}")
                return None if response.status == 204 else json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 429 or 500 <= error.code < 600:
                retry_after = error.headers.get("Retry-After")
                delay = float(retry_after) if retry_after else min(2**attempt, 30)
                delay += random.uniform(0, 0.5)
                log_event(
                    "http_retry",
                    method=method,
                    status=error.code,
                    attempt=attempt + 1,
                    delay_seconds=round(delay, 2),
                )
                time.sleep(delay)
                continue
            detail = error.read(1000).decode(errors="replace")
            raise RuntimeError(f"{method} {url} failed: {error.code} {detail}")
    raise RuntimeError(f"{method} {url} exhausted retries")


def fetch_all(url, token):
    items = []
    while url:
        page = request_json("GET", url, token)
        items.extend(page.get("value", []))
        url = page.get("@odata.nextLink", "")
    return items


def find_entra_matches(mde_device, entra_devices):
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


def verify_extension_attribute(patch_url, token, expected_tag):
    verified_tag = None
    for attempt, delay in enumerate((1, 2, 4, 8, 16, 30), start=1):
        verify = request_json(
            "GET",
            f"{patch_url}?$select=id,deviceId,displayName,extensionAttributes",
            token,
        )
        verified_tag = (verify.get("extensionAttributes") or {}).get(
            "extensionAttribute1"
        )
        if verified_tag == expected_tag:
            return True, verified_tag
        log_event(
            "device_update_verification_retry",
            attempt=attempt,
            expected_tag=expected_tag,
            observed_tag=verified_tag,
            delay_seconds=delay,
        )
        time.sleep(delay)
    return False, verified_tag


def synchronize(graph_token):
    counters = Counter()
    allowed_tags = {
        tag.strip().casefold()
        for tag in os.environ.get(ALLOWED_TAGS_SETTING, "").split(",")
        if tag.strip()
    }
    if not allowed_tags:
        raise RuntimeError(f"{ALLOWED_TAGS_SETTING} must contain at least one tag")
    mde_page = request_json(
        "POST", MDE_QUERY_URL, graph_token, {"Query": MDE_QUERY}
    )
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
            log_event(
                "ambiguous_entra_match",
                device_name=machine.get("DeviceName"),
                match_method=match_method,
                match_count=len(entra_matches),
            )
            continue

        entra_device = entra_matches[0]
        current = (entra_device.get("extensionAttributes") or {}).get(
            "extensionAttribute1"
        )
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
            {"extensionAttributes": {"extensionAttribute1": tag}},
            (204,),
        )
        verified, verified_tag = verify_extension_attribute(
            patch_url, graph_token, tag
        )
        if not verified:
            counters["verification_pending"] += 1
            log_event(
                "device_update_verification_pending",
                device_name=machine.get("DeviceName"),
                entra_object_id=entra_device.get("id"),
                expected_tag=tag,
                observed_tag=verified_tag,
            )
            continue
        counters["updated"] += 1
        log_event(
            "device_updated",
            device_name=machine.get("DeviceName"),
            aad_device_id=machine.get("AadDeviceId"),
            entra_object_id=entra_device.get("id"),
            match_method=match_method,
        )
    return counters


def lambda_handler(event, context):
    started = time.monotonic()
    log_event("sync_started", request_id=context.aws_request_id)
    secret = load_secret()
    # Microsoft Graph handles both hunting and device updates.
    graph_token = get_token(secret, "https://graph.microsoft.com/.default")
    counters = synchronize(graph_token)
    result = {
        "duration_seconds": round(time.monotonic() - started, 3),
        **dict(counters),
    }
    log_event("sync_completed", **result)
    return result
