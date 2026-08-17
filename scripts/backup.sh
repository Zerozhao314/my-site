#!/usr/bin/env bash
# =============================================================================
# DDEV WordPress 站点备份脚本 (增量硬链接版)
#
# 策略: rsync --link-dest 对 uploads 做目录级硬链接增量,未变更文件 0 空间
#       每次备份一个独立目录 (daily.YYYYMMDD-HHMMSS/),用 latest 软链接回指
#       最后 rsync -aH 把硬链接关系同步到 Windows 异地副本
#
# 目录结构 (WSL ~/backups/ddev-test/  &  Windows D:\backups\ddev-test\):
#   latest -> daily.20260817-093000      (软链接, 指向最近一次成功的备份)
#   daily.20260817-093000/
#     db.sql.gz                          (数据库 gzip, 14MB 量级)
#     ddev-config.tar.gz                 (.ddev/config.yaml + wp-config.php)
#     uploads/                           (wp-content/uploads, 硬链接增量)
#     MANIFEST                           (清单: 时间戳, 文件数, 新增大小)
#
# 执行: cd ~/ddev-test && ./scripts/backup.sh
# 定时: crontab -e 添加:
#   0 2 * * * /home/zero/ddev-test/scripts/backup.sh >> ~/backups/ddev-test/backup.log 2>&1
# =============================================================================

set -euo pipefail

# ----------------------------- 配置区 -----------------------------
SITE_DIR="${HOME}/ddev-test"
SITE_NAME="ddev-test"

BACKUP_DIR="${HOME}/backups/${SITE_NAME}"
WIN_BACKUP_DIR="/mnt/d/backups/${SITE_NAME}"

# 保留最近 N 个 daily 快照 (含 latest)
RETENTION_COUNT=30

# ----------------------------- 初始化 -----------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CURRENT_DIR="${BACKUP_DIR}/daily.${TIMESTAMP}"
CURRENT_WIN_DIR="${WIN_BACKUP_DIR}/daily.${TIMESTAMP}"
LATEST_LINK="${BACKUP_DIR}/latest"
LATEST_WIN_LINK="${WIN_BACKUP_DIR}/latest"
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

# 解析 latest 软链接到绝对路径,不存在则返回空串
resolve_latest() {
    local link="$1"
    if [ -L "${link}" ] && [ -d "${link}" ]; then
        readlink -f "${link}"
    else
        echo ""
    fi
}

# ----------------------------- 前置检查 -----------------------------
log "启动 DDEV WordPress 增量备份 (rsync --link-dest + 硬链接)"

[ -d "${SITE_DIR}" ] || fail "站点目录不存在: ${SITE_DIR}"
[ -d "${SITE_DIR}/.ddev" ] || fail "未找到 .ddev 目录"

mkdir -p "${BACKUP_DIR}"
mkdir -p "${WIN_BACKUP_DIR}" 2>/dev/null || warn "无法创建 Windows 异地目录 ${WIN_BACKUP_DIR} (仅本地备份)"

cd "${SITE_DIR}"
if ! ddev describe 2>/dev/null | grep -q "OK"; then
    warn "DDEV 未运行, 正在启动..."
    ddev start >/dev/null 2>&1 || fail "DDEV 启动失败"
    sleep 3
fi

ok "环境检查通过"

# ----------------------------- 创建本次备份目录 -----------------------------
PREVIOUS=$(resolve_latest "${LATEST_LINK}")
mkdir -p "${CURRENT_DIR}/uploads"

if [ -n "${PREVIOUS}" ]; then
    log "检测到上一个快照: ${PREVIOUS}"
    LINK_DEST_UPLOADS="${PREVIOUS}/uploads"
else
    log "首次执行: 无上一个快照, 本次为全量基准"
    LINK_DEST_UPLOADS=""
fi

# ----------------------------- 1. 数据库 -----------------------------
log "备份数据库 (ddev export-db -> gzip)..."
ddev export-db --gzip=false 2>/dev/null | gzip > "${CURRENT_DIR}/db.sql.gz" || fail "数据库导出失败"
DB_SIZE=$(du -h "${CURRENT_DIR}/db.sql.gz" | cut -f1)
DB_LINES=$(zcat "${CURRENT_DIR}/db.sql.gz" | wc -l)
ok "数据库完成: db.sql.gz (${DB_SIZE}, ${DB_LINES} 行 SQL)"

# ----------------------------- 2. uploads 增量 (硬链接) -----------------------------
log "备份 uploads (rsync 硬链接增量)..."
START_TIME=$(date +%s)

