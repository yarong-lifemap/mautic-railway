#!/bin/sh
set -eu

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
