<?php
/**
 * Standalone test: verify that get_woo_context_standard_reply() returns a
 * hard-coded standard message for each high-risk hallucination scenario,
 * WITHOUT requiring WP bootstrap (so it's safe and fast to run).
 *
 *  1. Not logged in, asked for orders         -> must return 'require_login'
 *  2. Logged in but no orders                 -> must return 'orders_empty'
 *  3. testcustomer tries to access order #2739 (belongs to buyer007) -> 'only_view_own'
 *  4. Unknown / normal context                -> must return empty (let AI handle it)
 */

define('ABSPATH', '/tmp/fake-wp/'); // fake to silence "ABSPATH" guard only
define('WP_DEBUG', false);

$src = __DIR__ . '/wp-content/plugins/wp-ai-customer-service/includes/class-i18n.php';
if (!file_exists($src)) {
    fwrite(STDERR, "[FAIL] class-i18n.php not found at: $src\n");
    exit(1);
}

// Strip the "if (!defined('ABSPATH')) exit;" guard so we can require on CLI.
$raw = file_get_contents($src);
$raw = preg_replace('/^\s*if\s*\(\s*\!defined\s*\(\s*[\'"]ABSPATH[\'"]\s*\)\s*\)\s*exit\s*;\s*$/m', '/* guard stripped for testing */', $raw, 1);
// Any "defined('ABSPATH') ||" one-liner guards at top of files:
$raw = preg_replace('/^\s*defined\s*\(\s*[\'"]ABSPATH[\'"]\s*\)\s*\|\|\s*exit\s*;\s*$/m', '/* guard2 stripped */', $raw, 1);

eval('?>' . $raw);

if (!class_exists('WP_AI_CS_i18n')) {
    fwrite(STDERR, "[FAIL] WP_AI_CS_i18n class did not load.\n");
    exit(1);
}

// ---- Mock the logger / woo integrations if any constructor tries to access them.
// The i18n class constructor calls get_option() in some branches, so we must
// provide stubs so it doesn't fatally die on CLI.
if (!function_exists('get_option')) {
    function get_option($k, $def = null) { return $def; }
}
if (!function_exists('sanitize_textarea_field')) {
    function sanitize_textarea_field($v) { return is_string($v) ? $v : ''; }
}

try {
    $i18n = new WP_AI_CS_i18n();
} catch (Throwable $e) {
    fwrite(STDERR, "[FAIL] Cannot construct i18n: " . $e->getMessage() . "\n");
    exit(1);
}

// ---- Build realistic RAG strings (what class-woo-integration returns) ----
$scenarios = array(
    'require_login' => array(
        'lang' => 'zh',
        'ctx'  => "[Current User] Customer is NOT logged in. You can only view your own orders. Please login to my-account to view orders.",
        'want' => true, // non-empty expected
    ),
    'require_login_en' => array(
        'lang' => 'en',
        'ctx'  => "[Current User] Customer is NOT logged in. You can only view your own orders. Please login to my-account to view orders.",
        'want' => true,
    ),
    'require_login_ru' => array(
        'lang' => 'ru',
        'ctx'  => "[Current User] Клиент НЕ вошёл в систему. Вы можете просматривать только свои собственные заказы. Пожалуйста, войдите в личный кабинет, чтобы просмотреть заказы.",
        'want' => true,
    ),
    'orders_empty' => array(
        'lang' => 'zh',
        'ctx'  => "[Current User] Logged in customer. User ID: 99, name: testcustomer. [Order Query] Search result: no orders found in database for this customer.",
        'want' => true,
    ),
    'orders_empty_ja' => array(
        'lang' => 'ja',
        'ctx'  => "[Current User] ログイン済み顧客。[Order Query] 検索結果：この顧客の注文はデータベースに見つかりませんでした。",
        'want' => true,
    ),
    'only_view_own' => array(
        'lang' => 'zh',
        'ctx'  => "[Order Query] Order #2739 found. Order owner user ID: 100 (buyer007). [Current User] Logged in customer. User ID: 99, name: testcustomer. Order #2739 does NOT belong to current customer ID 99. You can only view your own orders. Access denied.",
        'want' => true,
    ),
    'only_view_own_es' => array(
        'lang' => 'es',
        'ctx'  => "[Order Query] Pedido #2739 encontrado. Propietario: user ID 100 (buyer007). [Current User] Cliente ID 99 (testcustomer). No puede ver este pedido (no pertenece al cliente). You can only view your own orders. Acceso denegado.",
        'want' => true,
    ),
    'only_view_own_ko' => array(
        'lang' => 'ko',
        'ctx'  => "[Order Query] Order #2739. Owner: 100 (buyer007). Current user: 99 (testcustomer). 다른 사용자의 주문이므로 접근할 수 없습니다. You can only view your own orders.",
        'want' => true,
    ),
    'only_view_own_de' => array(
        'lang' => 'de',
        'ctx'  => "[Order Query] Bestellung #2739 gehört zu User 100 (buyer007). Aktueller Kunde: 99 (testcustomer). Dies ist nicht Ihre Bestellung. You can only view your own orders. Zugriff verweigert.",
        'want' => true,
    ),
    'only_view_own_fr' => array(
        'lang' => 'fr',
        'ctx'  => "[Order Query] Commande #2739 : propriétaire user 100 (buyer007). Client actuel 99 (testcustomer). Cette commande ne vous appartient pas. You can only view your own orders. Accès refusé.",
        'want' => true,
    ),
    // ---- negative: normal contexts should NOT trigger hard reply ----
    'normal_no_order_mention' => array(
        'lang' => 'zh',
        'ctx'  => "[Product Search] Query: red shirt. Matches: (0 results). No product found matching 'red shirt'.",
        'want' => false,
    ),
    'normal_own_order' => array(
        'lang' => 'zh',
        'ctx'  => "[Current User] User ID: 99. [Order Query] Order #2740 found, belongs to user 99. Status: Processing. Total: ￥299.",
        'want' => false, // let AI summarize real details
    ),
);

$fail = 0;
$pass = 0;
foreach ($scenarios as $name => $s) {
    try {
        $reply = $i18n->get_woo_context_standard_reply($s['ctx'], $s['lang']);
    } catch (Throwable $e) {
        echo "[$name] EXCEPTION: " . $e->getMessage() . "\n";
        $fail++;
        continue;
    }
    $hasReply = !empty(trim($reply));
    $ok = ($hasReply === $s['want']);
    if ($ok) {
        $pass++;
        echo "[$name] PASS " . ($hasReply ? "(hard-reply=" . mb_substr($reply, 0, 40, 'UTF-8') . "...)" : "(AI handles, as expected)") . "\n";
    } else {
        $fail++;
        if ($s['want']) {
            echo "[$name] FAIL: expected a standard hard reply, got EMPTY.\n       ctx = " . mb_substr($s['ctx'], 0, 120, 'UTF-8') . "\n";
        } else {
            echo "[$name] FAIL: expected EMPTY (let AI handle), got:\n       " . mb_substr($reply, 0, 160, 'UTF-8') . "\n";
        }
    }
}

echo "\n--- Summary ---\nPASS=$pass FAIL=$fail\n";
exit($fail > 0 ? 1 : 0);
