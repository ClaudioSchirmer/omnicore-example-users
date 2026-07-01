#!/usr/bin/env python3
# Field-by-field verifier for the "golden record". Two modes:
#
#   json  <surface> <id>   stdin = a JSON doc (REST envelope or a GraphQL node) →
#                          assert EVERY root field + both addresses (with the 2nd
#                          address's nullable label/complement absent) match.
#   flat  <surface>        stdin = raw text (CSV body, or the strings extracted
#                          from an XLSX) → assert every expected value appears.
#
# Exit non-zero + print the mismatches on failure; print a PASS line otherwise.
import sys, json

mode = sys.argv[1]
surface = sys.argv[2]

ROOT = {
    "name": "Golden Record",
    "email": "golden@example.com",
    "phone": "15551234567",
    "document": "10000000500",
    "userName": "golden",
    "emailNotification": True,
    "smsNotification": False,
}
ADDR0 = {
    "label": "home", "street": "1 Golden Way", "number": "10",
    "complement": "Suite 5", "neighborhood": "Downtown", "city": "Metropolis",
    "state": "NY", "zipCode": "10001", "country": "US",
}
ADDR1 = {
    "street": "2 Silver Rd", "number": "20", "neighborhood": "Uptown",
    "city": "Gotham", "state": "NJ", "zipCode": "07001", "country": "US",
}


def fail(errs):
    print(f"{surface} FIELD-BY-FIELD FAIL:")
    for e in errs:
        print("  -", e)
    sys.exit(1)


if mode == "json":
    want_id = sys.argv[3]
    doc = json.load(sys.stdin)
    if isinstance(doc, dict) and "data" in doc and isinstance(doc["data"], dict):
        doc = doc["data"]
    errs = []
    if doc.get("id") != want_id:
        errs.append(f"root.id: got {doc.get('id')!r} want {want_id!r}")
    for k, v in ROOT.items():
        if doc.get(k) != v:
            errs.append(f"root.{k}: got {doc.get(k)!r} want {v!r}")
    addrs = doc.get("addresses") or []
    if len(addrs) != 2:
        errs.append(f"addresses length {len(addrs)} want 2")
    else:
        # order can vary; match each expected address by its street.
        by_street = {a.get("street"): a for a in addrs}
        a0 = by_street.get("1 Golden Way", {})
        a1 = by_street.get("2 Silver Rd", {})
        for k, v in ADDR0.items():
            if a0.get(k) != v:
                errs.append(f"addr(1 Golden Way).{k}: got {a0.get(k)!r} want {v!r}")
        for k, v in ADDR1.items():
            if a1.get(k) != v:
                errs.append(f"addr(2 Silver Rd).{k}: got {a1.get(k)!r} want {v!r}")
        if a1.get("label") is not None:
            errs.append(f"addr(2 Silver Rd).label must be null/absent, got {a1.get('label')!r}")
        if a1.get("complement") is not None:
            errs.append(f"addr(2 Silver Rd).complement must be null/absent, got {a1.get('complement')!r}")
    if errs:
        fail(errs)
    print(f"{surface} FIELD-BY-FIELD PASS: 6 shared/role fields + id + 2 addresses (17 subfields) exact; nullables absent")

elif mode == "flat":
    text = sys.stdin.read()
    # every non-empty string value the write produced must appear somewhere.
    values = ["Golden Record", "golden@example.com", "15551234567",
              "10000000500", "golden"]
    for a in (ADDR0, ADDR1):
        for v in a.values():
            values.append(str(v))
    missing = [v for v in dict.fromkeys(values) if v not in text]
    if missing:
        fail([f"value not present: {v!r}" for v in missing])
    print(f"{surface} FIELD-BY-FIELD PASS: all {len(set(values))} data values present in the export")

else:
    print(f"unknown mode {mode!r}", file=sys.stderr)
    sys.exit(2)
