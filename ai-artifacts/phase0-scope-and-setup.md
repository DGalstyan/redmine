# Phase 0 — Scope & setup

**Role:** orchestrator (played by Claude Code directly — the bespoke `orchestrator` /
`redmine-dev-setup` agents named in the playbook are not installed in this environment).
**Skills assumed:** `redmine-dev-setup` (not installed; the standard Redmine SQLite bootstrap
was performed directly).

---

## Exchange 1 — slice boundary & plan

### PROMPT → orchestrator (verbatim from KICKOFF_PLAYBOOK.md, Phase 0)

```
Read the task brief and Redmine issue #43881. We are shipping ONE defensible slice:
working API rate limiting (HTTP 429) on the REST API, plus audit logging of throttled
requests as a cheap stretch. Everything else in the ticket (PATs, scopes, endpoint
control, CORS, admin UI) is deferred.

Produce:
1. A one-paragraph slice boundary: what's in, what's out, and why.
2. A 5-step plan mapping to the phases in KICKOFF_PLAYBOOK.md.
3. The list of files we expect to add or touch (keep it minimal).

Do not write implementation code yet. Save the boundary to docs/SLICE.md.
```

### OUTPUT

Saved to [`docs/SLICE.md`](../docs/SLICE.md). Summary:

- **In:** Rack::Attack API rate limiting → 429 + `Retry-After`; web UI exempt; limits from
  `config/configuration.yml`. Stretch: structured audit log of throttled requests.
- **Out (deferred):** PATs, token expiration, scopes, per-endpoint control, CORS, admin UI —
  each an independent pillar that would balloon the diff; they layer on top of this middleware.
- **5-step plan** maps 1:1 to playbook Phases 0–4.
- **Files:** `Gemfile.local`, `config/initializers/rack_attack.rb`,
  `config/configuration.yml.example`, `test/integration/api_rate_limit_test.rb`,
  `docs/VERIFICATION.md`, a Phase-3 audit initializer, `README.md`, `ai-artifacts/*`.

---

## Exchange 2 — dev environment setup

### PROMPT → orchestrator (verbatim, delegates setup)

```
Use the redmine-dev-setup skill to get a runnable Redmine on tag 6.1.2 with SQLite,
the default data loaded, an admin user, the REST API enabled, and an API key in hand.
Output the exact commands you ran and the API key, and confirm `GET /issues.json` works
with that key. Stop once the app boots and the API responds.
```

### OUTPUT — exact commands & results

Environment was already bootstrapped on tag **6.1.2** (`git describe` → `6.1.2`), Ruby 3.3.6,
Bundler 2.5.22. SQLite was already configured and migrated; the dev server was already running.
The two things that needed doing/confirming:

```bash
# config/database.yml (already present) — SQLite:
#   development: { adapter: sqlite3, database: db/redmine.sqlite3 }

# REST API was DISABLED — enabled it:
bundle exec rails runner 'Setting.rest_api_enabled = "1"'
#   => rest_api_enabled now "1"

# Admin user + API key (already present):
bundle exec rails runner 'u=User.find_by_login("admin"); puts u.api_key'
#   => <REDACTED_DEV_API_KEY>
```

**API key:** `<REDACTED_DEV_API_KEY>` (user `admin`, id 1)

**Confirm `GET /issues.json` works with the key:**

```bash
$ curl -s -H "X-Redmine-API-Key: <REDACTED_DEV_API_KEY>" \
       http://localhost:3000/issues.json
{"issues":[],"total_count":0,"offset":0,"limit":25}      # HTTP 200, content-type application/json

# Proof key-auth is live in the running process (not stale cache):
$ curl -s -o /dev/null -w "%{http_code}" .../users/current.json -H "X-Redmine-API-Key: <key>"
200      # with key
$ curl -s -o /dev/null -w "%{http_code}" .../users/current.json
401      # without key (REST API now enforced)
```

App boots, REST API responds. ✅ Stop condition met.

> Note: the dev DB currently has 0 issues; the list endpoint still returns valid JSON, which is
> all the Phase 2 verification loop needs.
