Vaultwarden 1Panel Backup Manager v1.3.0
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

首次配置选择菜单 1。管理器自动扫描 Vaultwarden 容器，通过 docker inspect 读取 /data 的主机路径；多个候选实例会要求人工选择。随后配置 GitHub Deploy Key、age 公钥、本地目录和保留策略。

主菜单
------
  1) 首次配置 / 重新检测容器与数据目录
  2) 立即备份当前数据并推送 GitHub
  3) 从 GitHub 选择备份并恢复数据
  4) 检查当前环境和备份配置
  5) 查看最近备份日志
  6) 查看自动备份定时任务帮助
  7) 更新已安装的后台脚本（保留现有配置）
  8) 验证 GitHub 历史备份（SHA256 / age / SQLite）
  9) 安装 systemd 自动备份 / 修改执行时间
 10) 查看 systemd 定时任务状态
 11) 暂停自动备份
 12) 恢复自动备份
 13) 配置 Telegram / ntfy / Webhook 通知并测试
 14) Vaultwarden 更新前自动备份保护
 15) 生成系统诊断报告
 16) 历史备份管理（查看 / 永久保留 / 取消保留 / 删除）
 17) 查看加密部署清单
 18) 隔离恢复演练（临时容器启动，不接入生产网络、不修改生产数据）
 19) 配置保留天数 / 磁盘阈值 / GitHub 推送重试
  0) 退出

自动备份调度
------------
推荐使用 Ubuntu/Debian 自带的 systemd timer，不依赖 1Panel 计划任务。首次手动备份成功后，在菜单 9 安装，可选择每天、每周日或每月 1 日，默认每天 VPS 本地时间 05:20；可修改频率和执行时间。systemd timer 使用 Persistent=true，VPS 关机错过计划后可以在下次启动补执行。

常用命令：
  systemctl list-timers --all | grep vw-backup
  systemctl status vw-backup.timer
  systemctl start vw-backup.service
  journalctl -u vw-backup.service -n 100 --no-pager
  tail -n 100 /var/log/vaultwarden-backup.log

如果此前在 1Panel 计划任务或 crontab 设置了同一备份命令，请停用旧任务，避免重复运行。

备份范围与验证
--------------
备份整个 /data，而不是只备份 db.sqlite3。包含 SQLite/WAL/SHM、附件、Send 文件、config.json、RSA 密钥等（存在时）。备份期间 Vaultwarden 会短暂停止；生成加密快照后立即尝试启动，再执行 GitHub 上传。

自动备份使用 age 公钥，不要求 age 私钥长期存放在 VPS。若私钥仅离线保存，自动任务不会声称进行了实际解密验证。应定期使用菜单 8 或 18，临时提供原 age 私钥，执行 SHA256、age 实际解密、tar 清单和 SQLite quick_check。

每次备份还会生成单独加密的脱敏部署清单，记录镜像、挂载、端口、网络及白名单非敏感环境变量。秘密变量只记录名称，不保存值。灾难恢复时可用菜单 17 查看清单。

恢复安全
--------
恢复前先将当前 /data 加密保存为本地 pre-restore 回滚快照，然后才替换挂载目录内部文件。恢复后等待容器达到 running/healthy；失败时尝试回滚。恢复完成后还需人工登录验证用户、密码库、附件、TOTP 和客户端同步。确认成功之前不要删除回滚快照。

安全说明
--------
- 源码仓库与 Vaultwarden 加密备份仓库必须分开。备份仓库必须为 GitHub Private。
- age 公钥可以放入 VPS 配置；AGE-SECRET-KEY-1 私钥离线保存至少两份。私钥丢失将无法解密备份。
- GitHub SSH Deploy Key 用于访问仓库，age 密钥用于数据加密，二者不可混淆。
- 不要提交真实配置、Token、SSH 私钥、age 私钥、数据库、附件或 .age 备份到源码仓库。
- 仅支持 SQLite 和容器内 /data 挂载；不支持 MySQL/PostgreSQL。
- 单文件默认限制 90 MiB；当前项目不集成 Restic/S3，也不使用多 age 密钥。Git 删除文件不会清除历史提交中的旧对象，需留意仓库体积。

文件说明
--------
- vw-manager.sh：交互菜单、系统定时任务、通知、恢复、历史管理等。
- vw-common.sh：容器动态发现、配置保存、通知与格式化。
- vw-backup.sh：systemd 和手动调用的非交互备份工作器。
- vw-restore-prepare.sh：SHA256、age 解密、tar 安全检查和 SQLite 暂存验证。
- vw-manifest.py：创建脱敏部署清单。
- vw-diagnose.sh：输出不包含密钥值的系统诊断报告。
- backup.conf.example：配置字段说明。
