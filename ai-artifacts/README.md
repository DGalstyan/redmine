# AI artifacts — how this slice was built

This folder shows *how* the #43881 rate-limiting slice was produced, not just the result.
It is meant to be honest: it names the real tool, the subagents and skills per phase, and
flags where stand-ins were used instead of the bespoke agents.

## Tool

Everything here was built with **Claude Code** (Anthropic), running the **Opus 4.8** model.
The work followed `KICKOFF_PLAYBOOK.md`, which defines a five-phase slice and a set of
purpose-built subagents and skills to drive each phase.

## Subagents and skills

The playbook's bespoke subagents and skills live in `.claude/`:

- **Agents:** `orchestrator`, `rails-engineer`, `test-engineer`, `docs-writer`
  (plus helpers `slice-scoper`, `redmine-dev-setup`, `rack-attack-api-throttle`,
  `rate-limit-tracer`).
- **Skills:** `redmine-dev-setup`, `rack-attack-rate-limiting`, `redmine-api-auth-model`,
  `redmine-testing`, `ai-workflow-capture`.

**Important honesty note:** Phases 0 and 1 were executed *before* those bespoke agents/skills
were available as loadable subagents in the session, so they were run with stand-ins — Claude
Code played the orchestrator directly, and the rate-limiting core was delegated to the
general-purpose subagent with the relevant skill knowledge **inlined into the prompt**. Each
phase transcript records this at the top. The bespoke definitions now ship in `.claude/` for
re-runs and future phases.

## Phase → agent → skill → output

| Phase | Agent (as run) | Skill(s) | Output | Status |
| --- | --- | --- | --- | --- |
| 0 — scope & setup | `orchestrator` *(Claude Code directly — stand-in)* | `redmine-dev-setup` *(inlined)* | [`docs/SLICE.md`](../docs/SLICE.md), runnable Redmine 6.1.2 on SQLite + REST API | ✅ done |
| 1 — rate-limit core | `rails-engineer` *(general-purpose subagent — stand-in)* | `rack-attack-rate-limiting`, `redmine-api-auth-model` *(inlined)* | `config/initializers/rack_attack.rb`, `Gemfile`, `config/configuration.yml.example` | ✅ done |
| 2 — prove it | `test-engineer` *(general-purpose subagent — stand-in)* | `redmine-testing` | `test/integration/api_rate_limit_test.rb` (4 tests, green), [`docs/VERIFICATION.md`](../docs/VERIFICATION.md) | ✅ done |
| 3 — audit logging (stretch) | `rails-engineer` *(general-purpose subagent — stand-in)* | `rack-attack-rate-limiting` | `config/initializers/rack_attack_audit.rb` → `log/api_audit.log` (fingerprinted, no raw key) | ✅ done (shipped) |
| 4 — docs & artifacts | `docs-writer` | `ai-workflow-capture` | [`../README.md`](../README.md), [`docs/ADR-001-rate-limiting.md`](../docs/ADR-001-rate-limiting.md), this folder | ✅ done |

## Workflow

The orchestrator (Claude Code) held the slice boundary and delegated each phase to a focused
agent, then independently verified the result before moving on. Verification was not a
formality — running the Phase 1 load check itself surfaced a real bug: `Rails.cache` is a
`NullStore` in Rails development, so throttle counters were silently discarded and the limiter
never fired. The orchestrator patched the initializer to fall back to a `MemoryStore`, then
re-ran the live 70-request curl loop to confirm the 200→429 flip. That exchange is recorded in
`phase1-ratelimit-core.md`.

Each phase produced a transcript here — verbatim prompt + actual output + the orchestrator's
independent checks. The phase-by-phase story lives both in *these transcripts* and in git
history, which carries a commit per phase step (six in all; see below).

## The AI development loop

Every phase ran through the same closed loop. The orchestrator never accepted a subagent's
output on trust — it independently verified each result against the slice boundary and only
advanced when the check passed. A failed check fed back into the same agent with the concrete
evidence, rather than moving on.

```
        ┌──────────────────────────────────────────────────────────┐
        │                                                            │
        ▼                                                            │
  ┌───────────┐   delegate   ┌───────────────┐   output   ┌──────────────┐
  │ ORCHESTRA-│ ───────────► │ FOCUSED AGENT │ ─────────► │  VERIFY      │
  │ TOR holds │   scoped     │ rails-engineer│            │ run it for   │
  │ the slice │   task +     │ test-engineer │            │ real: test,  │
  │ boundary  │   skill      │ docs-writer   │            │ curl, reread │
  └───────────┘              └───────────────┘            └──────┬───────┘
        ▲                                                        │
        │                          fail → feed evidence back     │ pass
        └────────────────────────────────────────────────────────┤
                                                                  ▼
                                                          advance to next phase
```

**The loop earned its keep in Phase 1.** The verify step ran a live 70-request curl loop and
saw `200`s the whole way — no `429`. That surfaced a real bug: `Rails.cache` is a `NullStore`
in Rails development, so throttle counters were silently discarded and the limiter never fired.
The failed check fed straight back to the rails-engineer, which patched the initializer to fall
back to a `MemoryStore`; the re-run then showed the `200 → 429` flip. Without the verify-and-
feed-back loop, a broken limiter would have shipped looking correct. The exchange is recorded
verbatim in `phase1-ratelimit-core.md`.

## Artifact checklist

- [x] `phase0-scope-and-setup.md`
- [x] `phase1-ratelimit-core.md`
- [x] `phase2-tests.md` — integration suite (4 runs, 27 assertions, green; deterministic)
- [x] `phase3-audit-log.md` — throttle audit log shipped and verified
- [x] `README.md` (this file)
- Phase 4 docs are this README plus the repo `README.md`; no separate `phase4-docs.md` transcript.

All real credentials are redacted (`<REDACTED_DEV_API_KEY>`); no secrets are committed here.

## Phase map and commit presentation

The five phases were developed and verified in sequence, each leaving a transcript in this
folder (`phase0-*` … `phase3-*`, plus this README for Phase 4). Git history mirrors this: the
slice lands as **six phase commits** on top of the `6.1.2` fork tag (`1b5585ca9`) — Phase 0
split into scope (boundary + scaffolding) and setup (config bootstrap), then Phase 1 rate-limit
core, Phase 2 tests, Phase 3 audit log, Phase 4 docs — so the phase structure is carried by
both these transcripts and the commit history.
