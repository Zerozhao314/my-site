#!/usr/bin/env bash
# =============================================================================
# DDEV WordPress 站点备份脚本
#
# 用途: 备份数据库 + 用户上传媒体 + DDEV 关键配置到本地 + Windows 异地
# 执行: cd ~/ddev-test && ./scripts/backup.sh
# 定时: crontab -e 添加: 0 2 * * * /home/zero/ddev-test/scripts/backup.sh >> ~/backups/ddev-test/backup.log 2>&1
#
# 产出文件 (~/backups/ddev-test/):
#   db-YYYYMMDD-HHMMSS.sql.gz          数据库 gzip 压缩
#   uploads-YYYYMMDD-HHMMSS.tar.gz     wp-content/uploads 全量打包
#   ddev-config-YYYYMMDD-HHMMSS.tar.gz  .ddev/config.yaml + .env 快照
#
# 异地副本: /mnt/d/backups/ddev-test/ (即 Windows D:\backups\ddev-test\)
# =============================================================================

set -euo pipefail

# ----------------------------- 配置区 -----------------------------
SITE_DIR="${HOME}/ddev-test"
SITE_NAME="ddev-test"

BACKUP_DIR="${HOME}/backups/${SITE_NAME}"
WIN_BACKUP_DIR="/mnt/d/backups/${SITE_NAME}"

RETENTION_DAYS=30

# ----------------------------- 初始化 -----------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_PREFIX="[backup ${TIMESTAMP}]"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

log()   { echo -e "${BLUE}${LOG_PREFIX}${NC} $*"; }
ok()    { echo -e "${GREEN}${LOG_PREFIX} OK${NC} $*"; }
warn()  { echo -e "${YELLOW}${LOG_PREFIX} !${NC} $*"; }
fail()  { echo -e "${RED}${LOG_PREFIX} X${NC} $*" >&2; exit 1; }

# ----------------------------- 前置检查 -----------------------------
log "启动 DDEV WordPress 备份"

[ -d "${SITE_DIR}" ] || fail "站点目录不存在: ${SITE_DIR}"
[ -d "${SITE_DIR}/.ddev" ] || fail "未找到 .ddev 目录,请在站点根执行"

mkdir -p "${BACKUP_DIR}"
mkdir -p "${WIN_BACKUP_DIR}" 2>/dev/null || warn "无法创建 Windows 异地目录 ${WIN_BACKUP_DIR} (D: 盘可能未挂载, 仅本地备份)"

cd "${SITE_DIR}"
if ! ddev describe 2>/dev/null | grep -q "OK"; then
    warn "DDEV 未运行, 正在启动..."
    ddev start >/dev/null 2>&1 || fail "DDEV 启动失败"
    sleep 3
fi

ok "环境检查通过"

# ----------------------------- 备份 1: 数据库 -----------------------------
DB_FILE="${BACKUP_DIR}/db-${TIMESTAMP}.sql.gz"
log "备份数据库 (ddev export-db -> gzip)..."

ddev export-db --gzip=false 2>/dev/null | gzip > "${DB_FILE}" || fail "数据库导出失败"

DB_SIZE=$(du -h "${DB_FILE}" | cut -f1)
ok "数据库完成: ${DB_FILE} (${DB_SIZE})"

# ----------------------------- 备份 2: 上传媒体 -----------------------------
UPLOADS_FILE="${BACKUP_DIR}/uploads-${TIMESTAMP}.tar.gz"
log "备份上传媒体 (wp-content/uploads/)..."

if [ -d "${SITE_DIR}/wp-content/uploads" ]; then
    tar -czf "${UPLOADS_FILE}" -C "${SITE_DIR}/wp-content" uploads 2>/dev/null || fail "uploads 打包失败"
    UPLOADS_SIZE=$(du -h "${UPLOADS_FILE}" | cut -f1)
    ok "上传媒体完成: ${UPLOADS_FILE} (${UPLOADS_SIZE})"
else
    warn "wp-content/uploads/ 不存在, 跳过媒体备份"
    UPLOADS_FILE=""
fi

# ----------------------------- 备份 3: DDEV 配置快照 -----------------------------
CONFIG_FILE="${BACKUP_DIR}/ddev-config-${TIMESTAMP}.tar.gz"
log "备份 DDEV 关键配置 (config.yaml + .env + wp-config.php)..."

CONFIG_TMP=$(mktemp -d)
trap "rm -rf ${CONFIG_TMP}" EXIT

mkdir -p "${CONFIG_TMP}/.ddev"
[ -f "${SITE_DIR}/.ddev/config.yaml" ] && cp "${SITE_DIR}/.ddev/config.yaml" "${CONFIG_TMP}/.ddev/"
[ -f "${SITE_DIR}/.env" ] && cp "${SITE_DIR}/.env" "${CONFIG_TMP}/" 2>/dev/null || true
[ -f "${SITE_DIR}/wp-config.php" ] && cp "${SITE_DIR}/wp-config.php" "${CONFIG_TMP}/" 2>/dev/null || true
if [ -d "${SITE_DIR}/.ddev/commands" ]; then
    cp -r "${SITE_DIR}/.ddev/commands" "${CONFIG_TMP}/.ddev/"
fi

tar -czf "${CONFIG_FILE}" -C "${CONFIG_TMP}" . 2>/dev/null
CONFIG_SIZE=$(du -h "${CONFIG_FILE}" | cut -f1)
ok "配置快照完成: ${CONFIG_FILE} (${CONFIG_SIZE})"

# ----------------------------- 复制到 Windows 异地 -----------------------------
if [ -d "${WIN_BACKUP_DIR}" ]; then
    log "复制到 Windows 异地目录: ${WIN_BACKUP_DIR}"
    cp "${DB_FILE}" "${WIN_BACKUP_DIR}/"
    [ -n "${UPLOADS_FILE}" ] && cp "${UPLOADS_FILE}" "${WIN_BACKUP_DIR}/"
    cp "${CONFIG_FILE}" "${WIN_BACKUP_DIR}/"
    ok "异地副本完成"
fi

# ----------------------------- 清理过期备份 -----------------------------
if [ "${RETENTION_DAYS}" -gt 0 ]; then
    log "清理 ${RETENTION_DAYS} 天前的旧备份..."
    DELETED=0
    for dir in "${BACKUP_DIR}" "${WIN_BACKUP_DIR}"; do
        [ -d "${dir}" ] || continue
        while IFS= read -r -d "" old_file; do
            rm -f "${old_file}"
            DELETED=$((DELETED+1))
        done < <(find "${dir}" -maxdepth 1 -type f \( -name "db-*.sql.gz" -o -name "uploads-*.tar.gz" -o -name "ddev-config-*.tar.gz" \) -mtime +${RETENTION_DAYS} -print0 2>/dev/null)
    done
    [ ${DELETED} -gt 0 ] && ok "已清理 ${DELETED} 个过期文件" || ok "无过期文件"
fi

# ----------------------------- 汇总 -----------------------------
echo ""
log "================ 备份汇总 ================"
echo "  数据库:  ${DB_FILE}  (${DB_SIZE})"
[ -n "${UPLOADS_FILE}" ] && echo "  媒体:    ${UPLOADS_FILE}  (${UPLOADS_SIZE})"
echo "  配置:    ${CONFIG_FILE}  (${CONFIG_SIZE})"
echo "  异地副本: ${WIN_BACKUP_DIR}"
echo "  保留策略: ${RETENTION_DAYS} 天 (0 = 永久)"
log "==========================================="
ok "备份完成"
