#!/bin/bash
#
# Krayin entrypoint for Railway.
#
# Everything here runs before supervisord starts anything, so the public
# listener never opens on a half-configured application — in particular the
# seeded admin@example.com / admin123 account never exists on a reachable
# deployment, and the web installer is already closed by its own marker.
#
set -euo pipefail

APP_DIR="${APP_DIR:-/var/www/krayin}"
SKELETON=/opt/krayin-storage-skel
HELPER=/usr/local/bin/railway-krayin.php

log() { printf '[railway] %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

cd "$APP_DIR"

# ---------------------------------------------------------------------------
# Configuration
#
# Nothing below has to be supplied by hand except the first admin's address and
# password and one seed for APP_KEY. The public URL comes from the platform,
# because Krayin bakes APP_URL into every generated link and every Storage::url.
# ---------------------------------------------------------------------------
: "${DB_HOST:?DB_HOST is required — reference the MySQL service's MYSQLHOST}"
: "${DB_PASSWORD:?DB_PASSWORD is required — the password of the app's own MySQL role}"
: "${ADMIN_EMAIL:?ADMIN_EMAIL is required — it becomes the first admin account}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required — it becomes the first admin password}"

# Laravel needs a stable 32-byte key: everything it has ever encrypted becomes
# unreadable if it changes, and .env lives in the container layer, which Railway
# rebuilds on every deploy. So it is derived from a seed that a variable *can*
# carry, and an operator migrating an existing install can still set APP_KEY
# directly to keep their old one.
if [ -z "${APP_KEY:-}" ]; then
    : "${APP_KEY_SEED:?APP_KEY_SEED is required unless APP_KEY is set explicitly}"
    APP_KEY="base64:$(php -r 'echo base64_encode(hash("sha256", getenv("APP_KEY_SEED"), true));')"
    log "APP_KEY derived from APP_KEY_SEED"
fi
export APP_KEY

# A ${{…RAILWAY_PUBLIC_DOMAIN}} reference renders to the empty string until the
# service owns a deployment, so an operator-supplied APP_URL can arrive as a
# bare scheme. Treat that as unset rather than baking "https://" into every
# generated link.
case "${APP_URL:-}" in
    ''|'https://'|'http://'|'https:///'|'http:///') APP_URL='' ;;
esac

if [ -z "${APP_URL:-}" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    APP_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi

export APP_NAME="${APP_NAME:-Krayin CRM}"
export APP_ENV="${APP_ENV:-production}"
export APP_DEBUG="${APP_DEBUG:-false}"
export APP_URL="${APP_URL:-http://localhost}"
export APP_ADMIN_PATH="${APP_ADMIN_PATH:-admin}"
export APP_TIMEZONE="${APP_TIMEZONE:-UTC}"
export APP_LOCALE="${APP_LOCALE:-en}"
export APP_CURRENCY="${APP_CURRENCY:-USD}"

export DB_CONNECTION="${DB_CONNECTION:-mysql}"
export DB_PORT="${DB_PORT:-3306}"
export DB_DATABASE="${DB_DATABASE:-krayin}"
export DB_USERNAME="${DB_USERNAME:-krayin}"
export DB_PREFIX="${DB_PREFIX:-}"

# Same empty-reference trap as APP_URL above: ${{mailpit.RAILWAY_PRIVATE_DOMAIN}}
# is blank until mailpit owns a deployment, which is exactly the state a
# one-click template deploy starts in. Private hostnames are deterministic, so
# repair it on the value's shape rather than letting the mailer point at nothing.
case "${MAIL_HOST:-}" in
    ''|':'*) MAIL_HOST=mailpit.railway.internal ;;
esac
export MAIL_HOST

export LOG_CHANNEL="${LOG_CHANNEL:-stderr}"
export LOG_LEVEL="${LOG_LEVEL:-info}"

export PORT="${PORT:-8080}"
export QUEUE_WORKERS="${QUEUE_WORKERS:-2}"
export QUEUE_NAMES="${QUEUE_NAMES:-default}"
export NGINX_WORKER_PROCESSES="${NGINX_WORKER_PROCESSES:-2}"
export CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-64M}"

case "$QUEUE_WORKERS" in
    ''|*[!0-9]*) log "QUEUE_WORKERS is not a number ('$QUEUE_WORKERS') — using 2"; export QUEUE_WORKERS=2 ;;
