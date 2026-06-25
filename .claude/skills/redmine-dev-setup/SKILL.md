---
name: redmine-dev-setup
description: Boot a runnable Redmine on SQLite with the REST API enabled and an admin API key in hand, then confirm GET /issues.json returns JSON. Use when you need a local Redmine to develop or verify against.
---

# Redmine dev setup (SQLite + REST API)

Goal: a booting Redmine on tag 6.1.2, SQLite, default data, an admin user, REST API on, and an
API key you can curl with.

## 1. Toolchain

- Ruby per `.ruby-version` (3.3.x), Bundler 2.5.x.
- `bundle install` (SQLite needs no server).

## 2. Database (SQLite)

`config/database.yml`:

```yaml
development:
  adapter: sqlite3
  database: db/redmine.sqlite3
test:
  adapter: sqlite3
  database: db/test.sqlite3
```

Then:

```bash
bundle exec rake generate_secret_token        # if config/initializers/secret_token.rb absent
RAILS_ENV=development bundle exec rake db:migrate
RAILS_ENV=development REDMINE_LANG=en bundle exec rake redmine:load_default_data
```

## 3. Admin user + REST API + API key

The default admin is `admin` / `admin`. Enable the REST API and read the key without the UI:

```bash
# Enable REST API (stored in the settings table)
bundle exec rails runner 'Setting.rest_api_enabled = "1"'

# Read (or generate) the admin API key
bundle exec rails runner 'u=User.find_by_login("admin"); u.api_key.presence || u.generate_api_key; puts u.api_key'
```

`Setting` changes persist in the DB. If a server was already running before you toggled the
setting, restart it (settings are cached per process).

## 4. Boot and confirm

```bash
bundle exec rails server -p 3000 -e development
```

```bash
KEY=<api-key>
curl -s -H "X-Redmine-API-Key: $KEY" http://localhost:3000/issues.json
# => {"issues":[...],"total_count":...}   HTTP 200, content-type application/json
```

Prove key-auth is actually enforced (not anonymous fallthrough):

```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "X-Redmine-API-Key: $KEY" http://localhost:3000/users/current.json  # 200
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/users/current.json                               # 401
```

## Gotchas

- A populated `db/redmine.sqlite3` may already exist — don't blow it away.
- Never paste a real API key into committed files; redact it in artifacts.
