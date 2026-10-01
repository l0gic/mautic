# Mautic (l0gic fork, 7.2.1 base) - built from THIS repo so fork changes are what runs.
# One image, two roles (web / cron) selected by the container command.
FROM php:8.3-apache-bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
      git unzip curl ca-certificates libicu-dev libzip-dev libpng-dev libjpeg-dev \
      libfreetype6-dev libxml2-dev libonig-dev libc-client-dev libkrb5-dev libssl-dev \
 && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \
 && docker-php-ext-install -j"$(nproc)" intl zip gd imap pdo_mysql bcmath mbstring exif opcache pcntl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /var/www/html
COPY . .
ENV COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 APP_ENV=prod APP_DEBUG=0
RUN composer install --no-dev --optimize-autoloader --no-interaction \
 && rm -rf node_modules .git /root/.npm /root/.composer/cache

# ---- runtime ----
# Pinned to bookworm: the runtime package names below (libicu72, libzip4, ...) are Debian 12 names.
FROM php:8.3-apache-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
      cron libicu72 libzip4 libpng16-16 libjpeg62-turbo libfreetype6 libxml2 libonig5 libc-client2007e libkrb5-3 mariadb-client \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=build /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d
COPY --from=build /var/www/html /var/www/html

RUN a2enmod rewrite headers expires \
 && printf 'memory_limit=512M\nupload_max_filesize=64M\npost_max_size=64M\nmax_execution_time=300\ndate.timezone=UTC\nopcache.enable=1\nopcache.validate_timestamps=0\n' > /usr/local/etc/php/conf.d/zz-mautic.ini \
 && sed -ri 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf

COPY docker/entrypoint.sh /usr/local/bin/mautic-entrypoint
COPY docker/crontab /etc/mautic-crontab
RUN chmod +x /usr/local/bin/mautic-entrypoint
WORKDIR /var/www/html
ENTRYPOINT ["mautic-entrypoint"]
CMD ["web"]
