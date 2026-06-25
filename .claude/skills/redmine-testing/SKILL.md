---
name: redmine-testing
description: Write and run deterministic Redmine integration/unit tests following the project's conventions — including enabling Rack::Attack in the test env and resetting the throttle cache between tests. Use when adding test coverage to Redmine.
---

# Redmine testing

Redmine uses Rails' built-in `ActiveSupport::TestCase` / `ActionDispatch::IntegrationTest`
(aliased as `Redmine::IntegrationTest`) with fixtures, under `test/`.

## Layout & running

- Integration tests: `test/integration/*_test.rb`. Unit: `test/unit/`. Functional: `test/functional/`.
- Prepare the test DB once: `RAILS_ENV=test bundle exec rake db:migrate`.
- Run a single file:
  ```bash
  RAILS_ENV=test bundle exec ruby -Itest test/integration/api_rate_limit_test.rb
  ```
- Load fixtures with `fixtures :users, :projects, ...` as needed.

## Deterministic Rack::Attack tests

Rack::Attack and the cache make tests order-dependent unless you control them:

```ruby
class ApiRateLimitTest < Redmine::IntegrationTest
  fixtures :users, :projects, :issues, :roles, :members, :member_roles,
           :enabled_modules, :issue_statuses, :trackers

  def setup
    Setting.rest_api_enabled = '1'
    Rack::Attack.enabled = true
    # A real, clearable store — Rails.cache is a NullStore in some envs and never throttles.
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.cache.store.clear
    @key = User.find(1).api_key  # admin
  end

  def teardown
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
  end
end
```

Reset the cache in `setup`/`teardown` so each test starts at zero. If the limit is large, either
lower it for the test (re-read config / stub) or loop past whatever the configured limit is and
assert on the final response.

## What to assert for rate limiting

1. **Over limit → 429:** hammer `get '/issues.json', headers: {'X-Redmine-API-Key' => @key}`
   past the limit; assert `response.status == 429`, a `Retry-After` header, and a JSON body with
   `error`/`retry_after`.
2. **Under limit → 200:** a few requests stay 200.
3. **Web UI exempt:** hammer `get '/issues'` (HTML) well past the limit; never 429.
4. **Independent budgets:** exhaust key A, then key B's first request is still 200.

Always paste the **real** run output, not just the expected output.
