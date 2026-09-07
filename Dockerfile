# Krayin CRM on Railway
#
# Krayin publishes no single-application image: `webkul/krayin` bundles a MySQL
# server, bakes the schema into the image layer at build time and never installs
# into an external database — and its newest tag is 2.2.0 while upstream is on
# 2.2.5. So this builds Krayin from its own release tag on the official PHP
# image and adds the pieces Railway needs:
#
#   * managed MySQL and Redis instead of a database inside the container
#   * an idempotent first-boot install, with a scoped MySQL role provisioned
#     from Railway's admin credentials
#   * the first admin created from ADMIN_EMAIL / ADMIN_PASSWORD, never defaults
#   * nginx bound to $PORT, PHP and application logs on stdout/stderr
#   * the real client IP and forwarded scheme handed to PHP as REMOTE_ADDR and
#     HTTPS, so Laravel needs no trusted-proxy list
#   * queue workers and the scheduler supervised beside the web server, because
#     Railway volumes cannot be shared between services and Krayin's Data
#     Transfer jobs read the same storage/ tree the admin UI uploads to
#
# Override KRAYIN_VERSION to track a different upstream release; it must be a
# tag or branch of krayin/laravel-crm.

FROM php:8.3-fpm-bookworm

ARG KRAYIN_VERSION=v2.2.5

ENV APP_DIR=/var/www/krayin \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1

# Build dependencies are purged without --auto-remove on purpose: the runtime
# libraries the extensions link against (libicu, libgmp, libwebp …) arrive as
# dependencies of the -dev packages, and an auto-remove takes them with it —
# leaving an image whose intl and gmp extensions cannot load.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libfreetype6-dev \
        libgmp-dev \
        libicu-dev \
        libjpeg62-turbo-dev \
        libonig-dev \
        libpng-dev \
        libwebp-dev \
        libzip-dev \
        nginx \
        supervisor \
        unzip \
        zlib1g-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" \
        bcmath \
        calendar \
        exif \
        gd \
        gmp \
        intl \
        opcache \
        pcntl \
        pdo_mysql \
        sockets \
        zip; \
    pecl install redis; \
    docker-php-ext-enable redis; \
    apt-get purge -y libfreetype6-dev libgmp-dev libicu-dev libjpeg62-turbo-dev \
        libonig-dev libpng-dev libwebp-dev libzip-dev zlib1g-dev; \
    rm -rf /var/lib/apt/lists/* /tmp/pear; \
    php -r 'foreach (["bcmath","calendar","exif","gd","gmp","intl","Zend OPcache","pcntl","pdo_mysql","redis","sockets","zip","mbstring","openssl"] as $e) { if (! extension_loaded($e)) { fwrite(STDERR, "missing extension: $e\n"); exit(1); } }'

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

WORKDIR ${APP_DIR}

RUN set -eux; \
    git clone --depth 1 --branch "${KRAYIN_VERSION}" \
        https://github.com/krayin/laravel-crm.git .; \
    rm -rf .git; \
    composer install \
        --no-dev \
        --no-interaction \
        --prefer-dist \
        --optimize-autoloader \
        --no-scripts; \
    rm -rf /root/.composer /root/.cache /tmp/*

# A Railway volume mounted at $APP_DIR/storage hides everything the release
# ships there — the Data Transfer sample CSVs above all — so keep a pristine
# copy to seed an empty volume from. `installed` must never travel with it:
# CanInstall trusts that marker over the database, so a stale copy on a fresh
# database serves redirects instead of installing.
RUN set -eux; \
    cp -a "${APP_DIR}/storage" /opt/krayin-storage-skel; \
    rm -f /opt/krayin-storage-skel/installed; \
    rm -f /opt/krayin-storage-skel/logs/*.log

# The scheduled inbound-email command throws outright under the shipped
# `sendgrid` receiver ("bulk processing is not supported"), so upstream's
# unconditional schedule logs a stack trace every five minutes on any
# deployment that has not wired up IMAP. This copy runs it only when the
# operator has actually selected the IMAP receiver.
COPY overrides/routes/console.php ${APP_DIR}/routes/console.php

COPY rootfs/ /

RUN set -eux; \
    rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/default.conf; \
    mkdir -p /var/log/supervisor /var/lib/nginx /var/www/krayin/bootstrap/cache; \
    chmod +x /usr/local/bin/railway-entrypoint.sh; \
    bash -n /usr/local/bin/railway-entrypoint.sh; \
    php -l /usr/local/bin/railway-krayin.php; \
    php -l "${APP_DIR}/routes/console.php"; \
    chown -R www-data:www-data "${APP_DIR}"; \
    chmod -R 775 "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache"

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
