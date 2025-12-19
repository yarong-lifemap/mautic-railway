#!/bin/sh
set -eu

# If Apache errors with "<Directory> was not closed" on Railway, it usually means
# /etc/apache2/conf-available/zz-railway.conf was corrupted/partially-written at runtime.
# As a guardrail, validate/restore it from the baked-in image copy before starting Apache.
if [ -f /etc/apache2/conf-available/zz-railway.conf ]; then
  # Ensure the file has a closing tag; if not, restore from image layer backup.
  if ! grep -q '</Directory>' /etc/apache2/conf-available/zz-railway.conf; then
    echo "[railway] zz-railway.conf appears corrupted (missing </Directory>); restoring"
    if [ -f /zz-railway.conf ]; then
      cp /zz-railway.conf /etc/apache2/conf-available/zz-railway.conf
    fi
  fi
fi

# Always (re)create the enabled symlink at runtime (some platforms/volumes can clobber conf-enabled).
ln -sf ../conf-available/zz-railway.conf /etc/apache2/conf-enabled/zz-railway.conf

# Log what Apache will actually parse (since you don't have shell access).
echo "[railway] --- /etc/apache2/conf-enabled/zz-railway.conf ---"
cat -n /etc/apache2/conf-enabled/zz-railway.conf || true

echo "[railway] --- /etc/apache2/conf-available/zz-railway.conf ---"
cat -n /etc/apache2/conf-available/zz-railway.conf || true

echo "[railway] --- ls -l /etc/apache2/conf-enabled/zz-railway.conf /etc/apache2/conf-available/zz-railway.conf ---"
ls -l /etc/apache2/conf-enabled/zz-railway.conf /etc/apache2/conf-available/zz-railway.conf || true

echo "[railway] --- apache2ctl -t (configtest) ---"
apache2ctl -t || true

MAUTIC_ROOT="/var/www/html"

mkdir -p /data/config /data/logs /data/media /data/tmp

# Make it writable regardless of runtime UID (Railway volumes often mount as root:root)
chmod -R a+rwX /data || true

# Replace expected Mautic paths with symlinks into /data
rm -rf "${MAUTIC_ROOT}/config" || true
rm -rf "${MAUTIC_ROOT}/var/logs" || true
rm -rf "${MAUTIC_ROOT}/docroot/media" || true

ln -s /data/config "${MAUTIC_ROOT}/config"
mkdir -p "${MAUTIC_ROOT}/var"
ln -s /data/logs "${MAUTIC_ROOT}/var/logs"
mkdir -p "${MAUTIC_ROOT}/docroot"
ln -s /data/media "${MAUTIC_ROOT}/docroot/media"

# Keep group-writable defaults for created files
umask 0002

exec "$@"
