FROM mautic/mautic:5-apache

# Tools for Railway diagnostics + optional S3 FUSE testing
# - rclone: supports S3 and can mount via FUSE
# - fuse3: provides /bin/fusermount3 and libraries
# NOTE: Whether FUSE mounting works still depends on the Railway runtime (/dev/fuse + permissions).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates fuse3 rclone \
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

# Entrypoint that prepares persistent dirs + symlinks after the Railway volume is mounted
COPY docker-entrypoint-railway.sh /usr/local/bin/docker-entrypoint-railway.sh
COPY railway-fuse-test.sh /usr/local/bin/railway-fuse-test.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-railway.sh /usr/local/bin/railway-fuse-test.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-railway.sh"]
CMD ["apache2-foreground"]
