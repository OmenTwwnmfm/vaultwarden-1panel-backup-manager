Vaultwarden（1Panel 应用商店版）交互式备份与恢复脚本包
========================================================

适用环境
--------
- Ubuntu / Debian VPS。
- Docker 已由 1Panel 安装和管理。
- Vaultwarden 已从 1Panel 应用商店安装为 Docker 应用。
- Vaultwarden 使用 SQLite，容器内数据目录为 /data。
- 当前用户具有 root 权限，或可以通过 sudo 管理 Docker。

本项目不会安装 Docker、安装 Vaultwarden、配置域名、HTTPS、反向代理或 Cloudflare。以上仍由 1Panel 管理。

推荐入口：项目根目录的 run.sh
--------------------------------
本脚本包优先使用交互式管理器，不要求新手手动输入容器名称或猜测数据目录。

从 GitHub 克隆完整项目后，在项目根目录运行：

  sudo bash ./run.sh

run.sh 会检查项目文件并启动 scripts/vw-manager.sh。不要只下载 run.sh 或 vw-manager.sh 单个文件。

如果当前终端已经是 root，可以省略 sudo。

菜单：
  1) 首次配置 / 重新检测容器与数据目录
  2) 立即备份当前数据并推送 GitHub
  3) 从 GitHub 选择备份并恢复数据
  4) 检查当前环境和备份配置
  5) 查看最近备份日志
  6) 查看 1Panel 每日 05:20 计划任务设置
  0) 退出

菜单 1 会扫描 Vaultwarden 容器，使用 docker inspect 获取容器内 /data 对应的主机 Source 路径，确认其中存在 db.sqlite3，再引导配置 GitHub Deploy Key 和 age 公钥，生成权限为 600 的配置文件，并安装脚本。

菜单 2 会显示目标容器和主机数据目录。确认后短暂停止容器，对整个 /data 目录打包并直接使用 age 公钥加密；加密快照完成后立即启动容器，再把密文与 SHA256 文件推送到 GitHub Private 仓库。

菜单 3 会从 GitHub 克隆备份仓库，列出当前分支可见的备份，选择后校验 SHA256、验证 age 私钥匹配、解密到暂存目录，再检测目标容器与 /data 路径。恢复前会显示加密回滚快照路径，必须输入大写 YES 才会替换数据。为兼容 Docker bind mount 和命名卷，脚本保留 /data 挂载点本身，只替换内部内容；恢复前的当前数据先用 age 公钥加密保存。复制失败时脚本使用你提供的原 age 私钥尝试回滚；自动回滚失败则保持容器停止。

菜单 4 检查容器、数据目录、SQLite 文件、磁盘空间、age 公钥和 GitHub SSH 连接。
菜单 5 查看最近备份日志。
菜单 6 显示 1Panel 计划任务设置方式。

安全提示
--------
- GitHub 源码仓库与 GitHub 加密备份仓库必须分开。
- age 公钥可以放在服务器配置中；age 私钥必须离线保存至少两份并验证可读。初次生成时私钥会暂时留在 VPS，确认离线副本安全后建议从 VPS 删除；恢复时再临时复制回来。私钥不能提交 GitHub。
- GitHub SSH Deploy Key 与 age 密钥是两套完全不同的密钥。
- 恢复时必须使用原 age 私钥。新 VPS 不能新生成一把 age 私钥来替代旧密钥。
- 恢复前当前 /data 会先生成 age 加密回滚快照，文件位于 BACKUP_DIR/pre-restore-*.tar.gz.age，并有对应 SHA256。确认恢复成功以前不要删除该快照。
- Vaultwarden 主密码、用户登录两步验证设备和恢复码并不会由服务器备份替代。

文件说明
--------
- vw-manager.sh：交互式菜单管理器，负责检测、配置、立即备份、GitHub 恢复、检查和日志。
- vw-backup.sh：底层备份脚本；1Panel 定时任务每天 05:20 调用它。
- vw-restore-prepare.sh：底层解密和暂存脚本，不会自行覆盖应用数据目录。
- backup.conf.example：手动部署/高级排错使用的配置模板；正常使用由管理器生成 /etc/vaultwarden-backup.conf。
- 1Panel-Vaultwarden-信息记录模板.txt：记录应用版本、域名和必要非敏感参数。

每天 05:20 自动执行
------------------
在 1Panel → 计划任务中新建 Shell 脚本任务：
- Cron：20 5 * * *
- 脚本：bash /usr/local/sbin/vw-backup.sh
- 用户：root 或具有 Docker 管理权限的用户

只设置一处定时任务，不要再重复添加 crontab。日志：

  tail -n 100 /var/log/vaultwarden-backup.log

限制与边界
----------
- 仅支持 SQLite，且容器内数据挂载目标为 /data；不支持 MySQL/PostgreSQL。
- 备份时会短暂停止 Vaultwarden；加密快照生成后立即启动，GitHub 上传在服务启动后进行。
- GitHub 普通 Git 文件限制为 100 MB；脚本默认单份密文限制为 90 MiB。大附件建议使用 Restic/Rustic 和对象存储。
- 删除当前分支目录中的旧备份不会清除 Git 历史对象，仓库可能持续增长。
- 脚本备份 /data，不包括 1Panel 应用编排、容器镜像、环境变量、域名和证书。请单独记录恢复所需的非敏感部署参数。
- 首次正式依赖前必须完成一次真实恢复演练。
