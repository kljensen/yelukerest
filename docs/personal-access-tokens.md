# Personal access tokens

A personal access token lets your own code talk to the course API — a Python
script, a notebook, a web app you are building, or an AI assistant writing that
code with you.

If you only want an assistant like Claude or ChatGPT to read your course data,
you probably want [MCP](mcp-for-students.md) instead: it needs no token at all,
just a sign-in and a consent screen. Use a personal access token when *you* are
writing the code.

## Getting one

1. Sign in to the course site.
2. Go to **Settings → API tokens**.
3. Give the token a name you will recognise later — "laptop", "colab", "final
   project" — and create it.
4. **Copy it immediately.** It is shown once and never again. If you lose it,
   revoke it and make another; that costs you nothing.

A token looks like this:

```
yk_2be8b799_1f3c…
```

Treat it like a password. It lasts four months, which is longer than the
semester, so you should only have to do this once.

## Using it

Your token is not the thing you send to the API. You trade it for a
short-lived **access token** that lasts an hour, and send that.

That extra step is what makes revoking work: if your token ever leaks, revoking
it stops new access tokens being issued straight away, instead of leaving
something valid for four months.

### Set it in your environment

```sh
export YELUKEREST_TOKEN='yk_2be8b799_…'
```

Do **not** paste it into your code, commit it to git, or post it in Slack,
Piazza or Canvas. If you commit it by accident, revoke it — do not just delete
the commit, because it stays in the repository history.

### Python

```python
import os
import requests

BASE = "https://www.656.mba"


def get_access_token() -> str:
    r = requests.post(
        f"{BASE}/auth/token",
        headers={"Authorization": f"Bearer {os.environ['YELUKEREST_TOKEN']}"},
        timeout=10,
    )
    r.raise_for_status()
    return r.json()["jwt"]


access_token = get_access_token()
r = requests.get(
    f"{BASE}/rest/meetings",
    headers={"Authorization": f"Bearer {access_token}"},
    params={"order": "begins_at"},
    timeout=10,
)

# An access token lasts an hour. If your program runs longer than that, get a
# new one when a request comes back 401 rather than crashing.
if r.status_code == 401:
    access_token = get_access_token()
    r = requests.get(
        f"{BASE}/rest/meetings",
        headers={"Authorization": f"Bearer {access_token}"},
        params={"order": "begins_at"},
        timeout=10,
    )

r.raise_for_status()
for meeting in r.json():
    print(meeting["begins_at"], meeting["title"])
```

### JavaScript

```js
const BASE = "https://www.656.mba";

async function getAccessToken() {
  const r = await fetch(`${BASE}/auth/token`, {
    method: "POST",
    headers: { Authorization: `Bearer ${process.env.YELUKEREST_TOKEN}` },
  });
  if (!r.ok) throw new Error(`token exchange failed: ${r.status}`);
  return (await r.json()).jwt;
}

let accessToken = await getAccessToken();

async function api(path) {
  let r = await fetch(`${BASE}/rest/${path}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (r.status === 401) {
    // The access token expired; get a new one and try once more.
    accessToken = await getAccessToken();
    r = await fetch(`${BASE}/rest/${path}`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
  }
  if (!r.ok) throw new Error(`${path}: ${r.status}`);
  return r.json();
}

console.log(await api("meetings?order=begins_at"));
```

### curl

```sh
ACCESS_TOKEN=$(curl -s -X POST https://www.656.mba/auth/token \
  -H "Authorization: Bearer $YELUKEREST_TOKEN" | jq -r .jwt)

curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://www.656.mba/rest/meetings?order=begins_at" | jq .
```

## What a token can do

By default a token can **read** your course data and **not change anything**:

| Scope | Meaning |
| --- | --- |
| `course:read` | meetings, assignments, quizzes |
| `grades:read` | your own grades |
| `submissions:read` | your own submissions |
| `submissions:write` | **submit and change your work** |

`submissions:write` is off unless you tick it when creating the token. Leave it
off unless you are deliberately writing code that submits work. If an assistant
is writing code alongside you, a read-only token means a misunderstanding cannot
turn into an accidental submission.

A token can never do more than you can. Everything goes through the same
row-level security as the website, so you cannot read another student's
submissions with a token any more than you could in the browser.

## Revoking

**Settings → API tokens → Revoke.** It takes effect immediately: no new access
tokens will be issued. An access token already handed out keeps working for up
to an hour.

Revoke a token if:

- you committed it to a repository or pasted it somewhere public,
- you are finished with the machine you put it on, or
- **Last used** shows activity you cannot explain.

That last one is worth checking occasionally. It is the only way to notice a
token you forgot about is still being used.

## Errors

| Status | Meaning |
| --- | --- |
| `401` on `/auth/token` | Token is wrong, revoked, or expired. Create a new one. |
| `401` on `/rest/…` | Access token expired. Exchange again. |
| `403` on `/rest/…` | Authentication worked; you are not allowed that data. A different token will not help. |
| `429` | Too many exchanges. Exchange once an hour, not once per request. |

`401` and `403` mean genuinely different things here, and the distinction is
worth keeping straight: `401` is "I do not know who you are", `403` is "I know
who you are and the answer is no".
