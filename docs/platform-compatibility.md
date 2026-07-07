# Platform Compatibility

Course admin tooling should fail fast when it targets a Yelukerest deployment
with an incompatible schema or admin API. Yelukerest exposes a stable,
unauthenticated, read-only endpoint for that preflight:

```sh
curl -fsS https://example.edu/rest/platform_version
```

The response is a one-row JSON array:

```json
[
  {
    "platform": "yelukerest",
    "platform_compatibility_version": 1,
    "schema_compatibility_version": 1,
    "admin_api_version": 3
  }
]
```

Clients should compare integer versions with `>=`, not string equality. A
course admin repo can declare required minimums and reject older deployments:

```python
import json
import urllib.request

required = {
    "platform": "yelukerest",
    "schema_compatibility_version": 1,
    "admin_api_version": 3,
}

with urllib.request.urlopen("https://example.edu/rest/platform_version") as res:
    actual = json.load(res)[0]

assert actual["platform"] == required["platform"]
assert actual["schema_compatibility_version"] >= required["schema_compatibility_version"]
assert actual["admin_api_version"] >= required["admin_api_version"]
```

Update the values in `db/src/api/yeluke/platform_version.sql` when a change
requires course admin tools to know about a new platform behavior, schema
shape, or admin API contract. Breaking schema or admin API changes should raise
the relevant compatibility version in the same change that introduces the new
contract.
