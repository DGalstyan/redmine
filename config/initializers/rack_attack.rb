# frozen_string_literal: true

# API rate limiting via Rack::Attack (Redmine issue #43881).
#
# Scope: ONLY API requests are throttled. A request is considered an API
# request when its path ends in ".json" or ".xml". The web UI (HTML) is
# never matched, so it is completely untouched by this throttle.
#
# Discriminator (cache key) priority:
#   1. X-Redmine-API-Key request header
#   2. ?key= query parameter
#   3. HTTP Basic auth username (Redmine accepts the API key as the basic-auth user)
#   4. client IP (fallback)
#
# Any credential is hashed with SHA256 and only a short fingerprint is used as
# the cache key, so the raw API key never becomes a cache key or appears in logs.
#
# Limits are configurable via config/configuration.yml under the
# "api_rate_limit" key (limit / period), with safe hardcoded fallbacks so the
# initializer boots cleanly even when no configuration.yml is present.

# Guard the require so the app still boots if the gem is somehow absent.
# (It is declared in the Gemfile, so in practice it will always be present.)
begin
  require 'rack/attack'
rescue LoadError
  Rails.logger.warn('rack-attack gem not available; API rate limiting disabled') if defined?(Rails)
else
  require 'digest'

  # --- Configuration ---------------------------------------------------------
  # Read requests-per-period and period from configuration.yml (per current
  # environment), falling back to sane defaults (60 requests / 60 seconds).
  api_rate_limit_config = (Redmine::Configuration['api_rate_limit'] || {})
  api_rate_limit        = (api_rate_limit_config['limit']  || 60).to_i
  api_rate_period       = (api_rate_limit_config['period'] || 60).to_i

  # --- Cache store -----------------------------------------------------------
  # Use Rails.cache as the backing store for throttle counters.
  #
  # NOTE: In production you MUST use a shared cache store (Redis or memcached).
  # The default memory store (ActiveSupport::Cache::MemoryStore) is per-process,
  # so with multiple app processes/workers each one keeps its own counters and
  # the effective limit becomes (limit * number_of_processes).
  #
  # However, Rails.cache defaults to a NullStore in the development environment
  # (and anywhere caching is disabled), which silently discards every write — so
  # counters would never accumulate and throttling would never fire. Fall back to
  # a dedicated in-process MemoryStore in that case so rate limiting works out of
  # the box; a real deployment overrides config.cache_store with a shared store.
  rack_attack_store = Rails.cache
  if rack_attack_store.is_a?(ActiveSupport::Cache::NullStore)
    rack_attack_store = ActiveSupport::Cache::MemoryStore.new
  end
  Rack::Attack.cache.store = rack_attack_store

  # --- Helpers ---------------------------------------------------------------
  # Short, non-reversible fingerprint of a credential for use as a cache key.
  api_fingerprint = lambda do |value|
    Digest::SHA256.hexdigest(value.to_s)[0, 16]
  end

  # Returns true when the request targets an API endpoint (.json/.xml path).
  api_request = lambda do |req|
    path = req.path.to_s
    path.end_with?('.json') || path.end_with?('.xml')
  end

  # --- Throttle --------------------------------------------------------------
  # Returning nil/false from the block means "do not count this request",
  # which is exactly how non-API (web UI) requests are exempted.
  Rack::Attack.throttle('api', limit: api_rate_limit, period: api_rate_period) do |req|
    next nil unless api_request.call(req)

    # 1. X-Redmine-API-Key header
    api_key = req.get_header('HTTP_X_REDMINE_API_KEY')

    # 2. ?key= query parameter
    api_key ||= req.params['key']

    # 3. HTTP Basic auth username (Redmine accepts the API key as the username)
    if api_key.nil? || api_key.empty?
      basic = Rack::Auth::Basic::Request.new(req.env)
      api_key = basic.username if basic.provided? && basic.basic? && basic.credentials
    end

    if api_key && !api_key.empty?
      "api-key:#{api_fingerprint.call(api_key)}"
    else
      # 4. Fall back to client IP
      "api-ip:#{req.ip}"
    end
  end

  # --- Throttled response ----------------------------------------------------
  # Return 429 with a JSON body and a Retry-After header computed from the
  # throttle match data (current Rack::Attack API).
  Rack::Attack.throttled_responder = lambda do |request|
    match_data  = request.env['rack.attack.match_data'] || {}
    period      = (match_data[:period] || api_rate_period).to_i
    epoch_time  = (match_data[:epoch_time] || Time.now.to_i).to_i
    retry_after = period.zero? ? 0 : (period - (epoch_time % period))

    body = {
      error: 'Too Many Requests',
      message: "API rate limit exceeded. Retry in #{retry_after}s.",
      retry_after: retry_after
    }.to_json

    [
      429,
      {
        'Content-Type' => 'application/json',
        'Retry-After'  => retry_after.to_s
      },
      [body]
    ]
  end
end