esac

# ---------------------------------------------------------------------------
# storage/
#
# The Railway volume mounts here and starts empty, hiding the tree the release
# ships — including the Data Transfer sample CSVs the import screen links to.
# `cp -an` seeds it once and never overwrites live data.
# ---------------------------------------------------------------------------
if [ -d "$SKELETON" ]; then
    mkdir -p "$APP_DIR/storage"

    if ! cp -an "$SKELETON/." "$APP_DIR/storage/"; then
        log "WARNING: seeding storage from the image skeleton reported an error"
    fi
fi

mkdir -p "$APP_DIR/storage/app/public" \
         "$APP_DIR/storage/framework/cache/data" \
         "$APP_DIR/storage/framework/sessions" \
         "$APP_DIR/storage/framework/views" \
         "$APP_DIR/storage/logs" \
         "$APP_DIR/bootstrap/cache"

fix_permissions() {
    chown -R www-data:www-data "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"
    chmod -R 775 "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"
}

fix_permissions

# ---------------------------------------------------------------------------
# .env
#
# Krayin's installer reads APP_ENV, APP_URL and the DB_* values out of the .env
# *file* rather than the process environment (Installer::getEnvAtRuntime), so
# the file has to be the source of truth, not a formality.
# ---------------------------------------------------------------------------
ENV_KEYS=(
    APP_NAME APP_ENV APP_KEY APP_DEBUG APP_URL APP_ADMIN_PATH
    APP_TIMEZONE APP_LOCALE APP_CURRENCY
    DB_CONNECTION DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD DB_PREFIX
    BROADCAST_DRIVER CACHE_DRIVER SESSION_DRIVER SESSION_CONNECTION
    SESSION_LIFETIME SESSION_SECURE_COOKIE QUEUE_CONNECTION FILESYSTEM_DISK
    LOG_CHANNEL LOG_LEVEL
    REDIS_CLIENT REDIS_HOST REDIS_PORT REDIS_PASSWORD REDIS_DB REDIS_CACHE_DB
    MAIL_MAILER MAIL_HOST MAIL_PORT MAIL_USERNAME MAIL_PASSWORD MAIL_ENCRYPTION
    MAIL_FROM_ADDRESS MAIL_FROM_NAME MAIL_DOMAIN
    MAIL_RECEIVER_DRIVER
    IMAP_HOST IMAP_PORT IMAP_ENCRYPTION IMAP_VALIDATE_CERT IMAP_USERNAME IMAP_PASSWORD
    GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_REDIRECT_URI
)

sync_env() {
    php "$HELPER" env "$APP_DIR/.env" "${ENV_KEYS[@]}"
    chown www-data:www-data "$APP_DIR/.env"
    chmod 640 "$APP_DIR/.env"
}

[ -f "$APP_DIR/.env" ] || cp "$APP_DIR/.env.example" "$APP_DIR/.env"
sync_env

php artisan config:clear >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
php "$HELPER" provision
php "$HELPER" wait

if php "$HELPER" installed; then
    log "Krayin is already installed — applying pending migrations only"
    php artisan migrate --force
else
    log "empty database — running the Krayin installer"

    # krayin-crm:install delegates to key:generate and migrate:fresh without
    # passing --force, so Laravel's "APPLICATION IN PRODUCTION" guard cancels
    # both in a non-interactive run — and the installer carries on, printing its
    # success lines against a database with no tables.
    #
    # A process-level APP_ENV does not get past it: the installer assigns
    # app()['env'] from the .env *file*. Flip the file for the length of the
    # install and put it back afterwards.
    (
        export APP_ENV=local
        sync_env
        php artisan krayin-crm:install --skip-env-check --skip-admin-creation --no-interaction
    )

    # key:generate rewrote APP_KEY in .env with a value no later deploy could
    # reproduce. The derived one is what Laravel must keep using.
    sync_env

    # The installer swallows failures from every step it delegates, so confirm
    # the install landed rather than trusting its exit code.
    if ! php "$HELPER" installed; then
        log "ERROR: krayin-crm:install finished but the users table is empty — the migrations did not run"
        exit 1
    fi

    # Krayin's UserSeeder always inserts admin@example.com / admin123 as user 1.
    # Replace it here, while nothing is listening yet.
    php "$HELPER" admin
