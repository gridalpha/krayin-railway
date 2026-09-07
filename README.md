# Krayin CRM on Railway

A production image for [Krayin CRM](https://github.com/krayin/laravel-crm) — the
open-source Laravel CRM for leads, contacts, quotes and sales pipelines — built
to run on [Railway](https://railway.com) against managed MySQL and Redis.

## Why this repo exists

Krayin publishes no single-application image. `webkul/krayin` runs a MySQL
server *inside* the container, bakes the schema into the image layer at build
time and, pointed at an external database, never installs into it — and its
newest tag is 2.2.0 while upstream is on 2.2.5.

So this builds Krayin from its own release tag on the official `php:8.3-fpm`
image and adds what a platform deployment needs:

- **Managed MySQL and Redis**, with the app running as a MySQL role scoped to
  its own schema — provisioned at boot from Railway's admin credentials, which
  are then dropped from the environment before anything else starts.
- **An idempotent first-boot install.** The installer runs only while the
  `users` table is empty; every later boot runs `migrate --force`.
- **No default credentials, ever.** Krayin's `UserSeeder` inserts
  `admin@example.com` / `admin123` as user 1 on every fresh install with no way
  to change it. That row is replaced from `ADMIN_EMAIL` / `ADMIN_PASSWORD`
  before supervisord starts, so those credentials are never valid on a
  reachable deployment — and the `storage/installed` marker that closes the web
  installer is written in the same pass.
- **`APP_KEY` derived from a seed**, so Laravel keeps one stable encryption key
  across deploys even though `.env` lives in the container layer.
- **nginx on `$PORT`**, with PHP, application and access logs on stdout/stderr.
- **The real client IP and forwarded scheme** handed to PHP as `REMOTE_ADDR` and
  `HTTPS` from the leftmost `X-Forwarded-For` entry, so Laravel is correct behind
  the platform edge with no trusted-proxy list to get wrong.
- **Queue workers and the scheduler** supervised beside the web server.

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | builds Krayin from `KRAYIN_VERSION` on `php:8.3-fpm-bookworm` |
| `rootfs/usr/local/bin/railway-entrypoint.sh` | configuration, install, tuning |
| `rootfs/usr/local/bin/railway-krayin.php` | `.env` writer, MySQL provisioning, first admin |
| `rootfs/etc/nginx/` | nginx config, and `fastcgi_params` with `REMOTE_ADDR`/`HTTPS` rewritten |
| `rootfs/etc/supervisor/conf.d/krayin.conf` | nginx, php-fpm, queue workers, scheduler |
| `rootfs/usr/local/etc/` | php-fpm pool and php.ini overrides |
| `overrides/routes/console.php` | upstream's file, with the inbound-email schedule gated on the IMAP receiver |

## Why one container and not a worker service

Krayin's Data Transfer jobs read the uploaded CSV/XLSX back through
`Storage::disk('public')->path()`, a local filesystem call no object-storage
disk can answer, and the app renders logos, avatars and activity attachments
with `Storage::url()`. A separate worker service would get its own volume —
Railway volumes are 1:1 — and every import would fail to find its file. Upstream
runs the same shape: one container, supervised.

`schedule:work` has no leader election, so this service must stay at one replica.

## Environment

Required: `DB_HOST`, `DB_PASSWORD`, `ADMIN_EMAIL`, `ADMIN_PASSWORD`, and either
`APP_KEY_SEED` or an explicit `APP_KEY`.

Everything else has a working default. `APP_URL` is derived from
`RAILWAY_PUBLIC_DOMAIN` unless set; `DB_ADMIN_USERNAME` / `DB_ADMIN_PASSWORD`
are optional and only used to create the app's database and role.

## Licence

Krayin CRM is MIT-licensed by Webkul. This repository holds only the deployment
wrapper.
