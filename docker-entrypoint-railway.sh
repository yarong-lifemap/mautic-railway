#!/bin/sh
set -eu

echo "[railway] entrypoint starting"

# Snapshot environment for debugging Railway deployments.
# NOTE: This contains secrets. Keep it inside the container filesystem and avoid printing to stdout.
# Location intentionally under /etc so it's easy to find in Railway SSH.
# Best-effort only; should never break container startup.
(
  umask 0077
  printenv | sort > /etc/environment 2>/dev/null || true
) >/dev/null 2>&1 || true

# Chain to upstream Mautic entrypoint so DOCKER_MAUTIC_ROLE works (mautic_web/mautic_cron/mautic_worker)
# We keep this wrapper to provide Railway-specific Apache guardrails + optional /data persistence hydration.
#
# NOTE: The upstream entrypoint requires DOCKER_MAUTIC_ROLE and checks DB connectivity and config/local.php.

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
THEMES_DIR="${MAUTIC_ROOT}/docroot/themes"

# For cron/worker roles (no shared volume on Railway), ensure local.php exists and includes
# at least db_driver + site_url, otherwise the upstream entrypoint will wait forever.
#
# Required env vars for this bootstrap:
# - MAUTIC_SITE_URL (public URL)
# - MAUTIC_SECRET_KEY (shared across all roles)
# - MAUTIC_DB_* (as per upstream template)
case "${DOCKER_MAUTIC_ROLE:-}" in
  mautic_cron|mautic_worker)
    if [ ! -f "${CONFIG_DIR}/local.php" ]; then
      echo "[railway] ${CONFIG_DIR}/local.php missing for role ${DOCKER_MAUTIC_ROLE}; generating from env"

      : "${MAUTIC_SITE_URL:?MAUTIC_SITE_URL is required for cron/worker}"
      : "${MAUTIC_SECRET_KEY:?MAUTIC_SECRET_KEY is required for cron/worker}"
      : "${MAUTIC_DB_DATABASE:?MAUTIC_DB_DATABASE is required}"
      : "${MAUTIC_DB_HOST:?MAUTIC_DB_HOST is required}"
      : "${MAUTIC_DB_USER:?MAUTIC_DB_USER is required}"
      : "${MAUTIC_DB_PASSWORD:?MAUTIC_DB_PASSWORD is required}"

      mkdir -p "${CONFIG_DIR}"
      cat > "${CONFIG_DIR}/local.php" <<'EOF'
<?php
$parameters = array(
  // Force TCP connectivity. If db_host is "localhost" libmysql often tries a unix socket and fails in containers.
  // Railway MySQL is reachable via an internal hostname, so using 127.0.0.1/localhost is never correct.
  'db_driver' => 'pdo_mysql',
  'db_host' => (getenv('MAUTIC_DB_HOST') === 'localhost') ? '127.0.0.1' : getenv('MAUTIC_DB_HOST'),
  'db_port' => getenv('MAUTIC_DB_PORT') ?: '3306',
  'db_name' => getenv('MAUTIC_DB_DATABASE'),
  'db_user' => getenv('MAUTIC_DB_USER'),
  'db_password' => getenv('MAUTIC_DB_PASSWORD'),
  'db_table_prefix' => getenv('MAUTIC_DB_TABLE_PREFIX') ?: null,

  // IMPORTANT: ensure no socket is used (prevents SQLSTATE[HY000] [2002] No such file or directory)
  'db_path' => null,

  'db_backup_tables' => 1,
  'db_backup_prefix' => 'bak_',
  'secret_key' => getenv('MAUTIC_SECRET_KEY'),
  'site_url' => getenv('MAUTIC_SITE_URL'),
);
EOF
      # Ensure PHP can read it even in cron/worker containers.
      # The upstream image defaults to www-data, but we use best-effort and permissive mode.
      chown "${MAUTIC_WWW_USER:-www-data}:${MAUTIC_WWW_GROUP:-www-data}" "${CONFIG_DIR}/local.php" 2>/dev/null || true
      chmod 644 "${CONFIG_DIR}/local.php" || true
    fi
    ;;
esac

