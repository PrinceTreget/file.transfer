# Messenger

A small chat website written in Ruby (Sinatra + Puma) with a PostgreSQL database.
Users sign up, chat in a shared "Everyone" room or privately one-to-one, and send
files and images (drag and drop, paste, or the 📎 button) from any laptop's browser.

## Requirements

- Ruby 3.1+
- PostgreSQL 13+ (with the `libpq` development headers so the `pg` gem can build)

## Setup

```bash
cd messenger
bundle install

createdb messenger
psql messenger -f db/schema.sql
```

If your Postgres needs a user/password, set `DATABASE_URL`:

```bash
export DATABASE_URL="postgres://USER:PASSWORD@localhost:5432/messenger"
```

## Run

```bash
bundle exec puma -b tcp://0.0.0.0:4567 -t 0:8 config.ru
```

Open `http://localhost:4567` on the host laptop.

## Use it from other laptops

1. Put all laptops on the same Wi-Fi / network.
2. Find the host laptop's IP address (`ipconfig` on Windows, `ifconfig` / `ip a` on Mac/Linux), e.g. `192.168.1.20`.
3. On the other laptops open `http://192.168.1.20:4567` and create an account.
4. If it won't connect, allow port 4567 through the host laptop's firewall.

## API

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/register` | `{username, password}` creates an account and logs in |
| POST | `/api/login` | `{username, password}` |
| POST | `/api/logout` | |
| GET | `/api/me` | Current user |
| GET | `/api/users` | All other users |
| GET | `/api/messages?with=all\|<user_id>&after=<message_id>` | Messages (latest 200 after the given id) |
| POST | `/api/messages` | multipart: `body`, optional `recipient_id`, optional `file` (max 25 MB) |
| GET | `/files/:id` | Download an attachment (only sender, recipient, or anyone for room messages) |

Uploaded files are stored in `uploads/`; their details are stored in the `messages` table.

## Notes

- This serves plain HTTP, which is fine on a trusted home or office network. To use it over
  the internet, put it behind HTTPS (for example Caddy or nginx) and also pass
  `secure: true` for the cookie in `start_session` in `app.rb`.
- Messages arrive by polling every 2 seconds, which keeps the code simple and reliable.
  It can be swapped for WebSockets later if you need instant delivery at larger scale.
