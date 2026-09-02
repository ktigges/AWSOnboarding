import json
import sys


def validate(raw: str) -> str:
    start = raw.find("{")
    if start < 0:
        raise ValueError("MDE health output contained no JSON object")

    health = json.loads(raw[start:])
    licensed = health.get("licensed")
    org_id = health.get("org_id")

    if licensed is not False:
        raise ValueError(f"expected licensed=false, received {licensed!r}")
    if org_id not in (None, "", "unavailable"):
        raise ValueError(f"expected unavailable org_id, received {org_id!r}")

    return f"licensed=false org_id={org_id!r}"


def main() -> int:
    try:
        print(validate(sys.stdin.read()))
    except (AssertionError, json.JSONDecodeError, ValueError) as error:
        print(f"MDE health validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
