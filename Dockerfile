# syntax=docker/dockerfile:1

ARG PHP_VERSION=8.5

############################
# Stage 1: 安装 composer 依赖（在构建机原生架构上运行，避免 QEMU 下过慢）
############################
FROM --platform=$BUILDPLATFORM composer:2 AS vendor
WORKDIR /app
# Laravel 8 已 EOL，所有版本都有安全公告；Composer 2.9+ 默认会在解析阶段拦截，这里关闭拦截
ENV COMPOSER_NO_SECURITY_BLOCKING=1
ARG PHP_VERSION
COPY composer.json ./
# 按运行镜像的 PHP 版本解析依赖（构建机 composer 镜像的 PHP 版本可能不同）；
# 只忽略扩展要求（扩展装在运行镜像里），不忽略 PHP 版本要求
RUN composer config platform.php "${PHP_VERSION}.0" \
 && composer install \
      --no-dev --no-scripts --no-autoloader --no-interaction \
      --prefer-dist --ignore-platform-req='ext-*'

############################
# Stage 2: 运行镜像 (nginx + php-fpm + horizon + scheduler)
############################
FROM php:${PHP_VERSION}-fpm-alpine

ENV TZ=Asia/Shanghai \
    COMPOSER_ALLOW_SUPERUSER=1

COPY --from=mlocati/php-extension-installer:latest /usr/bin/install-php-extensions /usr/local/bin/
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

RUN apk upgrade --no-cache \
 && apk add --no-cache nginx supervisor tzdata bash ca-certificates \
 && install-php-extensions pdo_mysql redis igbinary pcntl bcmath zip sockets \
 && mkdir -p /run/nginx /data

WORKDIR /www

COPY --from=vendor /app/vendor ./vendor
COPY . .

RUN composer dump-autoload --optimize --no-dev --classmap-authoritative \
 && rm -f /usr/local/bin/composer \
 && mv public/theme /usr/src/theme-dist \
 && mkdir -p storage/logs storage/framework/cache storage/framework/sessions storage/framework/views bootstrap/cache config/theme \
 && chown -R www-data:www-data /www /data

COPY docker/nginx.conf       /etc/nginx/http.d/default.conf
COPY docker/php.ini          /usr/local/etc/php/conf.d/zz-v2board.ini
COPY docker/php-fpm.conf     /usr/local/etc/php-fpm.d/zz-v2board.conf
COPY docker/supervisord.conf /etc/supervisord.conf
COPY docker/entrypoint.sh    /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/data"]
EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
