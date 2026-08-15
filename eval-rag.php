<?php
$user = get_user_by("login", "testcustomer");
wp_set_current_user($user->ID);
echo "User: {$user->user_login} (ID={$user->ID})\n";
require_once WP_PLUGIN_DIR . "/wp-ai-customer-service/includes/class-woo-integration.php";
require_once WP_PLUGIN_DIR . "/wp-ai-customer-service/includes/class-chat-logger.php";
require_once WP_PLUGIN_DIR . "/wp-ai-customer-service/includes/class-i18n.php";
$logger = new WP_AI_CS_Logger();
$woo = new WP_AI_CS_Woo_Integration($logger);
$ctx = $woo->get_context("我最近下的订单怎么样了？帮我查一下。");
echo "LEN=".strlen($ctx)."\n";
echo "MD5=".md5($ctx)."\n";
echo "---CTX START---\n".$ctx."\n---CTX END---\n";
$i18n = new WP_AI_CS_i18n();
foreach (["zh","en","ru","ja","ko","es","fr","de"] as $l) {
  $r = $i18n->get_woo_context_standard_reply($ctx, $l);
  echo "[$l] ".($r ? "MATCH=".mb_substr($r,0,40,"UTF-8") : "NO_MATCH")."\n";
}
