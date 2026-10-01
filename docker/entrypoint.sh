#!/bin/bash
# Roles: web (apache + first-run install), cron (scheduled jobs). Config is env-driven; no secrets in the image.
set -euo pipefail
cd /var/www/html
ROLE="${1:-web}"

: "${MAUTIC_DB_HOST:=mautic-db}" "${MAUTIC_DB_PORT:=3306}" "${MAUTIC_DB_NAME:=mautic}"
: "${MAUTIC_DB_USER:=mautic}" "${MAUTIC_DB_PASSWORD:?MAUTIC_DB_PASSWORD required}"
: "${MAUTIC_URL:?MAUTIC_URL required}"

# make runtime env available to cron jobs
printenv | grep -E '^(MAUTIC_|APP_|PHP_|RESEND_)' | sed 's/^/export /; s/=/="/; s/$/"/' > /etc/mautic.env || true
chmod 600 /etc/mautic.env

until mysqladmin ping -h"$MAUTIC_DB_HOST" -P"$MAUTIC_DB_PORT" -u"$MAUTIC_DB_USER" -p"$MAUTIC_DB_PASSWORD" --silent 2>/dev/null; do
  echo "waiting for database..."; sleep 3
done

mkdir -p var/cache var/logs var/tmp config media/files media/images
chown -R www-data:www-data var config media

patch_mailer() {
  [ -f config/local.php ] || return 0
  [ -n "${RESEND_API_KEY:-}" ] || return 0
  php -r '
    include "config/local.php";
    $parameters["mailer_dsn"] = "smtps://resend:" . rawurlencode(getenv("RESEND_API_KEY")) . "@smtp.resend.com:465";
    if (getenv("MAUTIC_MAIL_FROM_EMAIL")) { $parameters["mailer_from_email"] = getenv("MAUTIC_MAIL_FROM_EMAIL"); }
    if (getenv("MAUTIC_MAIL_FROM_NAME"))  { $parameters["mailer_from_name"]  = getenv("MAUTIC_MAIL_FROM_NAME"); }
    $parameters["site_url"] = getenv("MAUTIC_URL");
    file_put_contents("config/local.php", "<?php\n\$parameters = " . var_export($parameters, true) . ";\n");
  '
  chown www-data:www-data config/local.php
}

installed() { [ -f config/local.php ] && grep -q "'db_name'" config/local.php; }

install_if_needed() {
  installed && return 0
  : "${MAUTIC_ADMIN_EMAIL:?}" "${MAUTIC_ADMIN_PASSWORD:?}"
  echo "first run: installing Mautic..."
  su -s /bin/bash www-data -c "php bin/console mautic:install '$MAUTIC_URL' --force \
    --db_driver=pdo_mysql --db_host='$MAUTIC_DB_HOST' --db_port='$MAUTIC_DB_PORT' \
    --db_name='$MAUTIC_DB_NAME' --db_user='$MAUTIC_DB_USER' --db_password='$MAUTIC_DB_PASSWORD' \
    --admin_username='${MAUTIC_ADMIN_USERNAME:-admin}' --admin_email='$MAUTIC_ADMIN_EMAIL' \
    --admin_password='$MAUTIC_ADMIN_PASSWORD' \
    --admin_firstname='${MAUTIC_ADMIN_FIRSTNAME:-Admin}' --admin_lastname='${MAUTIC_ADMIN_LASTNAME:-User}'"
}

case "$ROLE" in
  web)
    install_if_needed
    patch_mailer
    su -s /bin/bash www-data -c "php bin/console cache:clear --no-interaction" || true
    chown -R www-data:www-data var
    exec apache2-foreground ;;
  cron)
    until installed; do echo "waiting for install..."; sleep 5; done
    install -m 0644 /etc/mautic-crontab /etc/cron.d/mautic
    touch /var/log/mautic-cron.log
    cron && exec tail -F /var/log/mautic-cron.log ;;
  *) exec "$@" ;;
esac
