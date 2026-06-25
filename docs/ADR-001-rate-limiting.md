# ADR-001 — API rate limiting for Redmine (#43881, pillar 3)

**Status:** accepted for this slice
**Context:** Redmine #43881 asks for several API hardening pillars. This slice implements
pillar 3 — request rate limiting that returns HTTP 429 — and treats the rest as deferred.
This record is the source of truth for the README's "how it works + limits" section.

## Decision

Use **Rack::Attack** as Rails middleware to throttle API requests, returning **429** with a
`Retry-After` header. Throttle is scoped to API requests (`.json`/`.xml` paths) and keyed on
the API credential (fingerprint), falling back to client IP. Limits are read from
`config/configuration.yml`.

## Alternatives considered

| Option | Why not (for this slice) |
| --- | --- |
| **Rack::Attack** ✅ | Battle-tested, middleware-level, returns 429 natively, integrates with `Rails.cache`, minimal code. Standard answer in the Rails ecosystem. |
| Custom Rack middleware | Reinvents counters, windows, and the responder Rack::Attack already gives us. More code to defend, no upside at this scope. |
| `before_action` in `ApplicationController` | Runs after routing and full request setup, so it wastes work on requests we mean to reject, and entangles limiting with controller logic. |
| Reverse proxy (nginx `limit_req`) | Real and common in production, but it's infra, not in the app, so the repo couldn't demonstrate or test it — and the ticket wants this in Redmine. |
| `rack-throttle` | Less maintained, fewer features than Rack::Attack. |

## How it works

1. Rack::Attack runs early in the middleware stack, before Rails routing/auth.
2. For each request the throttle block asks: is this an API request (`.json`/`.xml`)? If
   not, return `nil` → not counted (the web UI is never throttled).
3. If it is, compute a **discriminator**: `X-Redmine-API-Key` header → `?key=` param →
   HTTP Basic username → IP. A present credential is hashed (`SHA256`) so the raw key never
   becomes a cache key or a log line.
4. Rack::Attack increments a counter for `(discriminator, fixed window)` in `Rails.cache`.
   Over the limit → the `throttled_responder` returns 429 + `Retry-After`.
5. Limit and period come from `config/configuration.yml` (`api_rate_limit.limit/period`),
   defaulting to 60 requests / 60 seconds.

## Limits of this approach (state these plainly)

- **Per-process cache.** With the default memory store, each app worker/host keeps its own
  counters, so the effective limit is `limit × workers`. Production needs a shared store
  (Redis/memcached) via `Rails.cache`. This is the most important caveat.
- **Fixed window, not sliding.** A caller can send up to ~2×limit across a window boundary.
  Fine for abuse mitigation; not a precise quota.
- **Keys on the credential, not the user.** Middleware runs before Redmine resolves the
  user, so two valid keys owned by one person get independent budgets, and no per-user or
  per-role policy is possible at this layer.
- **Accept-header API calls.** Detection is by path extension; a client using
  `Accept: application/json` with no `.json` extension isn't recognized as API. Extendable,
  noted as a gap.
- **Proxy IP trust.** The IP fallback is only as good as `trusted_proxies` configuration;
  behind an unconfigured proxy, anonymous callers may collapse to one IP.
- **Scope.** This addresses bulk-extraction and brute-force *volume*. It does not implement
  the ticket's token expiration, scopes, audit query UI, endpoint control, or CORS.

## Consequences

A small, reviewable, testable change that satisfies the hard requirement and is honest
about where it stops. The deferred pillars can layer on top without reworking this.
