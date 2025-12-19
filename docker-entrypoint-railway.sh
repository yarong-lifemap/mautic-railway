#!/bin/sh
set -eu

echo "[railway] entrypoint starting"

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

# Sync helper (best-effort; avoids deleting container-provided files)
# Usage: sync_dir <container_dir> <persist_dir>
# Behavior:
# - If persist_dir is empty: seed it from container_dir
# - Else: hydrate container_dir from persist_dir
sync_dir() {
  CONTAINER_DIR="$1"; PERSIST_DIR="$2"
  mkdir -p "$CONTAINER_DIR" "$PERSIST_DIR"

  if [ -z "$(ls -A "$PERSIST_DIR" 2>/dev/null || true)" ]; then
    cp -a "$CONTAINER_DIR"/. "$PERSIST_DIR"/ 2>/dev/null || true
  else
    cp -a "$PERSIST_DIR"/. "$CONTAINER_DIR"/ 2>/dev/null || true
  fi
}

# Ensure Mautic dirs exist as real directories (no symlinks)
mkdir -p "${CONFIG_DIR}" "${LOGS_DIR}" "${MEDIA_DIR}"

# Important: remove symlinks if a previous version created them
if [ -L "${CONFIG_DIR}" ]; then rm -f "${CONFIG_DIR}"; mkdir -p "${CONFIG_DIR}"; fi
if [ -L "${LOGS_DIR}" ]; then rm -f "${LOGS_DIR}"; mkdir -p "${LOGS_DIR}"; fi
if [ -L "${MEDIA_DIR}" ]; then rm -f "${MEDIA_DIR}"; mkdir -p "${MEDIA_DIR}"; fi

# Sync the three directories between /data and container paths
sync_dir "${CONFIG_DIR}" "${PERSIST_CONFIG}"
sync_dir "${LOGS_DIR}" "${PERSIST_LOGS}"
sync_dir "${MEDIA_DIR}" "${PERSIST_MEDIA}"

# Final permissions (best-effort)
if [ -n "${APACHE_USER:-}" ]; then
  chown -R "${APACHE_USER}:${APACHE_GROUP:-${APACHE_USER}}" "${CONFIG_DIR}" "${LOGS_DIR}" "${MEDIA_DIR}" || true
fi
chmod -R a+rwX "${CONFIG_DIR}" "${LOGS_DIR}" "${MEDIA_DIR}" || true

# Minimal runtime info
echo "[railway][fs] whoami: $(whoami 2>/dev/null || true)"
echo "[railway][fs] id: $(id 2>/dev/null || true)"
echo "[railway][fs] apache user/group: ${APACHE_USER:-?}:${APACHE_GROUP:-?}"
ls -ld "${CONFIG_DIR}" "${LOGS_DIR}" "${MEDIA_DIR}" || true
ls -ld "${PERSIST_CONFIG}" "${PERSIST_LOGS}" "${PERSIST_MEDIA}" || true

# Keep group-writable defaults for created files
umask 0002

exec "$@"