PERSIST_CONFIG="/data/config"
PERSIST_LOGS="/data/logs"
PERSIST_MEDIA="/data/media"
PERSIST_THEMES="/data/themes"

# Detect which user Apache will run as (and thus PHP/mod_php)
APACHE_USER=""
APACHE_GROUP=""
if [ -f /etc/apache2/envvars ]; then
  # shellcheck disable=SC1091
  . /etc/apache2/envvars || true
  APACHE_USER="${APACHE_RUN_USER:-}"; APACHE_GROUP="${APACHE_RUN_GROUP:-}"
fi

# For cron/worker roles we typically don't have a shared /data volume on Railway.
# Skip /data hydration/sync to avoid relying on a non-existent volume.
case "${DOCKER_MAUTIC_ROLE:-}" in
  mautic_cron|mautic_worker)
    echo "[railway] role ${DOCKER_MAUTIC_ROLE}: skipping /data persistence hydration"

    # Ensure key runtime directories exist and are writable.
    # On Railway, worker/cron containers are often ephemeral and do not mount /data.
    # Without this, Monolog can crash with "Failed to open stream: Permission denied".
    mkdir -p "${LOGS_DIR}" "${CONFIG_DIR}" /tmp || true

    # Best-effort permissions for CLI + messenger consumers.
    # Worker processes usually run as www-data.
    chown -R "${MAUTIC_WWW_USER:-www-data}:${MAUTIC_WWW_GROUP:-www-data}" "${LOGS_DIR}" "${CONFIG_DIR}" /tmp 2>/dev/null || true
    chmod -R a+rwX "${LOGS_DIR}" "${CONFIG_DIR}" /tmp 2>/dev/null || true

    # Also align temp env vars used by some libraries.
    export TMPDIR="${TMPDIR:-/tmp}"
    export TMP="${TMP:-/tmp}"
    export TEMP="${TEMP:-/tmp}"

    # Chain to upstream entrypoint.
    exec /entrypoint.sh "$@"
    ;;
esac

# Prepare persistent dirs
mkdir -p "${PERSIST_CONFIG}" "${PERSIST_LOGS}" "${PERSIST_MEDIA}" "${PERSIST_THEMES}" /data/tmp

# Ensure Apache runtime user can write to persisted volume paths.
if [ -n "${APACHE_USER:-}" ]; then
  chown -R "${APACHE_USER}:${APACHE_GROUP:-${APACHE_USER}}" /data || true
fi
chmod -R a+rwX /data || true

# Sync helper using rsync.
# We intentionally do NOT use --delete for config/logs by default (safer),
# but we DO use --delete for media/themes so deletions persist.
#
# Usage:
# - seed_or_hydrate_dir <container_dir> <persist_dir> [delete_mode]
# - sync_back_dir <container_dir> <persist_dir> [delete_mode]
# where delete_mode is "delete" or "nodelete".
seed_or_hydrate_dir() {
  CONTAINER_DIR="$1"; PERSIST_DIR="$2"; DELETE_MODE="${3:-nodelete}"
  mkdir -p "$CONTAINER_DIR" "$PERSIST_DIR"

  # If persist dir is empty, seed it from the image (container -> persist).
  if [ -z "$(ls -A "$PERSIST_DIR" 2>/dev/null || true)" ]; then
    if [ "$DELETE_MODE" = "delete" ]; then
      rsync -a --delete "$CONTAINER_DIR"/ "$PERSIST_DIR"/ >/dev/null 2>&1 || true
    else
      rsync -a "$CONTAINER_DIR"/ "$PERSIST_DIR"/ >/dev/null 2>&1 || true
    fi
  else
    # Hydrate container dir at startup (persist -> container).
    if [ "$DELETE_MODE" = "delete" ]; then
      rsync -a --delete "$PERSIST_DIR"/ "$CONTAINER_DIR"/ >/dev/null 2>&1 || true
    else
      rsync -a "$PERSIST_DIR"/ "$CONTAINER_DIR"/ >/dev/null 2>&1 || true
    fi
  fi
}

