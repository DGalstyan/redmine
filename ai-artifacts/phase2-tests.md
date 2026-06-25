# Phase 2 — Prove it (tests)

**Role:** test-engineer (played by the Claude Code **general-purpose** subagent — the bespoke
`test-engineer` agent now exists at `.claude/agents/test-engineer.md` but was not yet loadable as
an Agent `subagent_type` mid-session). **Skill used:** `redmine-testing`
(`.claude/skills/redmine-testing/SKILL.md`, read by the subagent).

---

## PROMPT → test-engineer (verbatim, KICKOFF_PLAYBOOK.md Phase 2 — write the test)

```
Write an integration test that proves the rate limiter. Using the redmine-testing skill:
- Place it under test/integration/ following Redmine's conventions.
- Enable Rack::Attack in the test environment and reset the cache between tests so runs are
  deterministic.
- Test 1: hammer GET /issues.json with a valid API key past the configured limit and assert the
  final response is 429 with a Retry-After header and JSON body.
- Test 2: assert that requests UNDER the limit return 200.
- Test 3: assert the web UI (GET /issues, HTML) is never throttled even when hammered.
- Test 4 (keying): two different API keys get independent budgets.
Give me the exact command to run just this file, and the expected output. Then run it and paste
the result.
```

## OUTPUT — test-engineer

Wrote `test/integration/api_rate_limit_test.rb` (`Redmine::IntegrationTest`, 4 tests):

1. over-limit → 429 + `Retry-After` + JSON body (`error`, `retry_after`);
2. under-limit → 200;
3. HTML web UI (`GET /issues`) never 429 even when hammered;
4. two distinct API keys (admin + jsmith) get independent budgets.

**Run command:**
```bash
RAILS_ENV=test bundle exec ruby -Itest test/integration/api_rate_limit_test.rb
```

**Real output:**
```
4 runs, 27 assertions, 0 failures, 0 errors, 0 skips
```

### Real flake caught and fixed (the honest part)

The first pass was green, but a re-run intermittently failed Test 4 (`Expected 429, got 200`).
Root cause is a genuine timing issue, not a bad assertion: **Rack::Attack uses a fixed time
window** (`floor(now / period)`). With the shipped `period: 60`, a multi-second test firing 60+
requests can **straddle a 60s window boundary**, resetting the counter mid-loop so the final
request slips through as 200. Fix (the skill's sanctioned option): in `setup`, re-register the
`api` throttle **reusing the production discriminator block** (so keying and `.json`/`.xml`
matching are exactly what ships) but with `limit: 5, period: 3600`; the long window guarantees all
of a test's requests fall in one window. `teardown` restores the original throttle so no config
leaks between tests. Bonus: suite time dropped from ~26s to ~5s.

**Determinism:** each test starts from a freshly-cleared `MemoryStore` (Rails.cache is a NullStore
in test and never throttles), and the long-period re-registration removes the wall-clock boundary.

---

## Orchestrator verification

Ran the file independently three times — all green and stable:
```
run 1: 4 runs, 27 assertions, 0 failures, 0 errors, 0 skips
run 2: 4 runs, 27 assertions, 0 failures, 0 errors, 0 skips
run 3: 4 runs, 27 assertions, 0 failures, 0 errors, 0 skips
```

## Manual proof (Phase 2 — second prompt)

The copy-pasteable reviewer curl loop already lives in [`docs/VERIFICATION.md`](../docs/VERIFICATION.md)
(scaffolded Phase 0). Its exact loop was confirmed **live** in Phase 1 against the running server:
60× `200` then `429` with `Retry-After: 19` + JSON body, and the HTML UI 80× `200` (never
throttled). No change needed.
