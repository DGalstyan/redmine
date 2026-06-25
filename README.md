# Redmine API Rate Limiting — #43881 (slice)

A defensible slice of Redmine issue
[#43881](https://www.redmine.org/issues/43881) "Strengthen API authentication." This
implements the required core — **API request rate limiting that returns HTTP 429** — plus
structured audit logging of throttled requests, built on a fork of `redmine/redmine`
branched off tag **6.1.2**.

## Approach

Rate limiting is added as **Rack::Attack** middleware. It runs ahead of Rails routing, so
it rejects abusive API traffic cheaply and without touching controller logic. The throttle
is scoped to API requests only (`.json`/`.xml`), keyed on the API credential (hashed) with
an IP fallback, and configurable via `config/configuration.yml`. See
[`docs/ADR-001-rate-limiting.md`](docs/ADR-001-rate-limiting.md) for the full rationale and
alternatives.

## What's done

- API requests over the configured limit get **429** with a `Retry-After` header and a JSON
  body.
- Throttling is scoped to the API; the **web UI is never throttled**.
- Limits are **configurable** (`api_rate_limit.limit` / `.period` in `configuration.yml`),
  defaulting to 60 req / 60 s. No hardcoded numbers.
- **Integration test** (`test/integration/api_rate_limit_test.rb`) proves all five behaviours
  — over-limit 429, under-limit 200, web-UI exemption, per-key independent budgets, and an
  audit-log line on throttle (5 runs, 32 assertions, deterministic).
- Throttled requests are written to a **structured audit log** (`log/api_audit.log`) — one
  JSON line per throttle (fingerprinted credential, path, method, IP), no raw key and no
  per-request DB writes.

## What's deferred (and why)

| Ticket pillar | Why deferred |
| --- | --- |
| Personal access tokens + expiration | Large auth-model change; orthogonal to throttling and out of scope for a focused slice. |
| Token scopes | Depends on the PAT work above. |
| Per-endpoint enable/disable | Independent feature; doesn't affect the 429 core. |
| CORS configuration | Independent feature; belongs with browser-context access work. |
| Admin UI + audit query/export | Limits live in `configuration.yml` and the audit trail is an append-only log file; a settings UI and in-app query/export view are out of scope for this slice. |

## Assumptions

- SQLite for development (PostgreSQL/MySQL supported per Redmine 6.1 requirements).
- Single-process app server in dev; production would need a shared cache store — see Limits.
- The common API path uses key-based auth (header / param / basic-auth username).

## How to run

```bash
git clone https://github.com/DGalstyan/redmine.git && cd redmine
git checkout feat/api-rate-limit            # branched off tag 6.1.2
# minimal SQLite config (see config/database.yml in this repo)
bundle config set --local without 'rmagick'
bundle install
bundle exec rake generate_secret_token
RAILS_ENV=development bundle exec rake db:migrate
RAILS_ENV=development REDMINE_LANG=en bundle exec rake redmine:load_default_data
bundle exec rails server -p 3000
```

Enable the REST API and get a key (Administration → Settings → API, then My account → API
access key), or run the console snippet in
[`.claude/skills/redmine-dev-setup/SKILL.md`](.claude/skills/redmine-dev-setup/SKILL.md).

## How to verify

Full steps in [`docs/VERIFICATION.md`](docs/VERIFICATION.md). Quick version:

```bash
KEY="<KEY>"
for i in $(seq 1 70); do
  curl -s -o /dev/null -w "%{http_code}\n" -H "X-Redmine-API-Key: $KEY" \
    http://localhost:3000/issues.json
done           # 200s, then 429s once over the limit
```

Or run the integration test (no server required):

```bash
RAILS_ENV=test bundle exec rake db:migrate
RAILS_ENV=test bundle exec ruby -Itest test/integration/api_rate_limit_test.rb
# => 5 runs, 32 assertions, 0 failures, 0 errors, 0 skips
```

## How the rate limiting works, and its limits

**Works:** Rack::Attack increments a per-`(credential, fixed-window)` counter in
`Rails.cache`; over the limit, a `throttled_responder` returns 429 + `Retry-After`. The
discriminator is `X-Redmine-API-Key` → `?key=` → HTTP Basic username → IP, with any
credential hashed before use. API detection is by path extension.

**Limits (read before relying on it):**
- **Per-process cache** — the default memory store means each worker enforces its own
  budget; production needs Redis/memcached via `Rails.cache`. *(Biggest caveat.)*
- **Fixed window** — allows up to ~2×limit across a window boundary.
- **Keys on the credential, not the resolved user** — middleware runs before auth, so no
  per-user/per-role policy at this layer.
- **Accept-header API calls** without a `.json` extension aren't detected as API.
- **Proxy IP trust** depends on `trusted_proxies` being configured.

Full discussion in [`docs/ADR-001-rate-limiting.md`](docs/ADR-001-rate-limiting.md).

## AI workflow

Built with [Claude Code](https://claude.com/claude-code) using a multi-agent setup under
`.claude/` (orchestrator, rails-engineer, test-engineer, docs-writer) and a set of skills.
Per-phase session notes and a tools-and-workflow record are in
[`ai-artifacts/`](ai-artifacts/); the per-phase notes there map one-to-one to the per-phase
commits in git history (one commit per phase, 0–4).
