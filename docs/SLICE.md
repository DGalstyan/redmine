# Slice boundary — Redmine #43881

## In / out / why (one paragraph)

This slice ships **one defensible thing: working API rate limiting** on Redmine's REST API —
over-limit API callers get **HTTP 429 + `Retry-After`**, under-limit callers get 200, and the
web UI is never throttled — implemented as Rack::Attack middleware keyed on the API credential
(fingerprinted) with limits read from `config/configuration.yml`. As a cheap stretch it adds
**structured audit logging of throttled requests only** to a dedicated log. Everything else in
the ticket — personal access tokens, token expiration, OAuth-style scopes, per-endpoint access
control, CORS configuration, and an admin UI for limits — is **deferred**, because each is an
independent pillar that would balloon the diff and the review surface; the chosen slice is the
one hard requirement (429) plus the lowest-cost adjacent win, and the deferred pillars can
layer on top of this middleware without reworking it.

## 5-step plan (maps to .claude/KICKOFF_PLAYBOOK.md phases)

1. **Phase 0 — scope & setup:** lock the boundary (this file) and stand up a runnable Redmine
   on SQLite with the REST API on and an API key in hand. *(setup confirmed working — see
   `ai-artifacts/phase0-scope-and-setup.md`.)*
2. **Phase 1 — rate-limiting core:** add Rack::Attack; new `config/initializers/rack_attack.rb`
   throttling only `.json`/`.xml` paths, keyed `X-Redmine-API-Key → ?key= → Basic-auth user →
   IP`; configurable limit/period; 429 JSON responder with `Retry-After`.
3. **Phase 2 — prove it:** integration test (over-limit→429, under-limit→200, web-UI never
   throttled, distinct keys = independent budgets) + a copy-pasteable curl loop in
   `docs/VERIFICATION.md`.
4. **Phase 3 — audit logging (optional stretch):** subscribe to the rack_attack throttle
   notification; one structured JSON line per throttle (fingerprinted key, path, method, IP,
   throttle name) to `log/api_audit.log`. No per-request DB writes.
5. **Phase 4 — docs & artifacts:** README from `templates/README_SUBMISSION.md` grounded in
   `docs/ADR-001-rate-limiting.md`; assemble `ai-artifacts/` with a tools-and-workflow note.

## Files expected to add / touch (kept minimal)

| File | Add/Touch | Purpose |
| --- | --- | --- |
| `Gemfile.local` | add | pull in `rack-attack` (keeps `Gemfile` upgrade-clean) |
| `config/initializers/rack_attack.rb` | add | the throttle, discriminator, and 429 responder |
| `config/configuration.yml.example` | touch | document `api_rate_limit.{limit,period}` keys |
| `test/integration/api_rate_limit_test.rb` | add | Phase 2 integration coverage |
| `docs/VERIFICATION.md` | touch | live curl-loop proof (already scaffolded) |
| `config/initializers/rack_attack_audit.rb` *(or appended)* | add | Phase 3 throttle audit log |
| `README.md` | add | submission README (Phase 4) |
| `ai-artifacts/*` | add | per-phase transcripts + workflow note |

No admin UI, no schema migration, no controller changes.
