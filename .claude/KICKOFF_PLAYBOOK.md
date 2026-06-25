# Kickoff Playbook — Redmine #43881 Rate-Limiting Slice

Run these phases **in order**. Each prompt is addressed to a named agent (see
`.claude/agents/`). Commit at every phase boundary using the suggested message. The whole
slice is designed to fit comfortably and stay defensible — resist scope creep into the
deferred pillars.

> Convention: in Claude Code, invoke a subagent by addressing it
> (e.g. *"Use the rails-engineer subagent to…"*). The agent automatically pulls in the
> skills it needs. In Cursor/aider, paste the relevant `SKILL.md` body into context and
> address the role inline.

---

## Phase 0 — Scope & setup (orchestrator → redmine-dev-setup)

**Prompt → orchestrator**
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

**Prompt → orchestrator** (delegates setup)
```
Use the redmine-dev-setup skill to get a runnable Redmine on tag 6.1.2 with SQLite,
the default data loaded, an admin user, the REST API enabled, and an API key in hand.
Output the exact commands you ran and the API key, and confirm `GET /issues.json` works
with that key. Stop once the app boots and the API responds.
```

**Commit:** `chore: scaffold dev env + slice boundary for #43881`
**Artifact:** save this whole exchange to `ai-artifacts/phase0-scope-and-setup.md`.

---

## Phase 1 — Rate-limiting core (rails-engineer → rack-attack-rate-limiting, redmine-api-auth-model)

**Prompt → rails-engineer**
```
Implement API rate limiting using Rack::Attack. Requirements:

- Add rack-attack to the bundle (prefer Gemfile.local so upgrades stay clean; Gemfile is
  acceptable since this is a fork).
- New initializer config/initializers/rack_attack.rb.
- THROTTLE SCOPE: only API requests. Match paths ending in .json or .xml. Leave the web
  UI completely untouched.
- DISCRIMINATOR (keying), in this priority order, per the redmine-api-auth-model skill:
    1. X-Redmine-API-Key request header
    2. ?key= query param
    3. HTTP Basic auth username (Redmine accepts the API key as the basic-auth user)
    4. fall back to client IP
- LIMIT: configurable, not hardcoded. Read requests-per-period and period from
  config/configuration.yml (with sane defaults, e.g. 60 requests / 60 seconds). Document
  the keys you add in configuration.yml.example.
- RESPONSE: return 429 with a JSON body and a Retry-After header computed from the
  throttle match data. Use throttled_responder (current Rack::Attack API).
- CACHE: use Rails.cache. Note in a code comment that production needs a shared store
  (Redis/memcached); the memory store is per-process only.

Follow the rack-attack-rate-limiting skill exactly for the responder and discriminator
shapes. Show me the full initializer and the configuration.yml changes. Do not add an
admin UI — limits via config file only for this slice.
```

**Prompt → rails-engineer** (sanity pass)
```
Walk me through three request scenarios against your code and tell me the discriminator
value and whether it throttles: (a) GET /issues.json with X-Redmine-API-Key header,
(b) GET /issues.json?key=... , (c) GET /issues (HTML, no key). Confirm (c) is never
throttled. Fix anything that doesn't hold.
```

**Commit:** `feat(api): rate-limit REST API with Rack::Attack, return 429 (#43881)`
**Artifact:** `ai-artifacts/phase1-ratelimit-core.md`

---

## Phase 2 — Prove it (test-engineer → redmine-testing)

**Prompt → test-engineer**
```
Write an integration test that proves the rate limiter. Using the redmine-testing skill:

- Place it under test/integration/ following Redmine's conventions.
- Enable Rack::Attack in the test environment and reset the cache between tests so runs
  are deterministic.
- Test 1: hammer GET /issues.json with a valid API key past the configured limit and
  assert the final response is 429 with a Retry-After header and JSON body.
- Test 2: assert that requests UNDER the limit return 200.
- Test 3: assert the web UI (GET /issues, HTML) is never throttled even when hammered.
- Test 4 (keying): two different API keys get independent budgets.

Give me the exact command to run just this file, and the expected output. Then run it and
paste the result.
```

**Prompt → test-engineer** (manual proof for the README)
```
Use the rack-attack-rate-limiting + redmine-testing skills to produce a copy-pasteable
curl loop that a reviewer can run to see a 429 live. Add it to docs/VERIFICATION.md and
confirm it produces 200s then a 429.
```

**Commit:** `test(api): integration coverage for rate limiting + 429 behavior`
**Artifact:** `ai-artifacts/phase2-tests.md`

---

## Phase 3 — Audit logging of throttled requests (rails-engineer) — OPTIONAL STRETCH

Skip this if you're tight on time; the core slice is already complete after Phase 2.

**Prompt → rails-engineer**
```
Add lightweight, structured audit logging for throttled requests only (pillar 4, minimal
form). Subscribe to ActiveSupport::Notifications "throttle.rack_attack" (or the rack_attack
notification, per the skill). On a throttle match, write one structured line — JSON —
capturing: timestamp, discriminator (redacted: log key fingerprint, NOT the raw key),
request path, HTTP method, source IP, matched throttle name. Write to a dedicated logger
(log/api_audit.log), not the main Rails log. Keep it to ~30 lines. No DB writes (explain
in a comment why we avoid per-request DB writes here — write traffic / lock contention,
mirroring the maintainer concern in #43938).
```

**Commit:** `feat(api): structured audit log for throttled requests (#43881)`
**Artifact:** `ai-artifacts/phase3-audit-log.md`

---

## Phase 4 — README, ADR, artifacts (docs-writer → ai-workflow-capture)

**Prompt → docs-writer**
```
Using docs/ADR-001-rate-limiting.md as the source of truth for design + trade-offs, fill
in templates/README_SUBMISSION.md and place it as README at the repo root. It must cover:
approach, what's done, what's deferred (and why), assumptions, how to run, how to verify,
and a dedicated section on how the rate limiting works + the limits of the approach. Keep
it brief. Pull the verify steps from docs/VERIFICATION.md.
```

**Prompt → docs-writer**
```
Use the ai-workflow-capture skill to assemble the ai-artifacts/ folder: confirm each
phase transcript is present and named, write a one-page ai-artifacts/README.md that names
the tools used (Claude Code + which subagents/skills) and how they fit the workflow, and
sanity-check the commit history reads as a clean phase-by-phase story.
```

**Commit:** `docs: README, ADR, and AI workflow artifacts for #43881 slice`

---

## Definition of done

- [ ] `git clone` → install → `rake db:migrate` → boots on tag 6.1.2
- [ ] Over-limit API caller gets **429 + Retry-After**; under-limit gets 200
- [ ] Web UI never throttled
- [ ] Integration test passes; `docs/VERIFICATION.md` curl loop shows a live 429
- [ ] README covers approach / done / deferred / assumptions / run / verify / how-it-works + limits
- [ ] `ai-artifacts/` has per-phase transcripts + a tools-and-workflow note
- [ ] Commit history maps cleanly to the phases
