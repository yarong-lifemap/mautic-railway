<?php
// Simple runtime write check for Railway/Mautic.
// Visit /__fscheck to see whether PHP (under Apache user) can write to the config directory.

header('Content-Type: text/plain; charset=utf-8');

$root = '/var/www/html';
$configDir = $root . '/config';
$target = $configDir . '/.php-write-test';

echo "whoami (posix_geteuid): ";
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
