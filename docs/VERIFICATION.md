# Verifying the rate limiter

Two ways: a live curl loop (a reviewer sees the 429 happen) and the automated test.

## Prerequisites

- App running (`bundle exec rails server -p 3000`) per the redmine-dev-setup skill.
- REST API enabled and an API key in hand (`<KEY>` below).
- Default limit is 60 requests / 60s; adjust the loop count if you changed it.

## Live 429 (curl)

Fire more requests than the limit within the window and watch the status codes flip from
200 to 429:

```bash
KEY="<KEY>"
for i in $(seq 1 70); do
  printf "req %02d -> " "$i"
  curl -s -o /dev/null -w "%{http_code}\n" \
    -H "X-Redmine-API-Key: $KEY" \
    http://localhost:3000/issues.json
done
```

Expected: a run of `200`s, then `429`s once you cross the limit.

Inspect the 429 response in full (headers + body):

```bash
curl -s -D - -o - \
  -H "X-Redmine-API-Key: $KEY" \
  http://localhost:3000/issues.json | sed -n '1,20p'
```

Expected to include:
```
HTTP/1.1 429 Too Many Requests
Retry-After: <seconds>
Content-Type: application/json
...
{"error":"Too Many Requests","message":"API rate limit exceeded. Retry in ...s.","retry_after":...}
```

## Confirm the web UI is exempt

```bash
for i in $(seq 1 80); do
  curl -s -o /dev/null -w "%{http_code} " http://localhost:3000/issues
done; echo
```

Expected: all `200` (or `302` to login) — never `429`.

## Automated test

```bash
RAILS_ENV=test bundle exec rake db:migrate
RAILS_ENV=test bundle exec ruby -Itest test/integration/api_rate_limit_test.rb
```

Expected: all assertions pass — over-limit → 429 with `Retry-After`, under-limit → 200,
web UI never throttled, distinct keys have independent budgets.
