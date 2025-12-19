FROM mautic/mautic:5-apache

# Ensure required Apache modules/configs are available and MPM is consistent for mod_php
RUN a2dismod mpm_event mpm_worker || true \
 && a2enmod mpm_prefork \
 && a2enconf servername || true

# Railway/Apache/PHP config: allow /data and /tmp, and move temp/session dirs onto /data/tmp
# Use a single, unambiguous printf so Apache always gets a properly closed <Directory> block.
RUN printf '%s\n' \
  '<Directory /var/www/html>' \
  'php_admin_value open_basedir "/var/www/html:/data:/tmp"' \
  'php_admin_value session.save_path "/data/tmp"' \
  'php_admin_value sys_temp_dir "/data/tmp"' \
  'php_admin_value upload_tmp_dir "/data/tmp"' \
  '</Directory>' \
  'ServerName localhost' \
  > /etc/apache2/conf-available/zz-railway.conf \
 && a2enconf zz-railway

# Entrypoint that prepares persistent dirs + symlinks after the Railway volume is mounted
COPY docker-entrypoint-railway.sh /usr/local/bin/docker-entrypoint-railway.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-railway.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-railway.sh"]
CMD ["apache2-foreground"]
