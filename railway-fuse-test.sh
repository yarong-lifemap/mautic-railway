#!/bin/sh
set -eu

# Expected env vars provided by Railway bucket integration
: "${S3_ENDPOINT:?S3_ENDPOINT is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_ACCESS_KEY_ID:?S3_ACCESS_KEY_ID is required}"
: "${S3_SECRET_ACCESS_KEY:?S3_SECRET_ACCESS_KEY is required}"

MOUNT_DIR="${S3_MOUNT_DIR:-/data}"
REMOTE_NAME="${S3_RCLONE_REMOTE_NAME:-railway}"

LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"
VFS_CACHE_MODE="${RCLONE_VFS_CACHE_MODE:-writes}"
DIR_CACHE_TIME="${RCLONE_DIR_CACHE_TIME:-10s}"
ALLOW_OTHER="${RCLONE_ALLOW_OTHER:-1}"

echo "[railway-fuse-test] starting"
echo "[railway-fuse-test] endpoint=${S3_ENDPOINT} bucket=${S3_BUCKET} mount_dir=${MOUNT_DIR}"

echo "[railway-fuse-test] kernel=$(uname -a || true)"
echo "[railway-fuse-test] user=$(id || true)"

if [ -e /dev/fuse ]; then
  echo "[railway-fuse-test] /dev/fuse present"
  ls -l /dev/fuse || true
else
  echo "[railway-fuse-test] /dev/fuse NOT present"
fi

grep fuse /proc/filesystems >/dev/null 2>&1 && echo "[railway-fuse-test] fuse in /proc/filesystems" || echo "[railway-fuse-test] fuse NOT in /proc/filesystems"

mkdir -p /tmp/rclone "${MOUNT_DIR}"

RCLONE_CONFIG=/tmp/rclone/rclone.conf
# Create config without leaking secrets in logs
{
  echo "[${REMOTE_NAME}]"
  echo "type = s3"
  echo "provider = Other"
  echo "env_auth = false"
  echo "access_key_id = ${S3_ACCESS_KEY_ID}"
  echo "secret_access_key = ${S3_SECRET_ACCESS_KEY}"
  echo "endpoint = ${S3_ENDPOINT}"
  echo "acl = private"
} > "${RCLONE_CONFIG}"
chmod 600 "${RCLONE_CONFIG}" || true

echo "[railway-fuse-test] rclone version: $(rclone version | head -n 1 || true)"

echo "[railway-fuse-test] testing S3 auth with list..."
# This should work even if FUSE is blocked.
rclone --config "${RCLONE_CONFIG}" lsd "${REMOTE_NAME}:${S3_BUCKET}" || true

echo "[railway-fuse-test] attempting FUSE mount (this will stay running if successful)"

ALLOW_OTHER_FLAG=""
if [ "${ALLOW_OTHER}" = "1" ]; then
  ALLOW_OTHER_FLAG="--allow-other"
fi

# Use low polling to reduce API usage; VFS cache helps with write semantics.
# If this fails, logs should clearly show whether it's /dev/fuse missing or permission denied.
exec rclone --config "${RCLONE_CONFIG}" mount "${REMOTE_NAME}:${S3_BUCKET}" "${MOUNT_DIR}" \
  ${ALLOW_OTHER_FLAG} \
  --vfs-cache-mode "${VFS_CACHE_MODE}" \
  --dir-cache-time "${DIR_CACHE_TIME}" \
  --poll-interval 0 \
  --log-level "${LOG_LEVEL}"
