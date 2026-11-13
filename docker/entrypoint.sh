#!/bin/sh
set -e

# 所有需要持久化的运行时文件都放在 /data 卷中，再软链回应用目录：
#   /data/.env                 -> /www/.env              (首次启动自动生成，含 APP_KEY)
#   /data/config/v2board.php   -> /www/config/v2board.php (后台“系统配置”保存)
#   /data/config/theme/        -> /www/config/theme/      (后台“主题配置”保存)
#   /data/theme/               -> /www/public/theme/      (主题文件，可放自定义主题)
#   /data/logs/                -> /www/storage/logs/
mkdir -p /data/config/theme /data/theme /data/logs

# 每次启动把镜像内置主题同步到 /data/theme（覆盖同名内置主题以便随镜像更新，
# 其它自定义主题目录保持不变）
cp -a /usr/src/theme-dist/. /data/theme/

if [ ! -f /data/config/v2board.php ]; then
  printf '<?php\n return array (\n) ;' > /data/config/v2board.php
fi

ln -sfn /data/.env               /www/.env
ln -sfn /data/config/v2board.php /www/config/v2board.php
rm -rf /www/config/theme && ln -sfn /data/config/theme /www/config/theme
rm -rf /www/public/theme && ln -sfn /data/theme /www/public/theme
rm -rf /www/storage/logs && ln -sfn /data/logs /www/storage/logs

chown -R www-data:www-data /data /www/storage /www/bootstrap/cache

# 首次启动：生成 /data/.env 和 APP_KEY。数据库、Redis 等配置来自容器环境变量，优先级高于 .env
if [ ! -f /data/.env ]; then
  cp /www/.env.example /data/.env
  app_key="base64:$(php -r 'echo base64_encode(random_bytes(32));')"
  sed -i "s|^APP_KEY=.*|APP_KEY=${app_key}|" /data/.env
  chown www-data:www-data /data/.env
  echo "已生成 /data/.env"
fi

run_as_www() { su -s /bin/sh www-data -c "$*"; }
run_as_www "php /www/artisan config:cache"
run_as_www "php /www/artisan view:cache"
# 等待 MySQL/Redis，首次启动时导入数据库并按 ADMIN_EMAIL/ADMIN_PASSWORD 创建管理员；失败则退出让容器重启
run_as_www "php /www/artisan v2board:docker-init"

exec "$@"
