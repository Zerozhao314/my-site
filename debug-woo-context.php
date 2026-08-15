<?php
/**
 * Load WordPress and directly call WP_AI_CS_Woo_Integration->get_context()
 * with real Woo user, to print the exact $context string (encoding & whitespace preserved).
 */

if (!defined('ABSPATH')) {
    $wpRoots = [
        __DIR__ . '/wp-load.php',
        __DIR__ . '/../../../../wp-load.php',
        dirname(__DIR__) . '/wp-load.php',
    ];
    foreach ($wpRoots as $wp) {
        if (file_exists($wp)) {
            require_once $wp;
            break;
        }
    }
}

if (!defined('ABSPATH')) {
    fwrite(STDERR, "ABSPATH not defined. Could not locate wp-load.php\n");
    exit(1);
}

$USERNAME = 'testcustomer';
$QUERY    = '我最近下的订单怎么样了？帮我查一下。';

$user = get_user_by('login', $USERNAME);
if (!$user) {
    fwrite(STDERR, "User '$USERNAME' not found.\n");
    exit(1);
}

// Fake login
wp_set_current_user($user->ID);
wp_set_auth_cookie($user->ID, false);

echo "User: $user->user_login (ID=$user->ID, role=" . implode(',', $user->roles) . ")\n";
echo "Query: $QUERY\n";
echo "---\n";

// Find and instantiate Woo integration
$wooSrc = __DIR__ . '/wp-content/plugins/wp-ai-customer-service/includes/class-woo-integration.php';
if (!file_exists($wooSrc)) {
    // Try relative to plugin dir
    $wooSrc = dirname(__DIR__, 4) . '/plugins/wp-ai-customer-service/includes/class-woo-integration.php';
}
if (!file_exists($wooSrc)) {
    fwrite(STDERR, "Cannot locate class-woo-integration.php\n");
    exit(1);
}
require_once $wooSrc;

$cls = 'WP_AI_CS_Woo_Integration';
if (!class_exists($cls)) {
    fwrite(STDERR, "Class $cls missing.\n");
    exit(1);
}

$woo = new $cls();
$ctx = $woo->get_context($QUERY);

echo "LENGTH=" . strlen($ctx) . " (bytes)\n";
echo "MD5=" . md5($ctx) . "\n";
echo "--- CONTEXT START ---\n";
echo $ctx . "\n";
echo "--- CONTEXT END ---\n\n";

// Now run standard-reply matcher
$i18nSrc = __DIR__ . '/wp-content/plugins/wp-ai-customer-service/includes/class-i18n.php';
require_once $i18nSrc;
$i18n = new WP_AI_CS_i18n();
foreach (['zh', 'en', 'ru', 'ja', 'ko', 'es', 'fr', 'de'] as $l) {
    $r = $i18n->get_woo_context_standard_reply($ctx, $l);
    echo "[$l] " . ($r ? 'MATCH=' . mb_substr($r, 0, 50, 'UTF-8') : 'NO_MATCH') . "\n";
}
