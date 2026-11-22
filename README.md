<div align="center">

# Vaultwarden 1Panel Backup Manager

**交互式备份 · age 加密 · GitHub / WebDAV 异地备份 · 灾难恢复 · systemd 自动运维**

面向 Ubuntu / Debian 上通过 1Panel 应用商店安装的 Vaultwarden（SQLite）

![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-blue)
![Panel](https://img.shields.io/badge/panel-1Panel-1677ff)
![Encryption](https://img.shields.io/badge/encryption-age-16a34a)
![Scheduler](https://img.shields.io/badge/scheduler-systemd-6d28d9)
![Version](https://img.shields.io/badge/version-1.5.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)

</div>

---

## 项目简介

Vaultwarden 将用户密码库保存在自己的服务器上，因此需要可靠的异地备份和可验证的恢复流程。本项目提供一个面向 1Panel 应用商店版 Vaultwarden 的交互式运维管理器，帮助管理员发现正确的 Docker 容器和 `/data` 主机挂载目录，将完整数据目录加密后同步到独立的 GitHub Private 仓库或 WebDAV 专用目录，并在需要时从历史备份恢复。

项目重点不是再部署一套 Vaultwarden，而是保护已经由 1Panel 管理的现有实例。1Panel 继续负责应用安装、Docker、域名、HTTPS 证书和反向代理；本项目负责数据备份、校验、通知、历史管理和灾难恢复。

> **源码仓库与备份存储必须分离。** 本仓库仅放项目代码和文档。GitHub 备份目标须使用独立 Private 仓库，WebDAV 须使用专用目录。不要把数据库、附件、age 私钥、SSH 私钥、WebDAV 凭据、真实配置或其他秘密提交到源码仓库。

## 操作确认输入

所有需要输入 `YES` 的风险确认均已统一为大小写不敏感：输入 `yes`、`YES` 或 `Yes` 都可以继续；其他输入均取消。不会因为大小写不同而误取消操作。

## 功能特点

### v1.5.0 升级说明

菜单 `[01]`–`[23]` 沿用 v1.4.8。升级后运行 `[22]` 同步后台脚本，在 `[03]` 初始化独立的备份签名密钥，并把 `/etc/vaultwarden-backup-signing/allowed_signers` 留存到离线介质。

- 新备份和部署清单各带 `.sha256.sig`。恢复、解密验证和读取清单会验签。已知来源的无签名旧备份可以逐次输入 `UNSIGNED` 继续。
- 本地自动清理前核对远端副本。菜单 `[10]` 删除 GitHub 文件后保留本地备份，可用 `[11]` 单独清理。
- `PRIMARY_TARGET` 和可选的 `SECONDARY_TARGET` 共用一次快照。上传失败的目标进入待补传队列，下一次运行会尝试补传。
- `vbm status` 显示快照、远端核验和演练记录。菜单 `[23]` 跟踪源码仓库的 `main` 分支。

### 菜单结构

主菜单分为六类。`[02]` 可选择手动备份目标，`[14]` 设置定时备份目标、频率和时间。顶部摘要分别显示定时目标、定时器状态和最近一次备份结果。

完整显示顺序见 [`docs/完整使用手册.md`](docs/完整使用手册.md) 的“主菜单分组”章节。

### 本地备份与 WebDAV

| 菜单 | 操作 |
|---|---|
| `[05]` / `[08]` | 验证备份或恢复生产数据，可选择本地、GitHub 或 WebDAV |
| `[10]` | 管理历史备份，WebDAV 支持按组编号删除 |
| `[11]` | 查看本地备份及 `.keep` 保护，确认后按组删除 |
| `[12]` | 配置 WebDAV 专用目录与凭据 |
| `[13]` | 将已有本地密文上传或补传到 WebDAV |

WebDAV 支持独立配置。首次向导 `[01]` 可选择 `webdav`，已有 GitHub 配置可通过 `[12]` 添加 WebDAV。手动备份在 `[02]` 选择目标。定时任务和 `[19]` 升级前备份使用 `[14]` 保存的 `BACKUP_TARGET`。

WebDAV 使用已有 age 公钥加密完整 `/data` 和部署清单。备份只写入填写目录下独立的 `vbm/` 子目录；若 URL 已以 `vbm/` 结尾则直接使用该目录，不会再嵌套一层。该目录可在有父级写权限时由 WebDAV 自动创建。服务器应支持 `PROPFIND`、`MKCOL`、`GET`、`PUT`、`MOVE`、`DELETE`，并使用 HTTPS。支持用户名与密码或应用密码，凭据单独保存于 root 所有、权限 `600` 的 `/etc/vaultwarden-webdav.json`。上传先生成临时文件，回读并计算 SHA256 后用 `MOVE` 发布，SHA256 文件最后发布。同名同内容可重复补传，同名不同内容会停止。上传成功要求再次回读核验。

本地默认目录为 `/var/backups/vaultwarden`。`vw-*.tar.gz.age` 是常规数据备份，`pre-restore-*.tar.gz.age` 是恢复前数据快照，`.manifest.json.age` 是加密部署清单。`.sha256` 和 `.sha256.sig` 分别保存校验值和签名。可在 `[11]` 清理本地副本。

本地删除持有备份共用锁，检查保护标记、目录重叠并要求确认。过期清理保留 `pre-restore-*`、`.keep` 和待补传的备份组，并在删除前核验完整副本。WebDAV 远端保留可在 `[21]` 配置，默认关闭。

### 性能监控与执行耗时分析

- **阶段级计时**：备份分别记录容器发现、部署清单生成、容器停止、SQLite `quick_check`、完整 `/data` 快照与 age 加密、Docker 启动命令、启动后健康检查等待、本地校验、GitHub 同步/推送/远端核验；恢复分别记录容器停止、恢复前回滚快照、生产数据替换、Docker 启动命令和健康检查等待。
- **停机与交互计时**：恢复总耗时扣除记录到的人工提示等待；另记录从停止服务到确认就绪的 `SERVICE_DOWNTIME` 汇总窗口，避免将最后按 Enter 的等待误读成恢复处理时间。
- **恢复过程计时**：记录 GitHub 获取、解密与校验、恢复目标检查、恢复前停止容器、回滚快照加密/验证、生产数据替换、Docker 启动命令、健康检查等待及失败回滚步骤。
- **历史趋势**：汇总最近 20 次操作，按最近 30 次操作计算各阶段平均耗时与最大耗时，帮助判断瓶颈是在 VPS 磁盘/CPU 还是 GitHub 网络。
- **CSV 导出**：可将性能历史导出为 CSV，便于用 Excel 分析。
- **隐私保护**：性能记录只包含时间、操作类型、运行 ID、阶段、耗时、状态和字节数，不保存密码、Token、私钥或数据库内容。
- 性能记录保存在 `/var/lib/vaultwarden-backup/performance.tsv`，仅 root 可读取。源码更新后可通过 `[22]` 同步 systemd 使用的后台脚本。健康探测汇总行与细分阶段分别记录。
- **瓶颈定位**：性能摘要会显示最近一次运行的阶段耗时占比与最大耗时阶段。若 `启动后健康检查等待` 很高，说明时间花在容器启动后的 Docker Healthcheck 等待，而不是 tar/age；请结合 `docker inspect` 的 Healthcheck 配置与历史状态判断，不要为了速度直接跳过健康检查。


### 全局快捷命令

- 每次通过 `sudo bash ./run.sh` 启动时，启动器都会自动安装或修复 `/usr/local/bin/vbm`；不依赖首次配置向导或手动执行某个菜单。
- 之后在任意目录执行 `vbm` 即可进入交互式管理菜单；普通用户执行时会通过 sudo 请求管理员权限。
- 如果旧版本提示 `vbm: command not found`，进入项目目录执行一次 `sudo bash ./run.sh` 即可触发自修复，然后执行 `hash -r` 再运行 `vbm`。
- `vbm` 指向当初克隆的项目目录。项目目录不要随意移动或删除。

### 自动备份与完整性

- **自动发现容器**：每次备份重新扫描 Docker，不依赖 1Panel 生成的固定容器名后缀。
- **数据路径身份保护**：以已确认的 `/data` 主机挂载路径作为实例身份；如果路径消失、改变或出现多个候选实例，安全停止而不是猜测。
- **一致性快照**：备份窗口内短暂停止 Vaultwarden，打包整个 `/data`，包括 SQLite 数据库及其 WAL/SHM 文件（如存在）、附件、Send 文件、配置、RSA 密钥等；加密归档创建后立即尝试重启服务，网络上传在服务恢复后进行。
- **SQLite 检查**：备份停止容器后执行 `PRAGMA quick_check`；恢复必须安装 `sqlite3` 并在覆盖生产数据前再次通过完整性检查。
- **age 公钥加密**：服务器日常备份只需 age 公钥；age 私钥建议离线保存，不需要长期放在 VPS。
- **可选本地解密验证**：若 VPS 配置了匹配私钥，仅在 `/dev/shm` 确认为 tmpfs 且空间足够时验证解密归档和 SQLite；否则跳过，不把明文数据目录写入持久磁盘。私钥仍建议离线保存。
- **SHA256 与远端核验**：校验本地文件，GitHub 推送后比较本地与远端分支提交 ID，WebDAV 上传后回读并比较每个文件的 SHA256。
- **本次运行结果**：每次运行有独立 ID 和阶段结果文件；锁冲突以退出码 `75` 明确标记跳过。升级前保护只接受本次的本地校验、服务恢复和远端核验成功结果。
- **空间预检与快照保留**：在数据盘、备份目录、Git 工作目录和临时目录检查可用空间；加密快照完整生成后即保留，后续容器启动、健康探测或远端上传失败不会删除密文。
- **GitHub 推送重试**：GitHub 遇到临时网络错误时按配置重试；不会使用 `--force` 覆盖远程历史。WebDAV 使用临时文件、禁止覆盖发布和回读校验。
- **主动健康探测与磁盘阈值**：备份前检查剩余磁盘空间。容器启动后，若 Docker Healthcheck 配置为 Vaultwarden 官方 `/healthcheck.sh`，管理器会在容器内每 2 秒主动执行同一个探针，连续 2 次成功即确认应用就绪，最长等待 120 秒，单次探测另有 12 秒超时保护；不修改 1Panel 管理的 Docker Healthcheck。非标准镜像回退到 Docker 原生状态轮询。

### 自动化运维（不依赖 1Panel 计划任务）

- **systemd timer**：由 Ubuntu / Debian 系统本身调度，支持每天、每周日或每月 1 日运行；默认每天按 VPS 本地时区 05:20 备份。
- **错过任务补执行**：使用 `Persistent=true`，机器关机错过计划后可在下次启动时补执行。
- **成功/失败通知**：支持 Telegram、ntfy 或通用 Webhook；通知发送失败不会改变备份结果。
- **日志轮转**：安装 logrotate 配置，避免备份日志无限增长。
- **升级前保护**：在 1Panel 更新 Vaultwarden 前，先自动执行一份完整备份并核验当前目标远端数据。
- **诊断报告**：生成脱敏的系统、Docker、数据路径、磁盘、定时器和备份日志报告。

### 恢复与维护

- **交互式恢复**：从 GitHub、本地目录或 WebDAV 选择历史备份，检查 SHA256、age 私钥匹配、tar 清单和 SQLite 数据库，再进入恢复步骤。
- **恢复前回滚**：替换生产数据之前，先把当前 `/data` 加密保存为本地回滚快照；失败时尝试自动回滚。
- **恢复目标保护**：生产数据覆盖及回滚前，按已确认的 `/data` 主机路径重新确认唯一容器并验证已停止；不明状态或容器身份变化时中止。
- **归档与数据库校验**：解压前拒绝路径穿越、符号/硬链接、特殊文件、重复路径和 setuid/setgid 条目；正式恢复必须通过 SQLite `quick_check`，并预检暂存分区空间。
- **恢复后健康检查**：启动容器后优先主动执行 Vaultwarden `/healthcheck.sh`，每 2 秒探测一次、连续两次成功后立即继续；单次探测有 12 秒超时、总等待上限 120 秒。未通过时仍按安全策略尝试回滚到恢复前快照。
- **恢复演练**：在临时目录解密并检查历史备份，不修改生产数据。
- **历史备份管理**：列出 GitHub 当前分支中的备份，支持永久保留标记、取消标记和删除当前分支文件；自动过期清理会跳过已保护备份，并明确提醒 Git 历史仍可能保留旧对象。
- **部署清单**：每次备份生成一份经过脱敏的 1Panel/Docker 部署清单，并用同一 age 公钥加密；可在灾难恢复时查看。
- **二次确认**：停止服务、覆盖生产数据、删除历史备份、暂停定时器等危险操作均要求显式确认。

## 适用环境与边界

| 项目 | 要求 |
|---|---|
| 操作系统 | Ubuntu / Debian（使用 systemd） |
| 面板 | 1Panel 已安装并正常运行 |
| Vaultwarden | 通过 1Panel 应用商店安装的 Docker 版本 |
| 数据库 | SQLite |
| 容器数据路径 | 容器内 `/data` 挂载到 VPS 主机目录 |
| 权限 | root，或可通过 sudo 管理 Docker、systemd 和系统目录 |
| 远端 | 独立 GitHub Private 备份仓库或 WebDAV HTTPS 专用目录 |

**不支持** MySQL/PostgreSQL 外部数据库、容器内非 `/data` 的自定义数据布局、非 systemd Linux 发行版。项目不安装或升级 Docker/1Panel/Vaultwarden，不配置域名、HTTPS 或反向代理，也不会自动执行 Vaultwarden 版本升级。

本项目针对普通个人/小型实例，提供 GitHub Private 和 WebDAV 两种独立异地存储目标，不包含多 age 密钥、Restic 或 S3 兼容对象存储。单个 GitHub 普通 Git 文件默认限制为 90 MiB。删除当前分支文件不会自动清除 Git 历史对象；需定期关注仓库体积。

## 项目结构

```text
Vaultwarden_1Panel_GitHub_Project/
├── README.md
├── CHANGELOG.md
├── LICENSE
├── .gitignore
├── run.sh
├── logrotate-vaultwarden-backup
├── scripts/
│   ├── vw-manager.sh                 # 交互式管理器
│   ├── vw-common.sh                 # 容器发现、配置保存、通知等公共函数
│   ├── vw-backup.sh                 # systemd / 手动调用的非交互备份工作器
│   ├── vw-restore-prepare.sh        # 校验、解密、暂存及 SQLite 检查
│   ├── vw-archive-check.py          # 解压前的 tar 路径/文件类型安全检查
│   ├── vw-manifest.py               # 生成已脱敏的部署清单
│   ├── vw-diagnose.sh               # 生成脱敏诊断报告
│   ├── vw-performance.py            # 性能历史汇总、明细与 CSV 导出
│   ├── vw-storage.py                # 本地备份分组、删除保护和 WebDAV 传输
│   ├── vbm-launcher.sh              # 全局 vbm 命令安装模板
│   └── backup.conf.example          # 配置字段参考
└── docs/
    ├── 快速开始.md
    ├── 完整使用手册.md
    └── 部署信息记录模板.md
```

## 快速开始

### 1. 准备两个独立的 GitHub 仓库

| 仓库 | 可见性 | 用途 |
|---|---|---|
| 本项目源码仓库 | **Public** | README、脚本、文档；任何人均可匿名 HTTPS 克隆 |
| Vaultwarden 备份仓库 | **Private** | 仅保存 age 加密备份、清单和 SHA256 文件 |

建议备份仓库保持空仓库，不要先添加 README、License 或 `.gitignore`。管理器首次配置时会初始化或克隆它。

### 2. 在 VPS 克隆源码

在 SSH 终端执行（将 URL 替换成实际源码仓库地址）：

```bash
sudo apt update
sudo apt install -y git
sudo git clone https://github.com/OmenTwwnmfm/vaultwarden-1panel-backup-manager.git /opt/vaultwarden-1panel-backup-manager
cd /opt/vaultwarden-1panel-backup-manager
sudo bash ./run.sh
```

每次通过 `sudo bash ./run.sh` 启动时，启动器都会自动安装或修复全局命令 `/usr/local/bin/vbm`。之后在 VPS 任意目录执行 `vbm` 即可进入菜单。

本项目源码仓库为 Public，任何人都可以通过 HTTPS 克隆，不需要 GitHub 账号、SSH 密钥或 Token。只有独立的数据备份仓库必须保持 Private。推荐安装到 `/opt` 下 root 所有且不可被其他用户修改的项目目录；启动器会拒绝从普通用户可写路径以 root 运行。首次配置需要交互式终端，不要通过 systemd 或后台脚本启动配置向导。

### 3. 首次配置

在主菜单选择 **1「首次配置 / 重新检测容器与数据目录」**。向导将：

1. 检查 Docker 是否可用；不会重新安装 Docker。
2. 扫描 Vaultwarden 候选容器；多个候选项会要求你选择。
3. 通过 `docker inspect` 自动读取容器内 `/data` 对应的主机路径，并确认其中有非空 `db.sqlite3`。
4. 检查并按需安装 `age`、`git`、`openssh-client`、`sqlite3`、`python3`、`logrotate` 等工具。
5. 创建 GitHub 专用 SSH Deploy Key。将显示的 `.pub` 公钥添加到备份仓库的 **Settings → Deploy keys**，并勾选 **Allow write access**。
6. 输入现有 age 公钥，或在首次部署时生成一套新的 age 密钥。若你已有历史备份，必须沿用原公钥，不能新生成密钥替代。
7. 设置本地备份目录和保留天数，GitHub 目标另配置 Git 工作目录，核对目标容器与数据路径后输入 `yes` 确认（不区分大小写，`yes` / `YES` / `Yes` 均可）。

age 私钥必须复制到至少两份离线安全位置并验证可读。日常备份只需要公钥，不需要把私钥长期放在 VPS。

### 4. 首次手动备份

选择 `[02]` 后选择 GitHub 或 WebDAV，核对容器和数据路径并输入 `yes`。备份成功后，所选目标中会出现以下文件。

```text
vw-YYYYMMDD-HHMMSS.tar.gz.age
vw-YYYYMMDD-HHMMSS.tar.gz.age.sha256
vw-YYYYMMDD-HHMMSS.manifest.json.age
vw-YYYYMMDD-HHMMSS.manifest.json.age.sha256
```

部署清单只保留镜像、挂载、端口、网络和经允许的非敏感参数；秘密环境变量只记录变量名，不保存具体值。清单本身也会 age 加密。

## systemd 自动备份（不依赖 1Panel）

首次手动备份验证成功后，在 `[14]` 选择定时备份目标、频率和执行时间。默认每天 VPS 本地时间 05:20。

管理器会安装：

- `/etc/systemd/system/vw-backup.service`
- `/etc/systemd/system/vw-backup.timer`
- `/etc/logrotate.d/vaultwarden-backup`

Timer 使用 `Persistent=true`。若 VPS 关机错过计划，下一次启动时 systemd 会补执行一次。若你此前在 1Panel 或 crontab 配置了相同的计划任务，应停用旧任务，避免重复执行。

常用命令：

```bash
# 查看下一次执行时间和 timer 状态
systemctl list-timers --all | grep vw-backup
systemctl status vw-backup.timer

# 手动触发一次后台备份
systemctl start vw-backup.service

# 查看最近服务执行记录
journalctl -u vw-backup.service -n 100 --no-pager

# 查看脚本详细日志
tail -n 100 /var/log/vaultwarden-backup.log
```

自动备份菜单为 `[14]` 安装或修改、`[15]` 查看状态、`[16]` 暂停、`[17]` 恢复。

## 管理器菜单

菜单分为六类；完整序号见 [`docs/完整使用手册.md`](docs/完整使用手册.md) 第 5 节。`[02]` 选择 GitHub/WebDAV；`[05]`、`[06]`、`[08]`、`[09]`、`[10]` 选择 GitHub/本地/WebDAV 来源。

输入 `00` 或 `0` 退出。使用 `[07]` 查看最近运行、阶段平均与最大耗时、指定运行详情，或导出 CSV。详见[完整使用手册](docs/完整使用手册.md)。

## 通知配置

菜单 `[18]` 支持 Telegram、ntfy 和 Webhook。

- **Telegram**：Bot Token + Chat ID。
- **ntfy**：Topic URL，可选 Access Token。
- **Webhook**：向指定 URL 发送 JSON 事件。

通知配置保存在 root 专用的 `/etc/vaultwarden-backup.conf`（权限 600）。成功通知和失败通知可以分别开关。通知网络失败不会把已经成功的备份改判为失败。

## 备份完整性与恢复演练

备份工作器检查容器、`/data`、可用空间、SQLite、归档和密文 SHA256，并核验 GitHub 远端提交或 WebDAV 回读哈希。在 `[05]` 临时提供原 age 私钥可执行解密和 SQLite 校验。在 `[09]` 可用无网络、无端口映射的临时容器演练恢复并检查能否启动。

恢复流程在正式覆盖数据前会先解密到暂存目录、检查数据库，并加密保存当前生产数据为 `pre-restore-*.tar.gz.age` 回滚快照。恢复后会等待容器达到 running/healthy；健康检查失败时会尝试回滚。即使工具报告恢复成功，也必须人工登录原账户检查密码库、附件、TOTP 和客户端同步。确认前不要删除回滚快照。

## 升级前保护与部署清单

- 在 1Panel 更新 Vaultwarden 前，使用菜单 `[19]` 创建并验证升级前备份。只有完整备份和当前目标远端校验成功，才建议继续升级。
- 本项目不会自动升级 Vaultwarden，升级动作仍由 1Panel 完成。
- 每次备份会记录一份脱敏部署清单。发生 VPS 损坏时，可用菜单 `[06]` 选择并解密清单，参考原镜像版本、挂载、端口、网络和非敏感环境设置，在新 VPS 的 1Panel 中手动重建应用。
- SMTP 密码、Admin Token、Webhook Token 等秘密值不会进入部署清单；必须从你自己的密码管理或安全记录中恢复。

## 历史备份管理与 GitHub 容量

在菜单 `[10]` 选择 GitHub，可以查看当前分支的加密备份并删除选定的备份组。**删除当前分支文件后，Git 历史仍会保留旧对象**，因此仓库容量仍可能增长。

普通 GitHub 仓库对单个 Git 文件有 100 MiB 限制，项目默认将单文件上限设为 90 MiB。此项目针对小型 Vaultwarden 实例，不集成 Restic、S3 或多 age 密钥方案。

## 新 VPS 灾难恢复概要

1. 在新 VPS 上通过 1Panel 安装好兼容版本的 Vaultwarden 应用；不要创建新用户。
2. 配置好原域名、HTTPS 和必要的 1Panel 应用参数。
3. 从 GitHub 取得项目源码，运行管理器菜单 1；目标应是新应用的 `/data` 主机挂载路径，但 age 公钥必须填写旧备份使用的原公钥。
4. 为新 VPS 创建新的 GitHub Deploy Key，并给备份仓库写权限；旧 VPS 已销毁时可以移除旧 Deploy Key。
5. 将离线保存的原 age 私钥临时复制到新 VPS，运行菜单 `[08]` 选择旧备份恢复。恢复完成并确认成功后，安全删除 VPS 上临时私钥副本。
6. 用原用户主密码登录并检查数据。随后在菜单 `[14]` 启用新 VPS 的 systemd timer，并手动备份一次确认上传成功。

每位用户仍需自己的 Vaultwarden 主密码和登录两步验证设备/恢复码。服务器备份保存的是密码库数据，不会恢复用户主密码明文，也不能代替个人保存的 MFA 恢复码。

## 常见问题

**1Panel 更新后容器名称变了怎么办？** 备份前会重新发现容器，并按原先已确认的 `/data` 主机路径匹配。若匹配唯一则更新容器名；若找不到原路径或发现多个候选项会停止，需运行菜单 1 重新确认。

**备份显示 0 MiB 是否为空？** 旧版会将小文件按整数 MiB 显示。可在 `[05]` 使用原 age 私钥验证，或用 `[09]` 演练恢复。

**VPS 错过 05:20 备份怎么办？** systemd timer 使用 `Persistent=true`，下次开机时会补执行错过的触发时间。可通过 `systemctl list-timers --all` 查看计划。

**GitHub 或 WebDAV 上传失败怎么办？** GitHub 工作器会按配置重试，失败密文保留在本地备份目录，可从菜单 `[13]` 补传 WebDAV。查看 `/var/log/vaultwarden-backup.log`，检查凭据、网络和远端容量。

**可以只备份 db.sqlite3 吗？** 不建议。附件和 Send 文件位于文件系统中，必须备份整个 `/data`。

**忘记用户主密码能否通过备份找回？** 不能。Vaultwarden 的数据库保存的是用户密码库加密数据，用户主密码不会以可恢复的明文存储。

## 安全声明

- GitHub 源码仓库与备份仓库必须分开。
- age 私钥必须离线保存；私钥丢失后，加密备份无法恢复。
- 管理器需要从 root 所有且不可由普通用户修改的项目目录运行；推荐按照快速开始安装到 `/opt`，不要从普通用户可写的目录以 root 启动。
- GitHub SSH Deploy Key 与 age 密钥用途不同；SSH 密钥泄露不等于可以解密 age 备份，但可能允许访问仓库。
- 不要将真实 `/etc/vaultwarden-backup.conf`、私钥、Token、数据库、附件或 `.age` 文件提交到源码仓库。
- 恢复操作具有破坏性，必须逐项核对实例和路径；测试环境演练优先于直接在生产环境首次恢复。
- 请自行评估 GitHub、VPS 和通知服务的隐私及可用性风险。本项目不构成安全审计或数据可用性保证。

## 贡献

欢迎提交 Issue 或 Pull Request。涉及备份、加密、恢复和容器启停的修改，请同时提供：Bash 语法检查、模拟 Docker/Git/age 测试结果，以及对生产数据安全边界的说明。不要在 Issue 中上传真实数据库、加密备份、私钥或日志中的 Token。

## 文档

- [快速开始](docs/快速开始.md)
- [完整使用手册](docs/完整使用手册.md)
- [部署信息记录模板](docs/部署信息记录模板.md)

## 性能数据

性能模块使用 `/var/lib/vaultwarden-backup/performance.tsv` 保存阶段耗时。菜单 `[07]` 可查看摘要、按运行 ID 查看阶段明细，或导出 CSV。

## License

MIT License。详见仓库中的 `LICENSE`。

## 全局命令 `vbm` 与启动更新检查

通过 `sudo bash ./run.sh` 启动管理器时，程序会自动安装或修复 `/usr/local/bin/vbm`。完成首次配置或后台脚本更新后，也可以在任意目录执行：

```bash
vbm
```

如果此前显示 `Command 'vbm' not found`，进入项目目录重新运行 `sudo bash ./run.sh` 即可触发自修复；若 `/usr/local/bin` 不在系统 PATH 中，脚本会在适用时创建 `/usr/bin/vbm` 兼容入口。

交互式启动或选择 `[23]` 时会检查源码仓库的 `main` 分支。工作区干净、目标版本有效且可快进时，输入 `yes` 即可更新源码并同步后台脚本。

### 性能记录为空时怎么办？

如果 `[07]` 显示没有性能记录，更新源码后用 `[22]` 同步后台脚本，再执行一次 `[02]` 手动备份，并在 `[04]` 检查日志中的 `[性能]` 和 `[耗时]` 行。