sync_back_dir() {
  CONTAINER_DIR="$1"; PERSIST_DIR="$2"; DELETE_MODE="${3:-nodelete}"
  mkdir -p "$CONTAINER_DIR" "$PERSIST_DIR"
  if [ "$DELETE_MODE" = "delete" ]; then
    rsync -a --delete "$CONTAINER_DIR"/ "$PERSIST_DIR"/ >/dev/null 2>&1 || true
  else
    rsync -a "$CONTAINER_DIR"/ "$PERSIST_DIR"/ >/dev/null 2>&1 || true
  fi
}

# Ensure Mautic dirs exist as real directories (no symlinks)
mkdir -p "${CONFIG_DIR}" "${LOGS_DIR}" "${MEDIA_DIR}" "${THEMES_DIR}"

# Important: remove symlinks if a previous version created them
if [ -L "${CONFIG_DIR}" ]; then rm -f "${CONFIG_DIR}"; mkdir -p "${CONFIG_DIR}"; fi
if [ -L "${LOGS_DIR}" ]; then rm -f "${LOGS_DIR}"; mkdir -p "${LOGS_DIR}"; fi
if [ -L "${MEDIA_DIR}" ]; then rm -f "${MEDIA_DIR}"; mkdir -p "${MEDIA_DIR}"; fi
if [ -L "${THEMES_DIR}" ]; then rm -f "${THEMES_DIR}"; mkdir -p "${THEMES_DIR}"; fi

# Sync the directories between /data and container paths
# - config/logs: no deletes (safer)
# - media/themes: mirror with deletes (so deletions persist)
seed_or_hydrate_dir "${CONFIG_DIR}" "${PERSIST_CONFIG}" nodelete
seed_or_hydrate_dir "${LOGS_DIR}" "${PERSIST_LOGS}" nodelete
seed_or_hydrate_dir "${MEDIA_DIR}" "${PERSIST_MEDIA}" delete
seed_or_hydrate_dir "${THEMES_DIR}" "${PERSIST_THEMES}" delete

# Final permissions (best-effort)
if [ -n "${APACHE_USER:-}" ]; then
  chown -R "${APACHE_USER}:${APACHE_GROUP:-${APACHE_USER}}" "${CONFIG_DIR}" "${LOGS_DIR}" "${MEDIA_DIR}" "${THEMES_DIR}" || true
fi
chmod -R a+rwX "${CONFIG_DIR}" "${LOGS_DIR}" "${MEDIA_DIR}" "${THEMES_DIR}" || true

# Minimal startup info (keep this short; logs are noisy on Railway)
echo "[railway] apache user/group: ${APACHE_USER:-?}:${APACHE_GROUP:-?}"
# Background sync loop (container -> /data) for reliability
# Configurable via env vars:
# - SYNC_INTERVAL_SECONDS (default 30)
# - SYNC_ENABLED (default 1)
SYNC_ENABLED="${SYNC_ENABLED:-1}"
SYNC_INTERVAL_SECONDS="${SYNC_INTERVAL_SECONDS:-30}"

echo "[railway] persistence dirs: config/logs/media/themes -> /data (interval=${SYNC_INTERVAL_SECONDS}s)"

if [ "${SYNC_ENABLED}" != "0" ]; then
  (
    while true; do
      sync_back_dir "${CONFIG_DIR}" "${PERSIST_CONFIG}" nodelete
      sync_back_dir "${LOGS_DIR}" "${PERSIST_LOGS}" nodelete
      sync_back_dir "${MEDIA_DIR}" "${PERSIST_MEDIA}" delete
      sync_back_dir "${THEMES_DIR}" "${PERSIST_THEMES}" delete
      sleep "${SYNC_INTERVAL_SECONDS}" || sleep 30
    done
  ) >/dev/null 2>&1 &
  echo "[railway] background sync enabled (interval=${SYNC_INTERVAL_SECONDS}s)"
else
  echo "[railway] background sync disabled"
fi

# Keep group-writable defaults for created files
umask 0002

# If the upstream entrypoint exists, run it. This enables DOCKER_MAUTIC_ROLE behavior from mautic/mautic.
if [ -x /entrypoint.sh ]; then
  exec /entrypoint.sh "$@"
fi

# Fallback (shouldn't happen)
exec "$@"