if [ -d "${SITE_DIR}/wp-content/uploads" ]; then
    RSYNC_OPTS="-aH --delete --stats --inplace"
    if [ -n "${LINK_DEST_UPLOADS}" ] && [ -d "${LINK_DEST_UPLOADS}" ]; then
        RSYNC_OPTS="${RSYNC_OPTS} --link-dest=${LINK_DEST_UPLOADS}"
    fi
    # rsync 输出 stats, 方便统计新增/复用文件数
    RSYNC_LOG=$(rsync ${RSYNC_OPTS} "${SITE_DIR}/wp-content/uploads/" "${CURRENT_DIR}/uploads/" 2>&1) || fail "rsync uploads 失败"
    RSYNC_EXIT=$?
else
    warn "wp-content/uploads/ 不存在, 跳过"
    RSYNC_LOG=""
fi

ELAPSED=$(( $(date +%s) - START_TIME ))
UPLOADS_SIZE=$(du -sh "${CURRENT_DIR}/uploads" | cut -f1)
UPLOADS_COUNT=$(find "${CURRENT_DIR}/uploads" -type f | wc -l)

# 解析 rsync --stats 输出 (关键指标)
NEW_FILES=$(echo "${RSYNC_LOG}" 2>/dev/null | grep -oP 'Number of (created|transferred) files:\s*\K[0-9]+' | head -1 || echo "?")
# 硬链接复用数 = 总文件数 - (新创建 + 被删除) - 元数据文件
if [ "${UPLOADS_COUNT}" -gt 0 ] && [ "${NEW_FILES}" != "?" ]; then
    REUSED=$(( UPLOADS_COUNT - NEW_FILES ))
    [ ${REUSED} -lt 0 ] && REUSED=0
else
    REUSED="?"
fi

ok "uploads 完成: ${UPLOADS_SIZE}, ${UPLOADS_COUNT} 个文件 (新增 ${NEW_FILES}, 复用 ${REUSED}, 耗时 ${ELAPSED}s)"

# ----------------------------- 3. DDEV 配置快照 -----------------------------
log "备份 DDEV 关键配置 (config.yaml + wp-config.php + .ddev/commands)..."
CONFIG_TMP=$(mktemp -d)
trap "rm -rf ${CONFIG_TMP}" EXIT

mkdir -p "${CONFIG_TMP}/.ddev"
[ -f "${SITE_DIR}/.ddev/config.yaml" ] && cp "${SITE_DIR}/.ddev/config.yaml" "${CONFIG_TMP}/.ddev/"
[ -f "${SITE_DIR}/.env" ] && cp "${SITE_DIR}/.env" "${CONFIG_TMP}/" 2>/dev/null || true
[ -f "${SITE_DIR}/wp-config.php" ] && cp "${SITE_DIR}/wp-config.php" "${CONFIG_TMP}/" 2>/dev/null || true
if [ -d "${SITE_DIR}/.ddev/commands" ]; then
    cp -r "${SITE_DIR}/.ddev/commands" "${CONFIG_TMP}/.ddev/"
fi

tar -czf "${CURRENT_DIR}/ddev-config.tar.gz" -C "${CONFIG_TMP}" . 2>/dev/null
CONFIG_SIZE=$(du -h "${CURRENT_DIR}/ddev-config.tar.gz" | cut -f1)
ok "配置快照完成: ddev-config.tar.gz (${CONFIG_SIZE})"

# ----------------------------- 4. 写 MANIFEST 清单 -----------------------------
{
    echo "TIMESTAMP=${TIMESTAMP}"
    echo "DATE=$(date -Iseconds)"
    echo "DB_SIZE=${DB_SIZE}"
    echo "DB_SQL_LINES=${DB_LINES}"
    echo "UPLOADS_SIZE=${UPLOADS_SIZE}"
    echo "UPLOADS_FILES=${UPLOADS_COUNT}"
    echo "UPLOADS_NEW_FILES=${NEW_FILES}"
    echo "UPLOADS_REUSED_FILES=${REUSED}"
    echo "UPLOADS_RSYNC_SEC=${ELAPSED}"
    echo "CONFIG_SIZE=${CONFIG_SIZE}"
    echo "PREVIOUS_SNAPSHOT=${PREVIOUS:-none}"
    echo "RSYNC_OPTS=${RSYNC_OPTS:-none}"
} > "${CURRENT_DIR}/MANIFEST"

# ----------------------------- 5. 更新 latest 软链接 -----------------------------
# 原子操作: 先建临时链接再 rename
ln -sfn "${CURRENT_DIR}" "${LATEST_LINK}.tmp"
mv -Tf "${LATEST_LINK}.tmp" "${LATEST_LINK}"
ok "latest 软链接已更新 -> daily.${TIMESTAMP}"

