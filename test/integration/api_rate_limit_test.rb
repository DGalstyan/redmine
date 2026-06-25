# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require_relative '../test_helper'

# Integration test for the API rate limiter (Rack::Attack throttle "api",
# Redmine issue #43881). It proves: over-limit -> 429 + Retry-After + JSON,
# under-limit -> 200, the HTML web UI is never throttled, that two distinct
# API keys get independent budgets, and that a throttle appends one JSON line
# to log/api_audit.log (the rack_attack_audit.rb subscriber).
class ApiRateLimitTest < Redmine::IntegrationTest
  fixtures :users, :email_addresses, :projects, :issues, :roles, :members,
           :member_roles, :enabled_modules, :issue_statuses, :trackers,
           :projects_trackers, :enumerations

  def setup
    Setting.rest_api_enabled = '1'

    # Enable Rack::Attack and give it a real, clearable in-memory store.
    # Rails.cache is a NullStore in the test env and would never throttle,
    # so we swap in a MemoryStore we can clear before/after every test to
    # keep counters deterministic and isolated between runs.
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.cache.store.clear

    # Re-register the "api" throttle deterministically for the duration of the
    # test, reusing the production discriminator (so keying/path-matching are
    # exactly what ships) but with a small limit and a LONG period.
    #
    # Why: Rack::Attack uses a fixed time window (floor(now / period)). With the
    # shipped period of 60s, a multi-second test that fires 60+ requests can
    # straddle a window boundary mid-loop, reset the counter, and let the final
    # request through as 200 -- a real, wall-clock-driven flake. A long period
    # guarantees every request in a single test falls in one window. We keep the
    # original discriminator block and restore the original throttle in teardown.
    @original_api_throttle = Rack::Attack.throttles['api']
    discriminator = @original_api_throttle.block
    @limit = 5
    Rack::Attack.throttle('api', :limit => @limit, :period => 3600, &discriminator)

    # admin
    @key = User.find(1).api_key

    # second user (jsmith) for the independent-budget test. User#api_key lazily
    # creates an 'api'-action token when the fixtures don't ship one.
    @key2 = User.find(2).api_key
  end

  def teardown
    # Restore the production throttle so we don't leak test config into other
    # tests that may run in the same process.
    Rack::Attack.throttles['api'] = @original_api_throttle if @original_api_throttle
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
  end

  # Test 1: hammering the JSON API past the limit yields 429 + Retry-After + JSON.
  def test_api_over_limit_is_throttled_with_429
    last_status = nil
    (@limit + 5).times do
      get '/issues.json', :headers => {'X-Redmine-API-Key' => @key}
      last_status = response.status
    end

    assert_equal 429, last_status,
                 "expected the final request past the limit to be throttled"

    assert response.headers['Retry-After'].present?,
           "expected a Retry-After header on the throttled response"

    assert_equal 'application/json', response.media_type
    body = JSON.parse(response.body)
    assert_equal 'Too Many Requests', body['error']
    assert body.key?('retry_after'), "expected a retry_after key in the JSON body"
    assert body['retry_after'].to_i >= 0
  end

  # Test 2: staying under the limit keeps returning 200.
  def test_api_under_limit_returns_200
    (@limit - 1).times do
      get '/issues.json', :headers => {'X-Redmine-API-Key' => @key}
      assert_equal 200, response.status,
                   "requests under the limit must not be throttled"
    end
  end

  # Test 3: the HTML web UI is never throttled, even when hammered well past
  # the limit (the throttle only matches .json/.xml paths).
  def test_web_ui_is_never_throttled
    (@limit + 10).times do
      get '/issues'
      assert_not_equal 429, response.status,
                       "the HTML web UI must never be rate limited"
    end
  end

  # Test 4 (keying): two different API keys get independent budgets.
  def test_distinct_api_keys_have_independent_budgets
    # Exhaust key A.
    (@limit + 5).times do
      get '/issues.json', :headers => {'X-Redmine-API-Key' => @key}
    end
    assert_equal 429, response.status, "key A should be throttled after exhaustion"

    # Key B's first request must still be allowed.
    get '/issues.json', :headers => {'X-Redmine-API-Key' => @key2}
    assert_equal 200, response.status,
                 "a different API key must have its own independent budget"
  end

  # Test 5 (audit log): a throttled API request appends exactly one structured
  # JSON line to log/api_audit.log, proving the rack_attack_audit.rb subscriber
  # fires end-to-end on a throttle match (not merely that the file exists). The
  # subscriber is synchronous (ActiveSupport::Notifications.instrument), so the
  # line is on disk by the time the throttled request returns.
  def test_throttle_appends_an_audit_log_line
    audit_path = Rails.root.join('log', 'api_audit.log')
    lines_before = File.exist?(audit_path) ? File.foreach(audit_path).count : 0

    # Drive past the limit; the audit subscriber only fires on an actual throttle.
    last_status = nil
    (@limit + 5).times do
      get '/issues.json', :headers => {'X-Redmine-API-Key' => @key}
      last_status = response.status
    end
    assert_equal 429, last_status, "precondition: the request must be throttled"

    lines = File.foreach(audit_path).to_a
    assert lines.size > lines_before,
           "expected a new audit line appended to #{audit_path} on throttle"

    entry = JSON.parse(lines.last)
    assert_equal 'api', entry['throttle']
    assert_equal '/issues.json', entry['path']
    assert entry['discriminator'].to_s.start_with?('api-'),
           "expected a fingerprinted discriminator, got #{entry['discriminator'].inspect}"
  end
end
