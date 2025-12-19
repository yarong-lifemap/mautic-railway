#!/bin/sh
set -eu

echo "[railway] entrypoint starting"

# Optional role switch (lets Railway run this image as a non-web service without a custom start command)
ROLE="${ROLE:-web}"
if [ "${ROLE}" = "fuse-test" ]; then
  echo "[railway] ROLE=fuse-test; running /usr/local/bin/railway-fuse-test.sh"
  exec /usr/local/bin/railway-fuse-test.sh
fi

# Force a single Apache MPM at runtime too (some environments enable modules at container start).
a2dismod mpm_event mpm_worker mpm_prefork >/dev/null 2>&1 || true

a2enmod mpm_prefork >/dev/null 2>&1 || true

a2dismod mpm_event mpm_worker >/dev/null 2>&1 || true

# Show active MPM modules for debugging (one line each).
apache2ctl -M 2>/dev/null | grep -E 'mpm_(event|worker|prefork)_module' || true

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

MAUTIC_ROOT="/var/www/html"

CONFIG_DIR="${MAUTIC_ROOT}/config"
LOGS_DIR="${MAUTIC_ROOT}/var/logs"
MEDIA_DIR="${MAUTIC_ROOT}/docroot/media"

PERSIST_CONFIG="/data/config"
PERSIST_LOGS="/data/logs"
PERSIST_MEDIA="/data/media"

# Detect which user Apache will run as (and thus PHP/mod_php)
APACHE_USER=""
APACHE_GROUP=""
if [ -f /etc/apache2/envvars ]; then
  # shellcheck disable=SC1091
  . /etc/apache2/envvars || true
  APACHE_USER="${APACHE_RUN_USER:-}"; APACHE_GROUP="${APACHE_RUN_GROUP:-}"
fi

# Prepare persistent dirs
mkdir -p "${PERSIST_CONFIG}" "${PERSIST_LOGS}" "${PERSIST_MEDIA}" /data/tmp

# Ensure Apache runtime user can write to persisted volume paths.
if [ -n "${APACHE_USER:-}" ]; then
  chown -R "${APACHE_USER}:${APACHE_GROUP:-${APACHE_USER}}" /data || true
fi
chmod -R a+rwX /data || true

# Sync helper (best-effort; avoids deleting files)
# Usage:
# - seed_or_hydrate_dir <container_dir> <persist_dir>
# - sync_back_dir <container_dir> <persist_dir>
seed_or_hydrate_dir() {
  CONTAINER_DIR="$1"; PERSIST_DIR="$2"
  mkdir -p "$CONTAINER_DIR" "$PERSIST_DIR"

  if [ -z "$(ls -A "$PERSIST_DIR" 2>/dev/null || true)" ]; then
    # Seed persist dir once
    cp -a "$CONTAINER_DIR"/. "$PERSIST_DIR"/ 2>/dev/null || true
  else
    # Hydrate container dir at startup
    cp -a "$PERSIST_DIR"/. "$CONTAINER_DIR"/ 2>/dev/null || true
  fi
}

sync_back_dir() {
  CONTAINER_DIR="$1"; PERSIST_DIR="$2"
  mkdir -p "$CONTAINER_DIR" "$PERSIST_DIR"
  # Copy container -> persist (no deletes). This is reliable and simple; can accumulate stale files.
  cp -a "$CONTAINER_DIR"/. "$PERSIST_DIR"/ 2>/dev/null || true
}

# Ensure Mautic dirs exist as real directories (no symlinks)
mkdir -p "${CONFIG_DIR}" "${LOGS_DIR}" "${MEDIA_DIR}"

# Important: remove symlinks if a previous version created them
if [ -L "${CONFIG_DIR}" ]; then rm -f "${CONFIG_DIR}"; mkdir -p "${CONFIG_DIR}"; fi
if [ -L "${LOGS_DIR}" ]; then rm -f "${LOGS_DIR}"; mkdir -p "${LOGS_DIR}"; fi
if [ -L "${MEDIA_DIR}" ]; then rm -f "${MEDIA_DIR}"; mkdir -p "${MEDIA_DIR}"; fi

# Sync the three directories between /data and container paths
seed_or_hydrate_dir "${CONFIG_DIR}" "${PERSIST_CONFIG}"
seed_or_hydrate_dir "${LOGS_DIR}" "${PERSIST_LOGS}"
seed_or_hydrate_dir "${MEDIA_DIR}" "${PERSIST_MEDIA}"

# Final permissions (best-effort)
if [ -n "${APACHE_USER:-}" ]; then
  chown -R "${APACHE_USER}:${APACHE_GROUP:-${APACHE_USER}}" "${CONFIG_DIR}" "${LOGS_DIR}" "${MEDIA_DIR}" || true
fi
chmod -R a+rwX "${CONFIG_DIR}" "${LOGS_DIR}" "${MEDIA_DIR}" || true

# Minimal startup info (keep this short; logs are noisy on Railway)
echo "[railway] apache user/group: ${APACHE_USER:-?}:${APACHE_GROUP:-?}"
# Background sync loop (container -> /data) for reliability
# Configurable via env vars:
# - SYNC_INTERVAL_SECONDS (default 30)
# - SYNC_ENABLED (default 1)
SYNC_ENABLED="${SYNC_ENABLED:-1}"
SYNC_INTERVAL_SECONDS="${SYNC_INTERVAL_SECONDS:-30}"

echo "[railway] persistence dirs: config/logs/media -> /data (interval=${SYNC_INTERVAL_SECONDS}s)"

if [ "${SYNC_ENABLED}" != "0" ]; then
  (
    while true; do
      sync_back_dir "${CONFIG_DIR}" "${PERSIST_CONFIG}"
      sync_back_dir "${LOGS_DIR}" "${PERSIST_LOGS}"
      sync_back_dir "${MEDIA_DIR}" "${PERSIST_MEDIA}"
      sleep "${SYNC_INTERVAL_SECONDS}" || sleep 30
    done
  ) >/dev/null 2>&1 &
  echo "[railway] background sync enabled (interval=${SYNC_INTERVAL_SECONDS}s)"
else
  echo "[railway] background sync disabled"
fi

# Keep group-writable defaults for created files
umask 0002

exec "$@"
