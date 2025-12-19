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

# --- Mautic/Railway filesystem diagnostics (for local.php write failures)
CONFIG_DIR="${MAUTIC_ROOT}/config"
CONFIG_FILE="${CONFIG_DIR}/local.php"

echo "[railway][fs] whoami: $(whoami 2>/dev/null || true)"
echo "[railway][fs] id: $(id 2>/dev/null || true)"

# Show relevant paths, mounts, and filesystem type
( command -v ls >/dev/null 2>&1 && ls -ld "${MAUTIC_ROOT}" || true )
( command -v mount >/dev/null 2>&1 && mount | grep -E " on (/var/www/html|/data) " || true )
( command -v df >/dev/null 2>&1 && df -hT "${MAUTIC_ROOT}" /data 2>/dev/null || df -h "${MAUTIC_ROOT}" /data 2>/dev/null || true )

# Check common "read-only filesystem" conditions
( command -v touch >/dev/null 2>&1 && touch "${MAUTIC_ROOT}/.fs-write-test" 2>/dev/null && rm -f "${MAUTIC_ROOT}/.fs-write-test" && echo "[railway][fs] ${MAUTIC_ROOT} write test: OK" ) \
  || echo "[railway][fs] ${MAUTIC_ROOT} write test: FAILED (may be read-only or permission denied)"

# Extended permission/ACL diagnostics when available
if command -v stat >/dev/null 2>&1; then
  echo "[railway][fs] stat ${MAUTIC_ROOT}: $(stat -c '%U:%G %a %n' "${MAUTIC_ROOT}" 2>/dev/null || true)"
  if [ -e "${CONFIG_DIR}" ]; then
    echo "[railway][fs] stat ${CONFIG_DIR}: $(stat -c '%U:%G %a %n' "${CONFIG_DIR}" 2>/dev/null || true)"
  fi
fi
if command -v getfacl >/dev/null 2>&1; then
  echo "[railway][fs] getfacl ${MAUTIC_ROOT}"
  getfacl -p "${MAUTIC_ROOT}" 2>/dev/null || true
  if [ -e "${CONFIG_DIR}" ]; then
    echo "[railway][fs] getfacl ${CONFIG_DIR}"
    getfacl -p "${CONFIG_DIR}" 2>/dev/null || true
  fi
fi

# SELinux/AppArmor quick indicators (non-fatal)
if command -v sestatus >/dev/null 2>&1; then
  sestatus 2>/dev/null || true
fi
if [ -d /sys/kernel/security/apparmor ]; then
  echo "[railway][fs] AppArmor detected (details may require host privileges)"
fi

# Print current state before we modify anything
if [ -e "${CONFIG_FILE}" ]; then
  echo "[railway][fs] config file exists: ${CONFIG_FILE}"
  ls -l "${CONFIG_FILE}" || true
else
  echo "[railway][fs] config file does NOT exist yet: ${CONFIG_FILE}"
fi

if [ -d "${CONFIG_DIR}" ]; then
  echo "[railway][fs] config dir details (before symlink changes): ${CONFIG_DIR}"
  ls -ld "${CONFIG_DIR}" || true
  # Try to create a throwaway file to validate writability (non-fatal)
  ( umask 0002; echo "test" > "${CONFIG_DIR}/.write-test" && rm -f "${CONFIG_DIR}/.write-test" && echo "[railway][fs] write test: OK" ) 2>/dev/null \
    || echo "[railway][fs] write test: FAILED (dir not writable as current user)"
else
  echo "[railway][fs] config dir does NOT exist yet: ${CONFIG_DIR}"
fi

# Detect which user Apache will run as (and thus PHP/mod_php)
APACHE_USER=""
APACHE_GROUP=""
if [ -f /etc/apache2/envvars ]; then
  # shellcheck disable=SC1091
  . /etc/apache2/envvars || true
  APACHE_USER="${APACHE_RUN_USER:-}"; APACHE_GROUP="${APACHE_RUN_GROUP:-}"
fi
if [ -n "${APACHE_USER}" ]; then
  echo "[railway][fs] apache run user/group from envvars: ${APACHE_USER}:${APACHE_GROUP}"
  id "${APACHE_USER}" 2>/dev/null || true
fi

# If php-fpm exists, try to show its configured user/group too (not expected in apache image, but useful)
if command -v php-fpm >/dev/null 2>&1; then
  echo "[railway][fs] php-fpm detected: $(php-fpm -v 2>/dev/null | head -n 1 || true)"
  (php-fpm -tt 2>/dev/null | grep -E "^(user|group)\s*=" || true)
fi

mkdir -p /data/config /data/logs /data/media /data/tmp

# Ensure Apache runtime user can write to persisted volume paths.
# NOTE: chmod alone may not be enough if user needs directory ownership for created files.
if [ -n "${APACHE_USER:-}" ]; then
  chown -R "${APACHE_USER}:${APACHE_GROUP:-${APACHE_USER}}" /data || true
fi
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

# Create a docroot-visible runtime write test (avoids routing/redirects)
cat > "${MAUTIC_ROOT}/docroot/__fscheck.php" <<'PHP'
<?php
header('Content-Type: text/plain; charset=utf-8');
$root = '/var/www/html';
$configDir = $root . '/config';
$target = $configDir . '/.php-write-test';

echo "uid: ";
if (function_exists('posix_geteuid')) {
    $uid = posix_geteuid();
    echo $uid;
    if (function_exists('posix_getpwuid')) {
        $pw = posix_getpwuid($uid);
        echo " (" . ($pw['name'] ?? '?') . ")";
    }
}
echo "\n";

echo "configDir: $configDir\n";
echo "is_dir: " . (is_dir($configDir) ? 'yes' : 'no') . "\n";
echo "is_writable(dir): " . (is_writable($configDir) ? 'yes' : 'no') . "\n";
echo "realpath(configDir): " . (realpath($configDir) ?: '') . "\n";

$err = null;
set_error_handler(function($errno, $errstr) use (&$err) {
    $err = $errstr;
    return false;
});

@unlink($target);
$ok = @file_put_contents($target, "ok " . date(DATE_ATOM) . "\n");
restore_error_handler();

if ($ok === false) {
    echo "write_test: FAILED\n";
    if ($err) {
        echo "php_error: $err\n";
    }
} else {
    echo "write_test: OK ($ok bytes)\n";
    @unlink($target);
}
PHP
chmod 0644 "${MAUTIC_ROOT}/docroot/__fscheck.php" || true

# Post-symlink diagnostics: confirm config now points to /data/config and is writable
echo "[railway][fs] post-symlink config path resolution"
ls -ld "${MAUTIC_ROOT}/config" || true
ls -ld /data/config || true
( command -v readlink >/dev/null 2>&1 && echo "[railway][fs] readlink -f ${MAUTIC_ROOT}/config: $(readlink -f \"${MAUTIC_ROOT}/config\" 2>/dev/null || true)" ) || true
( umask 0002; echo "test" > "${MAUTIC_ROOT}/config/.write-test-post" && rm -f "${MAUTIC_ROOT}/config/.write-test-post" && echo "[railway][fs] post-symlink write test: OK" ) 2>/dev/null \
  || echo "[railway][fs] post-symlink write test: FAILED"

# Keep group-writable defaults for created files
umask 0002

exec "$@"
