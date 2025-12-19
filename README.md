# Mautic on Railway (3-service architecture)

This repo builds a `mautic/mautic:5-apache`-based image with a small Railway-focused entrypoint wrapper.

## Architecture overview

This setup is designed for Railway using **MySQL + Redis plugins** and **three Mautic services** (all built from the same Docker image, differentiated by `DOCKER_MAUTIC_ROLE`).

### Railway topology (diagram)

```mermaid
flowchart TB
  %% Plugins
  mysql[(MySQL
  plugin)]
  redis[(Redis
  plugin)]

  %% Project services
  subgraph mautic[Mautic (Railway project)]
    web[mautic-railway-web
    role: mautic_web]
    worker[mautic-railway-worker
    role: mautic_worker]
    cron[mautic-railway-cron
    role: mautic_cron]
  end

  %% Volumes
  mysqlv[(mysql-volume)]
  redisv[(redis-volume)]
  datav[(mautic-railway-volume
  /data)]

  %% Storage attachments
  mysql --- mysqlv
  redis --- redisv
  web --- datav

  %% App dependencies
  web --> mysql
  worker --> mysql
  cron --> mysql

  web --> redis
  worker --> redis
  cron --> redis

  %% Internal coordination
  cron -. queues work .-> worker
```

### What each box does

- **MySQL plugin**: primary application database (contacts, campaigns, config, etc.).
- **Redis plugin**: queue/cache backend (used by Symfony Messenger transports when enabled; can also be used for caching depending on your Mautic config).
- **`mautic-railway-web`**: Apache + PHP serving the UI and public endpoints.
- **`mautic-railway-worker`**: long-running `messenger:consume` process to execute queued jobs (email/hit processing, etc.).
- **`mautic-railway-cron`**: scheduled CLI tasks that enqueue/trigger work (segments, campaigns, broadcasts, etc.).
- **`mautic-railway-volume` mounted at `/data` (web only)**: persistent storage used by the entrypoint for safe temp/session dirs and (optionally) persistence/hydration.

On Railway, run **three services** from the same image, differentiated by `DOCKER_MAUTIC_ROLE`:

1) **Web** (`DOCKER_MAUTIC_ROLE=mautic_web`)
   - Apache + PHP serving the Mautic UI.
   - In this repo, the web role also supports optional persistence hydration/sync to `/data`.

2) **Cron** (`DOCKER_MAUTIC_ROLE=mautic_cron`)
   - Runs Mautic scheduled CLI tasks (segments rebuild, campaign triggers, etc.).
   - Does **not** persist `/data` by default in this entrypoint (Railway cron containers are often ephemeral).

3) **Worker** (`DOCKER_MAUTIC_ROLE=mautic_worker`)
   - Runs Symfony Messenger consumers.
   - Required when Messenger is enabled (Mautic 5 commonly uses async queues for email + hit processing).

### Why both cron and worker?
With Messenger enabled, cron often **queues work** and the worker **executes** it.

In our configuration (see `debug:config framework messenger` output), emails are routed to the Messenger transport named `email`:

- `Symfony\Component\Mailer\Messenger\SendEmailMessage -> sender: email`

So: **emails will not be sent unless the worker is consuming the `email` receiver**.

## Logging / “what is cron doing?”

### Entrypoint environment snapshot (debug)
At container startup, `docker-entrypoint-railway.sh` writes a snapshot of `printenv` to:

- `/etc/environment`

This helps debug “it works in SSH but fails during startup” issues by showing exactly which env vars were present at boot time.

Notes:
- This file contains **secrets** (DB password, API keys, etc.). Treat it as sensitive.
- It is written with restrictive permissions via `umask 0077`.

### Railway service logs
- **Cron behavior** is visible in the **cron service** logs (stdout/stderr of CLI commands).
- **Worker behavior** is visible in the **worker service** logs (messenger consume output).

### Mautic application logs (inside container)
Mautic 5 logs are often PHP files (not `.log`). Example:
- `/var/www/html/var/logs/prod-YYYY-MM-DD.php`

Useful commands:

```sh
ls -lah /var/www/html/var/logs
# show last 200 lines of all prod logs
find /var/www/html/var/logs -maxdepth 1 -type f -name 'prod-*.php' -print -exec tail -n 200 {} \;
```

## Required variables (all services)

These should be set on **web + cron + worker** (or using Railway “shared variables”).

### Core
- `MAUTIC_SITE_URL` – public base URL for the instance
- `MAUTIC_SECRET_KEY` – shared application secret (must be consistent across all services)
- `MAUTIC_REMEMBER_ME_KEY` – used for remember-me cookies (must be consistent across all services)

