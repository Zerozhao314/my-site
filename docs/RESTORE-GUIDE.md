# DDEV WordPress 灾难恢复操作手册

> 适用: `~/ddev-test` 站点仓库 + `~/backups/ddev-test/` 增量备份目录
> 备份脚本: [scripts/backup.sh](file:///D:/project/wp-ai-customer-service/DDEV-GIT-SETUP.md) (rsync --link-dest 硬链接增量版)
> 最近更新: 2026-08-17

---

## 目录

1. [恢复场景分类](#1-恢复场景分类)
2. [前置准备](#2-前置准备)
3. [恢复 1: 数据库](#3-恢复-1-数据库)
4. [恢复 2: 上传文件 (uploads)](#4-恢复-2-上传文件-uploads)
5. [恢复 3: DDEV 配置](#5-恢复-3-ddev-配置)
6. [恢复 4: 全站灾备 (WSL 崩溃 / 数据丢失)](#6-恢复-4-全站灾备)
7. [恢复 5: 指定历史快照回滚](#7-恢复-5-指定历史快照回滚)
8. [恢复后验证清单](#8-恢复后验证清单)
9. [常见问题排查](#9-常见问题排查)

---

## 1. 恢复场景分类

| 场景 | 用什么 | 操作复杂度 | 预计耗时 |
|---|---|---|---|
| **A. 误删文章/订单** | 仅恢复数据库 | ⭐ 简单 | 1-2 分钟 |
| **B. 误删图片/媒体** | 仅恢复 uploads 个别文件 | ⭐⭐ 中等 | 2-5 分钟 |
| **C. 误改 wp-config** | 仅恢复配置 | ⭐ 简单 | < 1 分钟 |
| **D. 插件升级导致站点崩溃** | 恢复数据库 + 主题/插件 | ⭐⭐ 中等 | 3-5 分钟 |
| **E. WSL 损坏 / 整机数据丢失** | 从 Windows 异地副本重建 | ⭐⭐⭐ 复杂 | 15-30 分钟 |
| **F. 回到上周某天状态** | 指定历史快照 | ⭐⭐ 中等 | 3-5 分钟 |

**通用原则**:
- **先停站点**(`ddev stop`),避免恢复过程中 WordPress 写入新数据覆盖
- **保留损坏现状**:恢复前先把当前(损坏的)状态改名备份一份,留作事后分析
- **优先用 latest**:除非要回到历史状态,默认恢复 `latest` 快照

---

## 2. 前置准备

### 2.1 备份目录结构速查

```
~/backups/ddev-test/                    ← WSL 端主备份
├── latest -> daily.YYYYMMDD-HHMMSS     ← 软链接,永远指向最近一次成功的快照
├── daily.YYYYMMDD-HHMMSS/
│   ├── db.sql.gz                       ← 数据库 gzip 压缩
│   ├── ddev-config.tar.gz              ← .ddev/config.yaml + .env + wp-config.php + .ddev/commands/
│   ├── uploads/                         ← wp-content/uploads 的硬链接增量副本
│   └── MANIFEST                        ← 本次快照的元信息清单

/mnt/d/backups/ddev-test/               ← Windows 端异地副本 (结构完全一致)
└── (同上)
```

### 2.2 列出可用快照

```bash
# 所有快照按时间从新到旧排列
ls -1dt ~/backups/ddev-test/daily.* | head -20

# 或查看 latest 指向哪个
readlink -f ~/backups/ddev-test/latest

# 查看某次快照的清单
cat ~/backups/ddev-test/daily.20260817-092804/MANIFEST
```

### 2.3 进入站点目录并停止服务

```bash
cd ~/ddev-test
ddev stop
```

### 2.4 保留损坏现状(强烈推荐)

```bash
# 把当前损坏的数据库导出留底,命名带 .broken 后缀
ddev start >/dev/null 2>&1     # 启动以便导出
ddev export-db --gzip=false 2>/dev/null | gzip > ~/backups/ddev-test/db-broken-$(date +%Y%m%d-%H%M%S).sql.gz
ddev stop

# uploads 当前损坏状态也打包留底(可选,占用空间大时跳过)
tar -czf ~/backups/ddev-test/uploads-broken-$(date +%Y%m%d-%H%M%S).tar.gz \
    -C ~/ddev-test/wp-content uploads 2>/dev/null
```

---

## 3. 恢复 1: 数据库

### 适用场景
- 误删文章 / 页面 / 订单
- WP-CLI 误操作
- 插件升级失败导致数据库结构损坏
- 测试数据需要重置

### 操作步骤

```bash
cd ~/ddev-test
ddev start                                # 确保数据库容器运行
                                          # (即使站点白屏,数据库本身通常仍能起)

# 方式 A: 从 latest 软链接恢复 (推荐)
zcat ~/backups/ddev-test/latest/db.sql.gz | ddev import-db

# 方式 B: 从指定历史快照恢复
SNAPSHOT="daily.20260817-092804"
zcat ~/backups/ddev-test/${SNAPSHOT}/db.sql.gz | ddev import-db

# 方式 C: 从 Windows 异地副本恢复 (WSL 主备份损坏时)
zcat /mnt/d/backups/ddev-test/latest/db.sql.gz | ddev import-db
```

### 验证

```bash
# 确认行数符合预期
ddev mysql -e "SELECT COUNT(*) FROM wp_posts;"
ddev mysql -e "SELECT COUNT(*) FROM wp_users;"

# 检查最近的文章日期
ddev mysql -e "SELECT post_title, post_date FROM wp_posts WHERE post_status='publish' ORDER BY post_date DESC LIMIT 5;"

# 刷新 WP 缓存
ddev wp cache flush
ddev wp rewrite flush
```

---

## 4. 恢复 2: 上传文件 (uploads)

### 适用场景
- 误删媒体库图片
- 上传目录被恶意清空
- 图片损坏

### 4.1 部分文件恢复 (推荐,速度快)

```bash
cd ~/ddev-test
# 假设误删了 2026/08 子目录
ddev exec ls -la /var/www/html/wp-content/uploads/2026/08/

# 从 latest 单独 rsync 回指定子目录
rsync -avH --inplace \
    ~/backups/ddev-test/latest/uploads/2026/08/ \
    ~/ddev-test/wp-content/uploads/2026/08/

# 或从指定历史快照
SNAPSHOT="daily.20260817-092804"
rsync -avH --inplace \
    ~/backups/ddev-test/${SNAPSHOT}/uploads/2026/08/ \
    ~/ddev-test/wp-content/uploads/2026/08/
```

### 4.2 全量恢复 uploads (整个目录覆盖)

```bash
cd ~/ddev-test
ddev stop

# 先删除当前 uploads (避免残留损坏文件)
rm -rf ~/ddev-test/wp-content/uploads

# 从 latest 恢复 (硬链接同步,快速)
rsync -avH --inplace \
    ~/backups/ddev-test/latest/uploads/ \
    ~/ddev-test/wp-content/uploads/

# 从 Windows 异地副本恢复 (WSL 备份损坏时,会慢一些,因为是跨 DrvFs)
rm -rf ~/ddev-test/wp-content/uploads
rsync -avH --inplace \
    /mnt/d/backups/ddev-test/latest/uploads/ \
    ~/ddev-test/wp-content/uploads/

# 修复权限 (DDEV 要求 www-data 可读写)
ddev start
ddev exec sudo chown -R www-data:www-data /var/www/html/wp-content/uploads
ddev exec sudo find /var/www/html/wp-content/uploads -type d -exec chmod 755 {} \;
ddev exec sudo find /var/www/html/wp-content/uploads -type f -exec chmod 644 {} \;
```

### 4.3 验证

```bash
# 文件数对比
find ~/ddev-test/wp-content/uploads -type f | wc -l
find ~/backups/ddev-test/latest/uploads -type f | wc -l

# MD5 抽查
md5sum ~/ddev-test/wp-content/uploads/2026/08/some-image.jpg
md5sum ~/backups/ddev-test/latest/uploads/2026/08/some-image.jpg

# WP 后台 → 媒体库 → 查看图片是否能正常显示
# 或命令行检查
ddev wp media image regenerate --yes
```

---

## 5. 恢复 3: DDEV 配置

### 适用场景
- `.ddev/config.yaml` 误改导致 DDEV 启动失败
- `wp-config.php` 中的 secret key 损坏
- 自定义 `.ddev/commands/` 误删

### 5.1 解压配置快照到临时目录查看

```bash
SNAPSHOT="latest"   # 或指定 "daily.20260817-092804"
TMP=$(mktemp -d)
tar -xzf ~/backups/ddev-test/${SNAPSHOT}/ddev-config.tar.gz -C "${TMP}"
ls -la "${TMP}"
ls -la "${TMP}/.ddev/"
```

预期内容:
```
./.ddev/config.yaml        ← DDEV 项目配置
./.ddev/commands/          ← 自定义命令目录
./.env                     ← 环境变量(若有)
./wp-config.php            ← WordPress 配置(含 secret key)
```

### 5.2 恢复 .ddev/config.yaml

```bash
cd ~/ddev-test
ddev stop

# 恢复单个文件
cp ~/backups/ddev-test/latest/ddev-config.tar.gz /tmp/
cd /tmp && tar -xzf ddev-config.tar.gz .ddev/config.yaml
cp /tmp/.ddev/config.yaml ~/ddev-test/.ddev/config.yaml

# 重启 DDEV 应用新配置
cd ~/ddev-test && ddev restart
```

### 5.3 恢复 wp-config.php

```bash
cd ~/ddev-test

# 注意:DDEV 会自动生成 wp-config.php,只有手动改过才需要恢复
# (如果没改过,直接 ddev restart 让 DDEV 重新生成)
ddev stop

TMP=$(mktemp -d)
tar -xzf ~/backups/ddev-test/latest/ddev-config.tar.gz -C "${TMP}"
cp "${TMP}/wp-config.php" ~/ddev-test/wp-config.php
rm -rf "${TMP}"

ddev start
```

### 5.4 恢复 .ddev/commands/ 自定义命令

```bash
cd ~/ddev-test

TMP=$(mktemp -d)
tar -xzf ~/backups/ddev-test/latest/ddev-config.tar.gz -C "${TMP}"
rm -rf ~/ddev-test/.ddev/commands
cp -r "${TMP}/.ddev/commands" ~/ddev-test/.ddev/
rm -rf "${TMP}"

# 验证
ddev list
ls ~/ddev-test/.ddev/commands/host/
ls ~/ddev-test/.ddev/commands/web/
ls ~/ddev-test/.ddev/commands/db/
```

### 5.5 恢复 .env (若存在)

```bash
cd ~/ddev-test
TMP=$(mktemp -d)
tar -xzf ~/backups/ddev-test/latest/ddev-config.tar.gz -C "${TMP}"
[ -f "${TMP}/.env" ] && cp "${TMP}/.env" ~/ddev-test/.env || echo "本次快照无 .env"
rm -rf "${TMP}"
```

---

## 6. 恢复 4: 全站灾备

### 适用场景
- WSL 发行版损坏/被重装
- 磁盘故障导致 `~/ddev-test` 数据丢失
- 想在另一台机器复刻当前开发环境

### 6.1 前置条件

- 已安装 WSL2 (Ubuntu 24.04) + DDEV
- 已克隆站点仓库:`git clone git@github.com:Zerozhao314/my-site.git ~/ddev-test`
- 已克隆插件仓库:`git clone git@github.com:Zerozhao314/sit-plugin.git /mnt/d/project/wp-ai-customer-service`
- Windows D 盘异地副本存在:`D:\backups\ddev-test\`

### 6.2 完整恢复流程

```bash
# 1. 进入站点目录,确认从 git 拉到最新
cd ~/ddev-test
git pull origin main
ls -la   # 应看到 .gitignore, scripts/backup.sh, 3 个调试脚本

# 2. 启动 DDEV (会自动生成 wp-admin/ wp-includes/ 等 WP 核心)
ddev start
# 等待完成,首次启动会安装 WordPress

# 3. 恢复 DDEV 配置 (让 DDEV 知道用 MariaDB 11.8 而非默认 MySQL)
ddev stop
TMP=$(mktemp -d)
tar -xzf /mnt/d/backups/ddev-test/latest/ddev-config.tar.gz -C "${TMP}"
cp "${TMP}/.ddev/config.yaml" ~/ddev-test/.ddev/config.yaml
[ -f "${TMP}/wp-config.php" ] && cp "${TMP}/wp-config.php" ~/ddev-test/wp-config.php
[ -d "${TMP}/.ddev/commands" ] && cp -r "${TMP}/.ddev/commands" ~/ddev-test/.ddev/
rm -rf "${TMP}"

# 4. 启动 DDEV (应用恢复后的 config.yaml)
ddev start
# 此时 wp-admin/wp-includes 会按 config.yaml 的 php_version/webserver_type 重新生成

# 5. 恢复数据库 (覆盖 DDEV 自动安装的空 WP)
zcat /mnt/d/backups/ddev-test/latest/db.sql.gz | ddev import-db

# 6. 恢复 uploads (从 Windows D 盘异地副本)
rm -rf ~/ddev-test/wp-content/uploads
rsync -avH --inplace \
    /mnt/d/backups/ddev-test/latest/uploads/ \
    ~/ddev-test/wp-content/uploads/

# 7. 修复权限
ddev exec sudo chown -R www-data:www-data /var/www/html/wp-content/uploads
ddev exec sudo find /var/www/html/wp-content/uploads -type d -exec chmod 755 {} \;
ddev exec sudo find /var/www/html/wp-content/uploads -type f -exec chmod 644 {} \;

# 8. 重新部署插件 (从 Windows 源码仓库)
cd /mnt/d/project/wp-ai-customer-service
./deploy.ps1   # 或在 WSL 内执行 rsync 命令
# 或 git hook 触发:随便改个 commit 即可

# 9. 刷新缓存
cd ~/ddev-test
ddev wp cache flush
ddev wp rewrite flush
ddev wp search reindex

# 10. 验证访问
echo "访问: https://ddev-test.ddev.site"
```

### 6.3 关键验证清单

```bash
# 数据库连接正常
ddev mysql -e "SELECT VERSION();"

# WP 配置完整
ddev wp core is-installed
ddev wp user list

# 插件已激活
ddev wp plugin list --status=active

# 媒体文件齐全
find ~/ddev-test/wp-content/uploads -type f | wc -l

# 站点可访问
curl -sI https://ddev-test.ddev.site | head -1
# 期望: HTTP/2 200
```

---

## 7. 恢复 5: 指定历史快照回滚

### 适用场景
- 当前 latest 不行,要回到上周三的状态
- 测试某次改动前的功能是否正常

### 7.1 查找目标快照

```bash
# 按时间从新到旧列出所有快照
ls -1dt ~/backups/ddev-test/daily.*

# 查看每个快照的 MANIFEST 元信息
for m in ~/backups/ddev-test/daily.*/MANIFEST; do
    echo "=== $(dirname "$m" | xargs basename) ==="
    cat "$m"
    echo ""
done | less
```

### 7.2 回滚到指定快照

```bash
# 1. 选定目标快照
TARGET="daily.20260815-092701"

cd ~/ddev-test
ddev stop

# 2. 恢复数据库
zcat ~/backups/ddev-test/${TARGET}/db.sql.gz | ddev import-db

# 3. 恢复 uploads (覆盖式)
rsync -avH --delete --inplace \
    ~/backups/ddev-test/${TARGET}/uploads/ \
    ~/ddev-test/wp-content/uploads/

# 4. 恢复配置
TMP=$(mktemp -d)
tar -xzf ~/backups/ddev-test/${TARGET}/ddev-config.tar.gz -C "${TMP}"
cp "${TMP}/.ddev/config.yaml" ~/ddev-test/.ddev/config.yaml
[ -f "${TMP}/wp-config.php" ] && cp "${TMP}/wp-config.php" ~/ddev-test/wp-config.php
rm -rf "${TMP}"

# 5. 启动 + 刷缓存
ddev start
ddev wp cache flush
```

> ⚠️ `--delete` 标志会删除目标目录中不在快照里的文件,慎用。如只想恢复部分文件,去掉 `--delete`。

---

## 8. 恢复后验证清单

恢复完成后,按此清单逐项确认:

```bash
# === 1. DDEV 健康 ===
ddev list                           # STATUS = OK
ddev describe | grep -E "URL|STATUS"

# === 2. 数据库完整 ===
ddev mysql -e "SHOW TABLES;" | wc -l   # 表数量符合预期
ddev wp core is-installed              # 退出码 0
ddev wp option get siteurl             # URL 正确
ddev wp option get home                # home URL 正确

# === 3. uploads 文件数 ===
EXPECTED=$(find ~/backups/ddev-test/latest/uploads -type f | wc -l)
ACTUAL=$(find ~/ddev-test/wp-content/uploads -type f | wc -l)
echo "期望: $EXPECTED, 实际: $ACTUAL"
[ "$EXPECTED" = "$ACTUAL" ] && echo "OK" || echo "MISMATCH"

# === 4. 插件状态 ===
ddev wp plugin list
# 确认 wp-ai-customer-service 状态为 active

# === 5. 主题状态 ===
ddev wp theme list
# 确认期望主题为 active

# === 6. 站点访问 ===
curl -sI https://ddev-test.ddev.site | head -3
# 期望 HTTP/2 200,无 500 错误

# === 7. 后台可登录 ===
ddev wp user list --fields=ID,user_login,user_email
# 用 admin 账号登录 https://ddev-test.ddev.site/wp-admin 验证

# === 8. 最新文章日期符合预期 ===
ddev mysql -e "SELECT post_title, post_date FROM wp_posts WHERE post_status='publish' ORDER BY post_date DESC LIMIT 3;"
```

---

## 9. 常见问题排查

### 9.1 `ddev import-db` 报错

```
ERROR 1273 (Hy000) at line X: Unknown collation: 'utf8mb4_0900_ai_ci'
```

**原因**:备份用 MySQL 8.0,恢复目标用 MariaDB 11.x(MariaDB 不识别 0900 collation)。

**解决**:
```bash
# 解压并替换 collation 后再导入
zcat ~/backups/ddev-test/latest/db.sql.gz \
    | sed 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g' \
    | ddev import-db
```

### 9.2 上传后图片后台显示但前台 404

**原因**:uploads 权限不对。

**解决**:
```bash
ddev exec sudo chown -R www-data:www-data /var/www/html/wp-content/uploads
ddev exec sudo find /var/www/html/wp-content/uploads -type d -exec chmod 755 {} \;
ddev exec sudo find /var/www/html/wp-content/uploads -type f -exec chmod 644 {} \;
ddev wp rewrite flush
```

### 9.3 恢复后插件报错 fatal

**原因**:插件源码没同步恢复。

**解决**(从插件仓库重新部署):
```powershell
# Windows 端
cd d:\project\wp-ai-customer-service
.\deploy.ps1
```
或直接跑 hook 触发:
```powershell
git commit --allow-empty -m "chore: 触发同步"
```

### 9.4 `.ddev/commands/` 自定义命令恢复后不生效

**解决**:
```bash
ddev stop
ddev start
ddev list
# 期望看到 ~/ddev-test/.ddev/commands/ 下的命令出现在 ddev --help
```

### 9.5 Windows 异地副本 /mnt/d 无法访问

**原因**:WSL2 没挂载 D 盘(罕见)。

**解决**:
```bash
# 检查 /mnt/d 是否存在
ls /mnt/

# 如果没有 d 目录,手动挂载
sudo mkdir -p /mnt/d
sudo mount -t drvfs D: /mnt/d -o metadata,uid=1000,gid=1000

# 永久挂载(写入 /etc/fstab)
echo "D: /mnt/d drvfs metadata,uid=1000,gid=1000 0 0" | sudo tee -a /etc/fstab
```

### 9.6 备份脚本本身丢失(scripts/backup.sh 不见了)

**原因**:站点仓库被误删。

**解决**:
```bash
# 从 GitHub 拉回站点仓库
cd ~
git clone git@github.com:Zerozhao314/my-site.git ddev-test
cd ddev-test
ls scripts/backup.sh   # 期望看到
```

---

## 附:命令速查卡

```bash
# === 列出快照 ===
ls -1dt ~/backups/ddev-test/daily.* | head -10
readlink ~/backups/ddev-test/latest

# === 数据库 ===
zcat ~/backups/ddev-test/latest/db.sql.gz | ddev import-db

# === uploads ===
rsync -avH --inplace ~/backups/ddev-test/latest/uploads/ ~/ddev-test/wp-content/uploads/

# === 配置 ===
TMP=$(mktemp -d) && tar -xzf ~/backups/ddev-test/latest/ddev-config.tar.gz -C "${TMP}"
cp "${TMP}/.ddev/config.yaml" ~/ddev-test/.ddev/config.yaml
cp "${TMP}/wp-config.php" ~/ddev-test/wp-config.php
rm -rf "${TMP}"

# === 权限 ===
ddev exec sudo chown -R www-data:www-data /var/www/html/wp-content/uploads
ddev exec sudo find /var/www/html/wp-content/uploads -type d -exec chmod 755 {} \;
ddev exec sudo find /var/www/html/wp-content/uploads -type f -exec chmod 644 {} \;

# === 验证 ===
ddev wp cache flush
ddev wp core is-installed && echo "WP OK"
curl -sI https://ddev-test.ddev.site | head -1

# === 异地副本路径 ===
# WSL:      ~/backups/ddev-test/latest/
# Windows:  D:\backups\ddev-test\latest\
# WSL 访问: /mnt/d/backups/ddev-test/latest/
```

---

## 附录:与备份脚本的关系

| 备份产出 | 恢复命令 |
|---|---|
| `db.sql.gz` (gzip SQL) | `zcat db.sql.gz \| ddev import-db` |
| `uploads/` (目录,硬链接) | `rsync -avH uploads/ <dest>/` |
| `ddev-config.tar.gz` | `tar -xzf ddev-config.tar.gz -C <tmp>`,再 `cp` 单个文件 |
| `MANIFEST` | 仅供查看,不需恢复 |
| `latest` (软链接) | 自动指向最新快照,无需手动维护 |

恢复脚本完成后,**立即执行一次 `./scripts/backup.sh`**,把恢复后的健康状态作为新的 `latest` 基准。
