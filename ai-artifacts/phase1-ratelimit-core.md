# Phase 1 — Rate-limiting core

**Role:** rails-engineer (played by the Claude Code **general-purpose** subagent — the bespoke
`rails-engineer` agent named in the playbook is not installed in this environment).
**Skills assumed:** `rack-attack-rate-limiting`, `redmine-api-auth-model` (not installed; their
knowledge — discriminator priority, `throttled_responder` shape, Redmine's API-key-as-Basic-auth
model, `Redmine::Configuration` access — was inlined into the delegation prompt).

---

## PROMPT → rails-engineer (verbatim, KICKOFF_PLAYBOOK.md Phase 1 — implement)

```
Implement API rate limiting using Rack::Attack. Requirements:
- Add rack-attack to the bundle (prefer Gemfile.local so upgrades stay clean; Gemfile is
  acceptable since this is a fork).
- New initializer config/initializers/rack_attack.rb.
- THROTTLE SCOPE: only API requests. Match paths ending in .json or .xml. Leave the web
  UI completely untouched.
- DISCRIMINATOR (keying), in this priority order:
    1. X-Redmine-API-Key request header
    2. ?key= query param
    3. HTTP Basic auth username (Redmine accepts the API key as the basic-auth user)
    4. fall back to client IP
- LIMIT: configurable, not hardcoded. Read requests-per-period and period from
  config/configuration.yml (with sane defaults, e.g. 60 requests / 60 seconds). Document
  the keys you add in configuration.yml.example.
- RESPONSE: return 429 with a JSON body and a Retry-After header computed from the throttle
  match data. Use throttled_responder (current Rack::Attack API).
- CACHE: use Rails.cache. Note in a code comment that production needs a shared store.
Do not add an admin UI — limits via config file only for this slice.
```
*(Plus a verbatim sanity-pass prompt covering three request scenarios — see below.)*

> **Orchestrator note on one deviation:** the playbook prefers `Gemfile.local`, but in this
> fork **`Gemfile.local` is gitignored** (`.gitignore:45`), so a fresh `git clone` wouldn't get
> the gem and the DoD ("clone → install → boots") would break. The gem was therefore added to
> the tracked **`Gemfile`** — which the playbook explicitly permits for a fork. Likewise the
> documented config keys go in the tracked **`configuration.yml.example`** (since
> `config/configuration.yml` is gitignored too), with hardcoded default fallbacks in the
> initializer so it boots with no config file present.

## OUTPUT — rails-engineer (general-purpose subagent)

- **Gem:** added `gem "rack-attack", "~> 6.7"` to `Gemfile`; `bundle install` resolved
  **rack-attack 6.8.0** (recorded in the gitignored `Gemfile.lock`).
- **Initializer** `config/initializers/rack_attack.rb`: throttle `"api"` matching `.json`/`.xml`
  paths; discriminator `X-Redmine-API-Key → ?key= → Basic-auth username → IP`, with any
  credential reduced to a 16-hex SHA256 fingerprint (raw key never used as a cache key or
  logged); `throttled_responder` returning 429 + `Retry-After` + JSON body; limit/period from
  `Redmine::Configuration['api_rate_limit']` defaulting to 60/60.
- **`configuration.yml.example`:** documented `api_rate_limit:` block (`limit`, `period`) under
  `default:`.
- **Load check:** `bundle exec rails runner 'puts Rack::Attack.throttles.keys.inspect'` → `["api"]`.
- **Sanity walkthrough** (rebuilt the discriminator via `Rack::MockRequest`):

  | Scenario | Discriminator | Throttled? |
  |---|---|---|
  | (a) `GET /issues.json` + `X-Redmine-API-Key` | `api-key:<sha256 fp>` | Yes |
  | (b) `GET /issues.json?key=...` | `api-key:<sha256 fp>` | Yes |
  | (c) `GET /issues` (HTML, no key) | `nil` | **No — never throttled** |
  | (d) `GET /issues.json` + Basic auth | `api-key:<sha256 fp of username>` | Yes |

---

## Orchestrator verification (caught a real bug)

Running the load check myself surfaced `Rack::Attack.cache.store == ActiveSupport::Cache::NullStore`.
**In Rails development `Rails.cache` is the NullStore by default** — it discards every write, so
throttle counters never accumulate and **throttling would silently never fire** (the live 429
demo, a DoD item, would fail). Patched the initializer to fall back to a real `MemoryStore` when
`Rails.cache` is a NullStore — keeping the "use Rails.cache" intent while guaranteeing the
throttle works out of the box (production still overrides `config.cache_store` with Redis/memcached):

```ruby
rack_attack_store = Rails.cache
if rack_attack_store.is_a?(ActiveSupport::Cache::NullStore)
  rack_attack_store = ActiveSupport::Cache::MemoryStore.new
end
Rack::Attack.cache.store = rack_attack_store
```

Re-check → `store=ActiveSupport::Cache::MemoryStore`. ✅

## Live smoke test (restarted server, real HTTP)

```bash
KEY=<redacted>; for i in $(seq 1 70); do curl ... -H "X-Redmine-API-Key: $KEY" \
  http://localhost:3000/issues.json; done
# → 60× 200, then 10× 429

# 429 response:
HTTP/1.1 429 Too Many Requests
content-type: application/json
retry-after: 19
{"error":"Too Many Requests","message":"API rate limit exceeded. Retry in 19s.","retry_after":19}

# Web UI exemption (80 HTML hits):
for i in $(seq 1 80); do curl ... http://localhost:3000/issues; done
# → 80× 200, never throttled
```

Core slice proven end-to-end. Files changed: `Gemfile`, `config/configuration.yml.example`,
`config/initializers/rack_attack.rb` (new). `Gemfile.lock` updated locally (gitignored).
