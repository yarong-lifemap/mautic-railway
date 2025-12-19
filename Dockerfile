FROM mautic/mautic:5-apache

# Redis Messenger transport requires either the phpredis extension (preferred) or Predis.
# We install the Debian package for PHP 8.2 on bookworm.
RUN apt-get update \
 && apt-get install -y --no-install-recommends php8.2-redis \
 && rm -rf /var/lib/apt/lists/*

# Ensure required Apache modules/configs are available and MPM is consistent for mod_php
# Some base images enable multiple MPMs via conf/modules; make it deterministic.
RUN a2dismod mpm_event mpm_worker mpm_prefork || true \
 && a2enmod mpm_prefork \
 && a2dismod mpm_event mpm_worker || true \
 && a2enconf servername || true

# Railway/Apache/PHP config: allow /data and /tmp, and move temp/session dirs onto /data/tmp
# Copy a static config file to avoid any shell/escaping surprises in build environments.
COPY zz-railway.conf /etc/apache2/conf-available/zz-railway.conf

# Also copy it to a safe location so the entrypoint can restore it if something corrupts conf-available at runtime.
COPY zz-railway.conf /zz-railway.conf

# Enable config; avoid failing the image build if Apache reload fails inside the build environment.
RUN a2enconf zz-railway || true

# Keep a small Railway entrypoint for /data persistence hydration, then chain to upstream /entrypoint.sh
COPY docker-entrypoint-railway.sh /usr/local/bin/docker-entrypoint-railway.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-railway.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-railway.sh"]
