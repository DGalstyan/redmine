# frozen_string_literal: true

# Structured audit logging for THROTTLED API requests only (Redmine #43881, pillar 4).
#
# Rack::Attack publishes "<match_type>.rack_attack" via ActiveSupport::Notifications
# (see rack-attack 6.8.0 lib/rack/attack.rb#instrument), payload key :request. We
# subscribe to the throttle event and emit one JSON line per throttle match.
#
# Why a log line and NOT a DB insert: this runs on a hot request path. Per-request
# DB writes add write traffic and row/lock contention (mirrors the maintainer
# concern in Redmine #43938). An append-only log line is cheap and contention-free.
#
# Privacy: the discriminator is already a safe fingerprint string
# ("api-key:<16hexSHA256>" or "api-ip:<ip>") set by the Phase-1 throttle block —
# the raw API key is never in it — so we log it verbatim, no re-hashing needed.

audit_logger = Logger.new(Rails.root.join('log', 'api_audit.log'))
audit_logger.formatter = ->(_severity, _time, _progname, msg) { "#{msg}\n" }

ActiveSupport::Notifications.subscribe('throttle.rack_attack') do |_name, _start, _finish, _id, payload|
  req = payload[:request] || payload[:req]
  next unless req && req.env['rack.attack.match_type'] == :throttle

  audit_logger.info({
    timestamp: Time.now.utc.iso8601,
    throttle: req.env['rack.attack.matched'],
    discriminator: req.env['rack.attack.match_discriminator'],
    path: req.path,
    method: req.request_method,
    ip: req.ip
  }.to_json)
end
