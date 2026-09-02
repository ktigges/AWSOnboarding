import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
import urllib.error

LAB_DEVICE_DNS_NAME = os.environ["LAB_DEVICE_DNS_NAME"]
APPLY = os.environ.get("APPLY_EXTENSION_ATTRIBUTE") == "true"
MDE_RESOURCE = "https://api.securitycenter.microsoft.com"
GRAPH_RESOURCE = "https://graph.microsoft.com"
MDE_QUERY_URL = "https://api.security.microsoft.com/api/advancedqueries/run"
GRAPH_DEVICES_URL = (
    "https://graph.microsoft.com/v1.0/devices?"
    + urllib.parse.urlencode(
        {
            "$select": "id,deviceId,displayName,operatingSystem,extensionAttributes",
            "$top": "999",
        }
    )
)


def token(resource):
    command = [
        "az",
        "account",
        "get-access-token",
        "--resource",
        resource,
        "--query",
        "accessToken",
        "--output",
        "tsv",
    ]
    return subprocess.check_output(command, text=True).strip()


def request_json(method, url, access_token, body=None, expected=(200,)):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {access_token}",
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
        detail = error.read(2000).decode(errors="replace")
        raise RuntimeError(f"{method} {url} failed: HTTP {error.code}: {detail}") from error


def fetch_all(url, access_token):
    items = []
    while url:
        page = request_json("GET", url, access_token)
        items.extend(page.get("value", []))
        url = page.get("@odata.nextLink", "")
    return items


mde_token = token(MDE_RESOURCE)
graph_token = token(GRAPH_RESOURCE)
escaped_name = LAB_DEVICE_DNS_NAME.replace("'", "''")
kql = (
    "DeviceInfo "
    f"| where DeviceName =~ '{escaped_name}' "
    "| summarize arg_max(Timestamp, *) by DeviceId "
    "| project DeviceName, AadDeviceId, OSPlatform, RegistryDeviceTag, "
    "DeviceManualTags, DeviceDynamicTags, OnboardingStatus"
)
mde_page = request_json("POST", MDE_QUERY_URL, mde_token, {"Query": kql})
mde_matches = mde_page.get("Results", [])

if not mde_matches:
    sys.exit("lab device not found in Advanced Hunting; verify DNS name and reporting delay")
if len(mde_matches) != 1:
    sys.exit(f"expected one MDE device, found {len(mde_matches)}")

mde_device = mde_matches[0]
system_tag = (mde_device.get("RegistryDeviceTag") or "").strip()
aad_device_id = (mde_device.get("AadDeviceId") or "").strip()

print("MDE system-tag verification:")
print(json.dumps(mde_device, indent=2))
if not system_tag:
    platform = (mde_device.get("OSPlatform") or "").casefold()
    if platform.startswith("windows"):
        sys.exit(
            "RegistryDeviceTag is empty in MDE. Verify the local "
            "DeviceTagging\\Group registry value and confirm the scheduled reboot "
            "completed; MDE has not published the Windows tag yet."
        )
    sys.exit(
        "RegistryDeviceTag is empty in MDE. Verify the local managed MDE profile; "
        "MDE has not published the Linux tag yet."
    )

entra_devices = fetch_all(GRAPH_DEVICES_URL, graph_token)
if aad_device_id:
    entra_matches = [
        device
        for device in entra_devices
        if (device.get("deviceId") or "").casefold() == aad_device_id.casefold()
    ]
    match_method = "AadDeviceId"
else:
    short_name = LAB_DEVICE_DNS_NAME.split(".", 1)[0]
    accepted_names = {LAB_DEVICE_DNS_NAME.casefold(), short_name.casefold()}
    entra_matches = [
        device
        for device in entra_devices
        if (device.get("displayName") or "").casefold() in accepted_names
    ]
    match_method = "unique exact hostname fallback"

if not entra_matches:
    sys.exit(
        "system tag verified, but no Entra device target exists by AadDeviceId or exact hostname"
    )
if len(entra_matches) != 1:
    names = [device.get("displayName") for device in entra_matches]
    sys.exit(f"ambiguous Entra hostname match; refusing to continue: {names}")

entra_device = entra_matches[0]
current_value = (entra_device.get("extensionAttributes") or {}).get(
    "extensionAttribute1"
)
patch_body = {"extensionAttributes": {"extensionAttribute1": system_tag}}
patch_url = f"https://graph.microsoft.com/v1.0/devices/{entra_device['id']}"

print("\nEntra target verification:")
print(
    json.dumps(
        {
            "matchMethod": match_method,
            "objectId": entra_device.get("id"),
            "deviceId": entra_device.get("deviceId"),
            "displayName": entra_device.get("displayName"),
            "operatingSystem": entra_device.get("operatingSystem"),
            "existingExtensionAttributes": entra_device.get("extensionAttributes"),
            "currentExtensionAttribute1": current_value,
            "desiredExtensionAttribute1": system_tag,
        },
        indent=2,
    )
)

if current_value == system_tag:
    print(
        "\nextensionAttribute1 is already there and matches the MDE system tag. "
        "No write is required."
    )
    raise SystemExit(0)

print("\nProposed PATCH:")
print(f"PATCH {patch_url}")
print(json.dumps(patch_body, indent=2))

if not APPLY:
    print("\nDRY RUN ONLY. Rerun the wrapper with --apply to perform this PATCH.")
    raise SystemExit(0)

request_json("PATCH", patch_url, graph_token, patch_body, expected=(204,))
print("\nPATCH succeeded: HTTP 204 No Content.")

verify = request_json(
    "GET",
    f"{patch_url}?$select=id,deviceId,displayName,extensionAttributes",
    graph_token,
)
verified_value = (verify.get("extensionAttributes") or {}).get("extensionAttribute1")
if verified_value != system_tag:
    sys.exit(
        f"PATCH returned success but verification read found {verified_value!r}"
    )

print("\nFinal Entra device query:")
print(
    json.dumps(
        {
            "id": verify.get("id"),
            "deviceId": verify.get("deviceId"),
            "displayName": verify.get("displayName"),
            "extensionAttributes": verify.get("extensionAttributes"),
        },
        indent=2,
    )
)
print(f"Verified extensionAttribute1={verified_value!r}")