fi

# Closes the installer: CanInstall and every /install/api endpoint check for
# this file, and the app has no other lock on them.
if [ ! -f "$APP_DIR/storage/installed" ]; then
    printf 'installed by railway-entrypoint on %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        > "$APP_DIR/storage/installed"
fi

php artisan storage:link >/dev/null 2>&1 || true

fix_permissions

# ---------------------------------------------------------------------------
# Runtime tuning
#
# nginx and php-fpm both size themselves from the host, which on Railway is a
# 48-core machine the container has no claim on.
# ---------------------------------------------------------------------------
memory_bytes=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)

if [ "$memory_bytes" = "max" ] || [ -z "$memory_bytes" ]; then
    memory_mb=2048
else
    memory_mb=$((memory_bytes / 1024 / 1024))
fi

# ~96 MB per php-fpm worker, leaving headroom for the queue workers, the
# scheduler and opcache.
max_children=$((memory_mb / 96))

if [ "$max_children" -lt 4 ]; then
    max_children=4
elif [ "$max_children" -gt 40 ]; then
    max_children=40
fi

start_servers=$((max_children / 4))
[ "$start_servers" -lt 2 ] && start_servers=2

max_spare=$((max_children / 2))
[ "$max_spare" -lt "$start_servers" ] && max_spare=$start_servers

pool=/usr/local/etc/php-fpm.d/zz-railway.conf
sed -i -E "s/^pm\.max_children[[:space:]]*=.*/pm.max_children = ${max_children}/" "$pool"
sed -i -E "s/^pm\.start_servers[[:space:]]*=.*/pm.start_servers = ${start_servers}/" "$pool"
sed -i -E "s/^pm\.min_spare_servers[[:space:]]*=.*/pm.min_spare_servers = ${start_servers}/" "$pool"
sed -i -E "s/^pm\.max_spare_servers[[:space:]]*=.*/pm.max_spare_servers = ${max_spare}/" "$pool"

# php-fpm refuses to start on an inconsistent pool (exit 78), which supervisord
# then retries into a FATAL state behind a container that still answers 502, so
# check the substitution landed rather than discovering it in a restart loop.
for key in max_children start_servers min_spare_servers max_spare_servers; do
    if ! grep -qE "^pm\.${key} = [0-9]+\$" "$pool"; then
        log "ERROR: php-fpm pool key pm.${key} was not rewritten"
        exit 1
    fi
done

php-fpm -t

mkdir -p /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi
chown -R www-data:www-data /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi

sed -i -e "s/__WORKER_PROCESSES__/${NGINX_WORKER_PROCESSES}/" \
       -e "s/__CLIENT_MAX_BODY_SIZE__/${CLIENT_MAX_BODY_SIZE}/" /etc/nginx/nginx.conf
sed -i -e "s/__PORT__/${PORT}/g" /etc/nginx/conf.d/krayin.conf

if grep -q '__[A-Z_]*__' /etc/nginx/nginx.conf /etc/nginx/conf.d/krayin.conf; then
    log "ERROR: an nginx placeholder survived substitution"
    exit 1
fi

nginx -t

log "container memory ${memory_mb}MB -> pm.max_children=${max_children}, nginx worker_processes=${NGINX_WORKER_PROCESSES}, listening on ${PORT}"

# route:cache is the only half of `optimize` that can fail on a closure route,
# and losing it costs performance rather than correctness.
php artisan config:cache
php artisan event:cache >/dev/null 2>&1 || true
php artisan view:cache >/dev/null 2>&1 || true
php artisan route:cache >/dev/null 2>&1 || { log "route cache skipped"; php artisan route:clear >/dev/null 2>&1 || true; }

fix_permissions

# The superuser credentials were only ever needed to create the app's own role.
# Nothing that runs from here on should be able to read them — a queue worker
# executes user-supplied import data, and supervisord passes its environment to
# every child.
unset DB_ADMIN_USERNAME DB_ADMIN_PASSWORD ADMIN_PASSWORD APP_KEY_SEED

log "starting supervisord: nginx + php-fpm + ${QUEUE_WORKERS} queue worker(s) + scheduler"

exec "$@"
