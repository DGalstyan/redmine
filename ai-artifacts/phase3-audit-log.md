# Phase 3 — Audit logging of throttled requests (optional stretch)

**Role:** rails-engineer (played by the Claude Code **general-purpose** subagent; bespoke
`rails-engineer` agent at `.claude/agents/rails-engineer.md`). **Skills assumed:**
`rack-attack-rate-limiting` (notification model). Pillar 4, minimal form.

---

## PROMPT → rails-engineer (verbatim, KICKOFF_PLAYBOOK.md Phase 3)

```
Add lightweight, structured audit logging for throttled requests only (pillar 4, minimal form).
Subscribe to ActiveSupport::Notifications "throttle.rack_attack" (or the rack_attack notification,
per the skill). On a throttle match, write one structured line — JSON — capturing: timestamp,
discriminator (redacted: log key fingerprint, NOT the raw key), request path, HTTP method, source
IP, matched throttle name. Write to a dedicated logger (log/api_audit.log), not the main Rails log.
Keep it to ~30 lines. No DB writes (explain in a comment why we avoid per-request DB writes here —
write traffic / lock contention, mirroring the maintainer concern in #43938).
```

## OUTPUT — rails-engineer

**Verified the notification against the installed gem** (rack-attack 6.8.0, `lib/rack/attack.rb`):

```ruby
def instrument(request)
  event_type = request.env["rack.attack.match_type"]
  notifier.instrument("#{event_type}.rack_attack", request: request)
  notifier.instrument("rack.attack", request: request)   # deprecated, back-compat
end
```

→ event name **`throttle.rack_attack`**, payload key **`:request`**. Subscribed to the specific
event and additionally guarded on `match_type == :throttle`.

New initializer `config/initializers/rack_attack_audit.rb` (the discriminator is already a safe
fingerprint set by the Phase-1 throttle, so it is logged verbatim — no re-hashing, no raw key):

```ruby
audit_logger = Logger.new(Rails.root.join('log', 'api_audit.log'))
audit_logger.formatter = ->(_s, _t, _p, msg) { "#{msg}\n" }

ActiveSupport::Notifications.subscribe('throttle.rack_attack') do |_n, _s, _f, _id, payload|
  req = payload[:request] || payload[:req]
  next unless req && req.env['rack.attack.match_type'] == :throttle
  audit_logger.info({
    timestamp: Time.now.utc.iso8601,
    throttle: req.env['rack.attack.matched'],
    discriminator: req.env['rack.attack.match_discriminator'],
    path: req.path, method: req.request_method, ip: req.ip
  }.to_json)
end
```

A code comment explains **no DB writes**: per-request inserts add write traffic and row/lock
contention on a hot path (mirrors the maintainer concern in Redmine #43938); an append-only log
line is cheap and contention-free.

**Real `log/api_audit.log` after hammering `GET /issues.json` (60×200 then 429s):**
```json
{"timestamp":"2026-06-25T10:12:14Z","throttle":"api","discriminator":"api-key:ec53152a52e5a6d7","path":"/issues.json","method":"GET","ip":"127.0.0.1"}
```
- Valid JSON, all keys present.
- `discriminator` is a fingerprint (`api-key:ec53152a52e5a6d7`), not the raw key.
- `grep -c 972d06864 log/api_audit.log` → **0** (raw key never logged).

---

## Orchestrator verification

```
config/initializers/rack_attack_audit.rb present
grep -c 972d06864 log/api_audit.log            -> 0
RAILS_ENV=test ... api_rate_limit_test.rb       -> 4 runs, 27 assertions, 0 failures
git check-ignore log/api_audit.log              -> ignored (runtime log; initializer is the tracked artifact)
```

The audit subscriber does not affect throttle behavior or the test suite.
