FROM mautic/mautic:5-apache

# Ensure required Apache modules/configs are available and MPM is consistent for mod_php
RUN a2dismod mpm_event mpm_worker || true \
 && a2enmod mpm_prefork \
 && a2enconf servername || true

# Railway/Apache/PHP config: allow /data and /tmp, and move temp/session dirs onto /data/tmp
# Copy a static config file to avoid any shell/escaping surprises in build environments.
COPY zz-railway.conf /etc/apache2/conf-available/zz-railway.conf

# Enable config; avoid failing the image build if Apache reload fails inside the build environment.
RUN a2enconf zz-railway || true

# Entrypoint that prepares persistent dirs + symlinks after the Railway volume is mounted
COPY docker-entrypoint-railway.sh /usr/local/bin/docker-entrypoint-railway.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-railway.sh

# Debug aid: print the enabled Apache config during image build logs (helps when no shell access).
RUN echo '--- /etc/apache2/conf-enabled/zz-railway.conf (if present) ---' \
 && (cat -n /etc/apache2/conf-enabled/zz-railway.conf || true) \
 && echo '--- /etc/apache2/conf-available/zz-railway.conf ---' \
 && cat -n /etc/apache2/conf-available/zz-railway.conf \
 && echo '--- ls -l /etc/apache2/conf-enabled/zz-railway.conf /etc/apache2/conf-available/zz-railway.conf ---' \
 && (ls -l /etc/apache2/conf-enabled/zz-railway.conf /etc/apache2/conf-available/zz-railway.conf || true)

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-railway.sh"]
CMD ["apache2-foreground"]