# ----------------------------- 6. Windows 异地副本 (rsync -aH 保留硬链接) -----------------------------
if [ -d "${WIN_BACKUP_DIR}" ]; then
    log "同步到 Windows 异地目录 (rsync -aH 保留硬链接关系)..."
    SYNC_START=$(date +%s)

    # 6a. 只同步本次 daily.* 目录 (通过 -aH 保留与已有快照间的硬链接)
    rsync -aH --inplace "${CURRENT_DIR}/" "${CURRENT_WIN_DIR}/" 2>/dev/null || fail "Windows 异地同步失败"

    # 6b. 同步 latest 软链接 -> Windows 端
    #     /mnt/d 默认不支持 symlink (DrvFs metadata 未启用时),用 "latest" 目录回退
    if [ -L "${LATEST_WIN_LINK}" ]; then
        rm -f "${LATEST_WIN_LINK}"
    fi
    if [ -d "${LATEST_WIN_LINK}" ]; then
        rm -rf "${LATEST_WIN_LINK}"
    fi
    # 优先 symlink,失败则退化为 latest 目录硬链接集合(占空间,但可访问)
    if ln -sfn "${CURRENT_WIN_DIR}" "${LATEST_WIN_LINK}" 2>/dev/null; then
        :
    else
        warn "Windows DrvFs 不支持 symlink, 退化为 latest 实副本目录 (含 uploads 硬链接复用)"
        mkdir -p "${LATEST_WIN_LINK}"
        rsync -aH --link-dest="${CURRENT_WIN_DIR}/uploads" "${CURRENT_WIN_DIR}/" "${LATEST_WIN_LINK}/" 2>/dev/null \
            || warn "latest 实副本同步失败 (不影响 daily.* 备份本身)"
    fi

    SYNC_ELAPSED=$(( $(date +%s) - SYNC_START ))
    WIN_UPLOADS_SIZE=$(du -sh "${CURRENT_WIN_DIR}/uploads" 2>/dev/null | cut -f1 || echo "?")
    ok "异地副本完成: ${CURRENT_WIN_DIR} (uploads ${WIN_UPLOADS_SIZE}, 耗时 ${SYNC_ELAPSED}s)"
fi

# ----------------------------- 7. 清理过期快照 -----------------------------
if [ "${RETENTION_COUNT}" -gt 0 ]; then
    log "保留最近 ${RETENTION_COUNT} 个 daily 快照, 删除其余..."
    DELETED=0

    for base_dir in "${BACKUP_DIR}" "${WIN_BACKUP_DIR}"; do
        [ -d "${base_dir}" ] || continue
        # 按修改时间从新到旧列 daily.* 目录, 跳过前 N 个, 其余删
        while IFS= read -r old_dir; do
            [ -z "${old_dir}" ] && continue
            # latest 永远不删 (即使 count 不够)
            [ "$(basename "${old_dir}")" = "latest" ] && continue
            rm -rf "${old_dir}"
            DELETED=$((DELETED+1))
        done < <(find "${base_dir}" -maxdepth 1 -type d -name "daily.*" -printf "%T@ %p\n" 2>/dev/null \
                  | sort -rn \
                  | tail -n +$((RETENTION_COUNT+1)) \
                  | cut -d' ' -f2-)
    done
    [ ${DELETED} -gt 0 ] && ok "已清理 ${DELETED} 个过期快照" || ok "无过期快照"
fi

# ----------------------------- 8. 汇总 -----------------------------
# 硬链接节省空间估算:
#   未用硬链接 = (全部 daily.* 独立) = daily 数 * uploads 大小
#   实际占用  = du -sh BACKUP_DIR (不会重复统计硬链接)
# 注: du 默认对硬链接只计一次 (POSIX 行为), 所以 BACKUP_DIR 总大小 ~= 基准 + 每次增量
TOTAL_SIZE=$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1 || echo "?")

SNAPSHOT_COUNT=$(find "${BACKUP_DIR}" -maxdepth 1 -type d -name "daily.*" | wc -l)

echo ""
log "================ 备份汇总 ================"
echo "  快照目录:  ${CURRENT_DIR}"
echo "  数据库:    ${CURRENT_DIR}/db.sql.gz  (${DB_SIZE})"
echo "  uploads:   ${CURRENT_DIR}/uploads/   (${UPLOADS_SIZE}, ${UPLOADS_COUNT} 文件, 复用 ${REUSED}, 新增 ${NEW_FILES})"
echo "  配置:      ${CURRENT_DIR}/ddev-config.tar.gz  (${CONFIG_SIZE})"
echo "  latest 链接:${LATEST_LINK}  ->  daily.${TIMESTAMP}"
echo ""
echo "  异地副本:  ${CURRENT_WIN_DIR}"
echo ""
echo "  快照总数:  ${SNAPSHOT_COUNT}  (保留 ${RETENTION_COUNT})"
echo "  实际占用:  ${TOTAL_SIZE}  (du 已扣除硬链接重复统计)"
log "==========================================="
ok "增量备份完成"