If `MAUTIC_REMEMBER_ME_KEY` is missing you may see errors like:
- `Parameter "mautic.secret_key" found when resolving env var "MAUTIC_REMEMBER_ME_KEY" must be scalar, "null" given.`

If you don’t already have a value in `config/local.php`, generate one:

```sh
php -r 'echo bin2hex(random_bytes(32)), PHP_EOL;'
```

### Database
- `MAUTIC_DB_HOST` (Railway plugin commonly: `mysql.railway.internal`)
- `MAUTIC_DB_PORT` (typically `3306`)
- `MAUTIC_DB_DATABASE`
- `MAUTIC_DB_USER`
- `MAUTIC_DB_PASSWORD`

### Messenger / Queue (when enabled)
You configured Messenger transports via env vars:
- `MAUTIC_MESSENGER_DSN_EMAIL`
- `MAUTIC_MESSENGER_DSN_HIT`
- `MAUTIC_MESSENGER_DSN_FAILED`

Also:
- `REDIS_URL` (if using Redis)

Important:
- These DSNs define **where the queues live**.
- They do **not** configure the SMTP/SES mail transport.

### Optional / platform vars
- `PORT` – assigned by Railway
- `MAUTIC_TRUSTED_PROXIES` – if behind Railway proxy/load balancer
- `PHP_INI_DATE_TIMEZONE`

### S3 variables
You had variables like:
- `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET`, `S3_ENDPOINT`, `S3_REGION`

These are only needed if you explicitly configured Mautic to store assets/media in S3-compatible storage.
If you are not using S3 storage, they can be omitted.

## Service start commands (recommended)

Exact commands can vary, but these are typical.

### Cron
Run the Mautic cron tasks you need, with verbosity:

```sh
php /var/www/html/bin/console mautic:segments:update -vvv
php /var/www/html/bin/console mautic:campaigns:trigger -vvv
php /var/www/html/bin/console mautic:emails:send -vvv
php /var/www/html/bin/console mautic:broadcasts:send -vvv
```

If you want to validate DB connectivity in logs (useful for debugging startup races):

```sh
php /var/www/html/bin/console doctrine:query:sql "SELECT 1" -vvv
```

### Worker
Consume the transports your routing uses. With our config, you usually want **both** `email` and `hit`:

```sh
php /var/www/html/bin/console messenger:consume email hit -vv --time-limit=0 --memory-limit=256M
```

To debug interactively:

```sh
php /var/www/html/bin/console messenger:consume email -vv --time-limit=120
```

## SES (email sending) configuration & troubleshooting

### Key learning
We observed log entries like:

> `Connection could not be established with host "localhost:25" (Connection refused)`

This indicates Symfony Mailer was configured to use **localhost SMTP**, not SES.

### Configure SES SMTP
In the Mautic UI:
- Settings → Email Settings
- Transport: SMTP
- Host: `email-smtp.<region>.amazonaws.com`
- Port: `587`
- Encryption: TLS
- Username/Password: SES SMTP credentials

After changing email settings:
- **Restart/redeploy the worker service** (recommended) because it’s a long-running process and may hold old config.

### SES common failure modes
- SES sandbox mode (recipient restrictions)
- sender identity not verified
- wrong region endpoint
- wrong SMTP credentials

### Where to look when mail doesn’t go out
1) **Worker logs** (Railway) and Mautic log files:
   - `/var/www/html/var/logs/prod-YYYY-MM-DD.php`
2) Verify the worker is consuming the `email` receiver:

```sh
php /var/www/html/bin/console debug:config framework messenger | head -n 120
php /var/www/html/bin/console debug:container --tag=messenger.receiver
```

## Troubleshooting cookbook

### Check DB env vars are present (cron/worker)
```sh
printenv | grep -E "^(DOCKER_MAUTIC_ROLE|MAUTIC_DB_HOST|MAUTIC_DB_PORT|MAUTIC_DB_DATABASE|MAUTIC_DB_USER)="
```

### Check DB connectivity via Doctrine (best signal)
```sh
php /var/www/html/bin/console doctrine:query:sql "SELECT 1" -vvv
```

### Run segment update with verbose output
```sh
php /var/www/html/bin/console mautic:segments:update -vvv
```

## Repo notes

### Files
- `Dockerfile` – builds image and installs PHP redis extension
- `docker-entrypoint-railway.sh` – wrapper entrypoint: Apache guardrails + optional `/data` persistence (web role), and `local.php` bootstrap for cron/worker
- `zz-railway.conf` – Apache/PHP config (open_basedir, temp/session dirs on `/data/tmp`)
