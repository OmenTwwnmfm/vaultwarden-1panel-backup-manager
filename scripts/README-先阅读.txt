Vaultwarden 1Panel Backup Manager v1.5.3
=======================================

适用环境
--------
- Ubuntu / Debian VPS，使用 systemd。
- Docker 已由 1Panel 安装和管理。
- Vaultwarden 已从 1Panel 应用商店安装为 Docker 应用。
- 使用 SQLite，容器内数据目录挂载为 /data。
- 具有 root 权限或可通过 sudo 管理 Docker、systemd 和系统目录。

本项目不会安装 Docker、Vaultwarden、域名、HTTPS 或反向代理；这些均由 1Panel 负责。

启动方式
--------
从 GitHub 克隆完整项目后：

  sudo bash ./run.sh

首次配置选择 [01]。管理器会自动识别容器和 /data 主机路径，并配置 age 公钥、备份目标及本地保留策略。项目要求由 root 所有且不可由普通用户修改。

主菜单
------
01 · 快速操作
  [01] 首次配置 / 重新检测容器与数据目录
  [02] 立即执行备份（GitHub / WebDAV）
  [03] 检查当前环境与备份状态

02 · 备份与验证
  [04] 查看备份日志
  [05] 验证历史备份（GitHub / 本地 / WebDAV）
  [06] 查看加密部署清单（GitHub / 本地 / WebDAV）
  [07] 性能监控与执行耗时分析

03 · 恢复与演练
  [08] 选择备份并恢复生产数据（GitHub / 本地 / WebDAV）
  [09] 隔离恢复演练（GitHub / 本地 / WebDAV）

04 · 存储与保留
  [10] 历史备份文件管理（GitHub / 本地 / WebDAV）
  [11] 查看 / 删除本地备份（本地）
  [12] 配置 WebDAV 连接（WebDAV）
  [13] 上传 / 补传 WebDAV 备份（WebDAV）

05 · 自动化与安全
  [14] 安装 / 修改自动备份（GitHub / WebDAV）
  [15] 查看定时任务状态
  [16] 暂停自动备份
  [17] 恢复自动备份
  [18] 配置通知与告警
  [19] 更新前备份保护

06 · 系统维护
  [20] 生成系统诊断报告
  [21] 配置备份策略
  [22] 同步已安装后台脚本
  [23] 检查 / 更新项目源码并同步后台脚本

[00] 退出

备份、验证与恢复
----------------
备份整个 /data，包括 SQLite、WAL/SHM、附件、Send 文件、config.json 和 RSA 密钥（存在时）。默认在停止容器期间创建一致快照；也可在 [21] 启用 online 模式。

每次备份生成：
  vw-YYYYMMDD-HHMMSS.tar.gz.age
  vw-YYYYMMDD-HHMMSS.tar.gz.age.sha256
  vw-YYYYMMDD-HHMMSS.tar.gz.age.sha256.sig
  vw-YYYYMMDD-HHMMSS.manifest.json.age
  vw-YYYYMMDD-HHMMSS.manifest.json.age.sha256
  vw-YYYYMMDD-HHMMSS.manifest.json.age.sha256.sig

恢复前生成的 pre-restore-*.tar.gz.age 是当前生产数据的加密回滚快照，不替代常规备份。[05] 使用离线 age 私钥验证，[08] 恢复生产数据，[09] 使用隔离临时容器演练。验证和演练的明文暂存目录必须位于 /dev/shm tmpfs；不可用时操作会停止，避免明文写入持久磁盘。

自动备份
--------
推荐使用 Ubuntu/Debian 的 systemd timer，不依赖 1Panel 计划任务。先手动备份并验证，再在 [14] 安装或修改计划；[15] 查看状态，[16] 暂停，[17] 恢复。默认每天 VPS 本地时间 05:20，Persistent=true 支持错过计划后补执行。

常用命令：
  systemctl list-timers --all | grep vw-backup
  systemctl status vw-backup.timer
  systemctl start vw-backup.service
  journalctl -u vw-backup.service -n 100 --no-pager
  tail -n 100 /var/log/vaultwarden-backup.log

安全说明
--------
- 源码仓库与加密备份仓库必须分开；GitHub 备份仓库必须为 Private，WebDAV 使用 HTTPS 专用目录。
- age 私钥必须离线保存至少两份；GitHub Deploy Key 只用于仓库访问，不能替代 age 私钥。
- 备份签名密钥与 GitHub Deploy Key 分开保存；allowed_signers 需要可信的离线副本。
- 不要把真实配置、Token、SSH 私钥、age 私钥、数据库、附件或 .age 文件提交到源码仓库。
- 仅支持 SQLite 和容器内 /data 挂载；不支持 MySQL/PostgreSQL。
- 单文件默认限制 90 MiB；Git 删除文件不会清除历史提交中的旧对象。

文件说明
--------
- vw-manager.sh：交互菜单、定时任务、通知、恢复、历史管理等。
- vw-common.sh：容器发现、配置保存、通知与公共函数。
- vw-backup.sh：systemd 和手动调用的非交互备份工作器。
- vw-restore-prepare.sh：SHA256、签名、age 解密、tar 安全检查和 SQLite 暂存验证。
- vw-storage.py：签名、WebDAV、本地保留和备份组管理。
- vw-manifest.py：创建脱敏部署清单。
- vw-diagnose.sh：生成脱敏诊断报告。
- backup.conf.example：配置字段示例。
