---
name: rack-attack-rate-limiting
description: Throttle Rails/Redmine API requests with Rack::Attack — scope to API paths, key on the API credential fingerprint, and return 429 + Retry-After + JSON via throttled_responder. Use when adding request rate limiting to a Rack/Rails app.
---

# Rack::Attack API rate limiting

The canonical Rails answer for rate limiting: middleware that runs before routing, counts
requests per `(discriminator, window)` in a cache, and returns 429 when over the limit.

## Install (fork-friendly)

Add to the **tracked `Gemfile`** if `Gemfile.local` is gitignored (otherwise a fresh clone
won't get the gem):

```ruby
gem "rack-attack", "~> 6.7"   # resolves to 6.8.x
```

## Initializer shape (`config/initializers/rack_attack.rb`)

```ruby
require 'rack/attack'
require 'digest'

# Limit/period from config with safe defaults — must boot with no config file present.
cfg    = Redmine::Configuration['api_rate_limit'] || {}
limit  = (cfg['limit']  || 60).to_i
period = (cfg['period'] || 60).to_i

# Cache store. Rails.cache is a NullStore in development (discards writes => never throttles),
# so fall back to a real MemoryStore. Production overrides with a SHARED store (Redis/memcached);
# a per-process memory store makes the effective limit (limit * workers).
store = Rails.cache
store = ActiveSupport::Cache::MemoryStore.new if store.is_a?(ActiveSupport::Cache::NullStore)
Rack::Attack.cache.store = store

fingerprint = ->(v) { Digest::SHA256.hexdigest(v.to_s)[0, 16] }   # never key/log a raw credential

Rack::Attack.throttle('api', limit: limit, period: period) do |req|
  next nil unless req.path.end_with?('.json', '.xml')   # nil => not counted => web UI exempt
  key = req.get_header('HTTP_X_REDMINE_API_KEY')         # 1. header
  key ||= req.params['key']                              # 2. ?key=
  if key.to_s.empty?                                     # 3. Basic-auth username
    basic = Rack::Auth::Basic::Request.new(req.env)
    key = basic.username if basic.provided? && basic.basic? && basic.credentials
  end
  key.to_s.empty? ? "api-ip:#{req.ip}" : "api-key:#{fingerprint.call(key)}"   # 4. IP fallback
end

Rack::Attack.throttled_responder = lambda do |request|
  md = request.env['rack.attack.match_data'] || {}
  p  = (md[:period] || period).to_i
  retry_after = p.zero? ? 0 : p - ((md[:epoch_time] || Time.now.to_i).to_i % p)
  body = { error: 'Too Many Requests',
           message: "API rate limit exceeded. Retry in #{retry_after}s.",
           retry_after: retry_after }.to_json
  [429, { 'Content-Type' => 'application/json', 'Retry-After' => retry_after.to_s }, [body]]
end
```

## Key points

- **Return `nil`/`false`** from the throttle block to NOT count a request — this is how you
  exempt the web UI (any non-`.json`/`.xml` path).
- **`throttled_responder`** is the current API (not the deprecated `throttled_response`). Match
  data lives at `request.env['rack.attack.match_data']` with symbol keys `:count :limit :period
  :epoch_time :discriminator`.
- **Fixed window**, not sliding: a caller can burst up to ~2×limit across a boundary. Fine for
  abuse mitigation.
- **Verify live**, don't assume: `for i in $(seq 1 70); do curl -s -o /dev/null -w "%{http_code} "
  -H "X-Redmine-API-Key: $KEY" .../issues.json; done` should show 200s then 429s.

## Document the config (`config/configuration.yml.example`, under `default:`)

```yaml
  #api_rate_limit:
  #  limit: 60      # max requests per period
  #  period: 60     # window in seconds
```
