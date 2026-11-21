<div align="center">

# Vaultwarden 1Panel Backup Manager

**面向 1Panel 应用商店版 Vaultwarden 的交互式备份、GitHub 加密同步与恢复工具**

让 Vaultwarden 的数据备份和迁移更容易操作：自动识别容器与数据目录，按向导完成配置，并通过菜单执行备份、检查和恢复。

[功能介绍](#功能特点) · [适用环境](#适用环境) · [快速开始](#快速开始) · [使用方式](#使用方式) · [安全说明](#安全说明) · [常见问题](#常见问题)

</div>

---

## 项目简介

如果你通过 **1Panel 应用商店**安装并运行 Vaultwarden，本项目可以帮助你备份其 SQLite 数据目录，并将加密后的备份同步到独立的 GitHub Private 仓库。

项目提供交互式 Shell 管理器。正常使用时，不必手动查找 Docker 容器名称、猜测 1Panel 的数据路径，也不必每次手动编辑配置文件。启动管理器后，按照屏幕提示选择操作即可。

本项目专注于 **Vaultwarden 数据备份与恢复**，不负责安装或配置 1Panel、Docker、Vaultwarden、域名、HTTPS 证书或反向代理。这些由用户现有的 1Panel 环境负责。

> **重要：项目源码仓库与备份数据仓库必须分开。** 本项目仓库用于发布脚本和文档；另建一个独立的 GitHub Private 仓库，仅保存 `.age` 加密备份。不要将真实数据库、附件、加密备份、私钥或真实配置提交到源码仓库。

## 功能特点

- **自动发现 Vaultwarden 容器**：扫描 Docker 容器，列出名称或镜像包含 `vaultwarden` 的候选项，并允许选择目标容器。
- **自动识别数据目录**：通过 `docker inspect` 查找容器内 `/data` 对应的主机挂载路径，并检查 SQLite 数据库文件是否存在。
- **完整备份 `/data`**：归档数据库、SQLite WAL/SHM 文件（如存在）、附件、Send 文件、配置和服务端密钥等数据，而不只是复制 `db.sqlite3`。
- **age 公钥加密**：备份在上传前加密；GitHub 备份仓库只保存密文和 SHA256 校验文件。
- **GitHub SSH 同步**：使用专用于备份仓库的 Deploy Key 推送备份，不需要在脚本中保存 GitHub 账户密码或 Personal Access Token。
- **交互式恢复**：从 GitHub 获取备份列表，选择历史版本，校验 SHA256、验证 age 私钥后解密到临时目录。
- **恢复前回滚保护**：替换数据前，先将当前 `/data` 加密保存为本地回滚快照；恢复失败时会尝试回滚。
- **危险操作二次确认**：备份、恢复等操作会显示目标容器和路径，并要求输入大写 `YES`。
- **适配 1Panel 计划任务**：可配置每天指定时间执行底层备份脚本。项目默认示例为每天 05:20（VPS 本地时间）。
- **检查与日志**：提供环境检查、备份日志查看和计划任务配置提示。

## 适用环境

| 项目 | 要求 |
|---|---|
| 操作系统 | Ubuntu / Debian |
| 面板 | 已安装并正常运行的 1Panel |
| 容器环境 | Docker 已由 1Panel 安装和管理 |
| Vaultwarden | 已从 1Panel 应用商店安装的 Docker 版本 |
| 数据库 | SQLite，数据位于容器内 `/data` |
| 权限 | root，或可通过 `sudo` 管理 Docker 和系统目录的用户 |
| 远端存储 | 一个独立的 GitHub Private 备份仓库 |

### 当前版本限制

- 当前仅支持 **SQLite** 版 Vaultwarden。不支持 MySQL、PostgreSQL 或其他外部数据库部署。
- Vaultwarden 容器必须将持久化数据挂载到容器内的 `/data`。如果实际挂载路径不同，本项目会停止，不会猜测或自动修改部署。
- 备份期间会短暂停止 Vaultwarden 容器。加密归档完成后，脚本会立即尝试重新启动容器；GitHub 上传在服务启动后进行。
- 单个备份文件默认限制为 90 MiB，以避开 GitHub 普通 Git 仓库的单文件大小限制。备份较大或附件持续增长时，建议使用 Restic / Rustic 和对象存储等专用备份方式。
- 清理当前分支中的旧备份文件不会自动清除 Git 历史中的旧对象，Git 仓库仍可能持续增长。请定期检查备份仓库容量。
- 本项目备份 Vaultwarden 的 `/data`，不备份 1Panel 应用编排、镜像版本、环境变量、站点配置、域名或证书。迁移时需另行记录必要的非敏感部署参数。

## 项目结构

```text
Vaultwarden_1Panel_GitHub_Project/
├── README.md
├── run.sh                         # 交互式管理器启动入口
├── .gitignore
├── scripts/
│   ├── vw-manager.sh              # 交互式管理器
│   ├── vw-backup.sh               # 底层备份脚本；供手动或计划任务调用
│   ├── vw-restore-prepare.sh      # 校验、解密并解压到临时目录
│   ├── backup.conf.example        # 手动配置参考模板
│   ├── 1Panel-Vaultwarden-信息记录模板.txt
│   └── README-先阅读.txt
└── docs/
    └── Vaultwarden_1Panel版_交互式备份恢复_新手交付手册.docx
```

## 快速开始

### 1. 准备 GitHub 仓库

建议创建两个独立仓库：

| 仓库 | 可见性 | 内容 |
|---|---|---|
| 项目源码仓库 | Public 或 Private | 本项目脚本、README 和文档 |
| Vaultwarden 备份仓库 | **Private** | 仅保存 `.age` 加密备份和校验文件 |

备份仓库建议创建为空仓库，不要预先添加 README、License 或 `.gitignore`。项目首次配置会初始化或克隆该仓库。

### 2. 在 VPS 下载项目

通过 SSH 登录已经运行 1Panel 和 Vaultwarden 的 Ubuntu / Debian VPS，执行：

```bash
sudo apt update
sudo apt install -y git
sudo git clone https://github.com/OmenTwwnmfm/vaultwarden-1panel-backup-manager.git /opt/vaultwarden-1panel-backup-manager
cd /opt/vaultwarden-1panel-backup-manager
sudo bash ./run.sh
```

如果你是从其他镜像或 Fork 仓库获取项目，请将 clone 地址替换为对应地址。若源码仓库为 Private，需要先配置该仓库的读取权限。

`run.sh` 会检查项目文件、确保以 root 权限运行，然后启动交互式管理器。请在 SSH 终端或 1Panel 终端中运行，不要通过非交互式后台任务启动首次配置向导。

### 3. 首次配置

在主菜单选择 `1`「首次配置 / 重新检测容器与数据目录」。管理器会依次：

1. 检查 Docker 命令是否可用；不会安装、升级或重装 Docker。
2. 列出名称或镜像包含 `vaultwarden` 的容器。如果有多个候选项，要求你选择正确的容器。
3. 通过 `docker inspect` 获取容器内 `/data` 对应的主机 `Source` 路径，并检查其中是否存在 `db.sqlite3`。
4. 检查备份所需工具；缺少 `age`、`git`、SSH 客户端等依赖时，会询问是否通过 APT 安装。不会修改 1Panel、Docker 或 Vaultwarden 的部署配置。
5. 引导配置 GitHub Private 备份仓库，并生成专用 SSH Deploy Key。将屏幕显示的 `.pub` 公钥添加到**备份仓库**的 `Settings → Deploy keys`，并勾选 `Allow write access`。
6. 让你输入已有 age 公钥，或生成新的 age 密钥对。
7. 配置本地备份目录、Git 工作目录和保留天数，生成权限受限的配置文件，并安装底层脚本。

配置向导会显示容器名称、镜像、数据目录和仓库地址。请仔细核对，只有确认无误后才输入大写 `YES` 继续。

### 4. 完成首次备份

首次配置成功后，返回主菜单选择 `4` 检查环境和配置，然后选择 `2` 执行一次手动备份并推送 GitHub。

确认备份仓库中出现 `vw-日期-时间.tar.gz.age` 和对应的 `.sha256` 文件后，再配置自动计划任务。

## 使用方式

启动管理器：

```bash
cd /opt/vaultwarden-1panel-backup-manager
sudo bash ./run.sh
```

主菜单：

```text
1) 首次配置 / 重新检测容器与数据目录
2) 立即备份当前数据并推送 GitHub
3) 从 GitHub 选择备份并恢复数据
4) 检查当前环境和备份配置
5) 查看最近备份日志
6) 查看 1Panel 每日 05:20 计划任务设置
0) 退出
```

### 立即备份

选择菜单 `2`。管理器显示即将操作的容器和 `/data` 主机目录，并提示备份期间服务会短暂不可用。输入大写 `YES` 后才会执行：

1. 停止指定的 Vaultwarden 容器。
2. 将完整 `/data` 目录打包，并通过 age 公钥直接加密输出，不在磁盘保留未加密的压缩归档。
3. 加密快照完成后立即尝试重新启动 Vaultwarden。
4. 生成 SHA256 校验文件。
5. 将加密备份同步到 GitHub Private 仓库。

### 从 GitHub 恢复

选择菜单 `3`。管理器将：

1. 通过 GitHub SSH 权限读取备份仓库并列出历史备份。
2. 让你选择需要恢复的备份文件。
3. 要求提供**生成该备份时对应的原 age 私钥**，并验证其公钥与当前配置相符。
4. 校验 SHA256，检查归档路径后解密到权限受限的临时目录。
5. 重新检测目标容器及其 `/data` 主机挂载目录。
6. 显示恢复目标和回滚文件位置；只有输入大写 `YES` 才会替换数据。
7. 停止目标容器，将当前 `/data` 先加密保存为本地回滚快照，再替换挂载目录内部内容。
8. 恢复完成后询问是否启动 Vaultwarden。

恢复后请使用原用户账号进行实际验证，包括登录、密码库条目、附件、TOTP 和客户端同步。确认恢复成功之前，不要删除本地 `pre-restore-*.tar.gz.age` 回滚快照。

### 配置每日自动备份

首次手动备份成功后，在 1Panel 中创建计划任务：

1. 进入 **1Panel → 计划任务 → 创建计划任务**。
2. 任务类型选择 **Shell 脚本**。
3. 执行周期选择自定义 Cron：

   ```cron
   20 5 * * *
   ```

4. 脚本内容填写：

   ```bash
   bash /usr/local/sbin/vw-backup.sh
   ```

5. 执行用户选择 `root`，或选择具有 Docker 管理权限的用户。
6. 保存后手动执行一次，检查计划任务执行结果和备份日志。

以上时间按 VPS 系统本地时区执行。请只配置一处定时任务，不要同时再添加相同的 crontab，以免重复备份。

查看日志：

```bash
sudo tail -n 100 /var/log/vaultwarden-backup.log
```

## 密钥与安全说明

本项目使用两套用途不同的密钥：

| 密钥 | 用途 | 应如何保存 |
|---|---|---|
| GitHub SSH Deploy Key | 允许 VPS 访问指定备份仓库 | 私钥留在 VPS 的 `/root/.ssh/`；公钥添加到备份仓库 Deploy Keys |
| age 密钥对 | 加密和解密备份 | 服务器配置只保存 `age1...` 公钥；`AGE-SECRET-KEY-1...` 私钥应离线保存 |

### age 私钥非常重要

- age 公钥用于加密，泄露公钥不会让别人解密已有备份。
- age 私钥用于解密。私钥丢失后，历史 `.age` 文件将无法恢复。
- 请将完整 age 私钥文件离线保存至少两份，并验证副本可读取。
- 不要把 age 私钥、SSH 私钥、Vaultwarden 主密码、Admin Token、SMTP 密码或真实配置文件上传到任何源码仓库或备份仓库。
- 新 VPS 恢复旧备份时，必须使用原来的 age 公钥配置和匹配的原私钥，不能新生成一把密钥替代。

### 其他安全注意事项

- GitHub 备份仓库务必设置为 **Private**。
- 不要将真实的 `backup.conf`、`/etc/vaultwarden-backup.conf`、数据库、附件目录或 `.age` 备份提交到项目源码仓库。
- 使用前先检查代码内容，了解脚本会停止哪个容器、读取哪个目录以及写入哪些路径。
- 恢复操作会替换目标 `/data` 内的内容。执行前确认容器和数据目录，且保留回滚快照。
- 服务器备份不能代替用户的 Vaultwarden 主密码，也不能替代用户的两步验证恢复码。

## 迁移到新 VPS

1. 在新 VPS 上安装并登录 1Panel。
2. 通过 1Panel 应用商店安装 Vaultwarden（建议先使用与原实例兼容的版本），不要创建真实用户或导入新数据。
3. 从本项目 GitHub 仓库下载项目，在新 VPS 运行 `sudo bash ./run.sh`。
4. 选择菜单 `1`，在 age 配置步骤选择使用**已有公钥**，输入原备份对应的 `age1...` 公钥。
5. 为新 VPS 生成新的 GitHub SSH Deploy Key，并将其添加到原来的 Private 备份仓库。需要继续每日上传备份时，勾选 `Allow write access`。
6. 选择菜单 `3`，从 GitHub 选择备份，并提供原 age 私钥文件。
7. 完成恢复后启动 Vaultwarden，使用原用户账号和主密码登录，检查密码库、附件、TOTP 和同步。
8. 重新配置新 VPS 的 1Panel 计划任务。

注意：本项目只恢复 Vaultwarden `/data`。域名、HTTPS 证书、1Panel 应用参数、SMTP 等部署设置需要在新 VPS 上另行配置。

## 常见问题

**找不到 Vaultwarden 容器？**

请先确认 Vaultwarden 已通过 1Panel 应用商店安装，并在 1Panel「已安装应用」中处于可管理状态。也可以在 VPS 执行 `docker ps -a` 查看容器名称和镜像名称。脚本只会把名称或镜像中包含 `vaultwarden` 的容器列为候选项。

**提示没有 `/data` 挂载或找不到 `db.sqlite3`？**

当前版本只支持容器内 `/data` 挂载并使用 SQLite 的部署。如果实际数据挂载到其他容器路径，或使用外部数据库，请不要绕过检查强行运行。

**GitHub 推送失败？**

检查备份仓库是否为 Private、SSH Deploy Key 是否添加到了正确仓库、是否勾选写入权限、仓库 SSH 地址和分支是否正确，以及 VPS 是否能连接 GitHub。

**恢复时提示 age 公钥不匹配？**

说明输入的私钥并非创建这些备份时使用的密钥。请从离线备份中找到原始 age 私钥；重新生成密钥不能解开旧备份。

**备份超过 90 MiB？**

脚本会保留本地加密文件但停止 GitHub 推送。请考虑使用 Restic / Rustic 和兼容 S3 的对象存储，不建议通过不断拆分 Git 文件来绕过 GitHub 仓库限制。

**恢复后无法登录？**

确认使用的是原用户邮箱和原主密码，并检查恢复的是否为正确日期的完整备份。服务器无法还原用户遗失的主密码；如果服务启动异常，请先查看 1Panel 应用日志，保留回滚快照，不要反复覆盖数据。

## 文档

更详细的新手操作说明见：

[`docs/Vaultwarden_1Panel版_交互式备份恢复_新手交付手册.docx`](docs/Vaultwarden_1Panel版_交互式备份恢复_新手交付手册.docx)

也可阅读：

- [`scripts/README-先阅读.txt`](scripts/README-先阅读.txt)
- [`scripts/1Panel-Vaultwarden-信息记录模板.txt`](scripts/1Panel-Vaultwarden-信息记录模板.txt)

## 测试状态与免责声明

本项目脚本已进行 Bash 语法检查，并在模拟环境中检查过菜单及备份/恢复流程。模拟环境不等同于真实生产 VPS，也不能保证覆盖所有 1Panel 版本、Vaultwarden 镜像和 Docker 存储布局。首次使用前请先阅读脚本、检查配置，并在非关键实例或维护窗口中完成一次真实备份和恢复演练。

本项目按现状提供，不保证适用于所有自定义部署。使用者应自行确认数据目录、密钥保管和恢复结果，并在执行任何覆盖操作前保留可用的独立备份。

## 贡献与反馈

欢迎提交 Issue 或 Pull Request，建议在报告问题时提供：

- Ubuntu / Debian 版本；
- 1Panel 版本；
- Vaultwarden 镜像标签；
- 容器 `/data` 挂载类型（bind mount 或 volume）；
- 脱敏后的错误信息和相关日志。

**请勿提交数据库、附件、真实配置文件、域名管理凭据、GitHub Token、SSH 私钥或 age 私钥。**

---

<div align="center">

为自托管 Vaultwarden 用户提供一个更容易上手的备份与恢复流程。

</div>
