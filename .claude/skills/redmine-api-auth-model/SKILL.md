---
name: redmine-api-auth-model
description: How Redmine accepts and resolves REST API credentials (X-Redmine-API-Key header, ?key= param, HTTP Basic with the key as username) and why middleware-level rate limiting keys on the credential fingerprint rather than the user. Use when reasoning about API auth, keying, or what runs before user resolution.
---

# Redmine API auth model

## How a caller presents an API key

Redmine accepts the REST API key three ways (see `lib/redmine/...` / `AccountController` /
`ApplicationController#find_current_user`):

1. **`X-Redmine-API-Key` request header** — the preferred form.
2. **`?key=<api_key>` query parameter**.
3. **HTTP Basic auth with the API key as the username** (any/`X` password). Redmine treats the
   Basic username as the key when it looks like one.

REST must be enabled (`Setting.rest_api_enabled == "1"`) for key auth to be honored.

## Why this matters for rate limiting

Rate-limiting middleware (Rack::Attack) runs **before** Redmine routes the request or resolves
`User.current`. So at that layer you cannot key on the user or role — you only have the raw
request. The right discriminator mirrors Redmine's own credential precedence:

```
X-Redmine-API-Key header  ->  ?key= param  ->  Basic-auth username  ->  client IP (fallback)
```

### Consequences (state these in docs)

- **Keys on the credential, not the person.** Two valid keys owned by one user get independent
  budgets. No per-user/per-role policy is possible at this layer — that needs controller-level
  logic after user resolution.
- **Fingerprint, don't store raw.** Hash the credential (SHA256, short prefix) before using it as
  a cache key or log field, so the raw key never persists.
- **IP fallback trust.** Anonymous/keyless API calls collapse to `req.ip`, which is only as good
  as `trusted_proxies`/`X-Forwarded-For` handling. Behind an unconfigured proxy, many callers may
  share one IP.
- **Path-based API detection.** Redmine serves API by `.json`/`.xml` extension; a client sending
  `Accept: application/json` without the extension isn't recognized as API by a path-based check.

## Verifying credential handling

```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "X-Redmine-API-Key: $KEY" .../users/current.json  # 200
curl -s -o /dev/null -w "%{http_code}\n" -u "$KEY:x"                  .../users/current.json   # 200 (Basic)
curl -s -o /dev/null -w "%{http_code}\n"                              .../users/current.json   # 401
```
