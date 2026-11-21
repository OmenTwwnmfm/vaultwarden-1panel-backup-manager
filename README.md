# Vaultwarden Backup & Restore for 1Panel

面向 **Ubuntu / Debian VPS + 1Panel + 1Panel 应用商店版 Vaultwarden（Docker）** 的自动备份与恢复工具包。

本项目不负责安装 Docker、不负责安装 Vaultwarden，也不负责配置域名、HTTPS 或反向代理。这些工作继续由 1Panel 管理。本项目只负责备份 Vaultwarden 容器挂载到 `/data` 的持久化数据，并将加密后的备份同步到 GitHub Private 仓库。

> **重要：本项目代码仓库和备份仓库必须分开。** 本仓库用于存放脚本、示例配置和文档；另建一个空的 GitHub Private 仓库专门存放 `.age` 加密备份。不要把真实密码库数据、`.age` 备份、age 私钥、SSH 私钥或真实配置文件提交到本项目仓库。

## 功能特点

- 适配通过 1Panel 应用商店安装的 Vaultwarden Docker 应用。
- 自动检查容器名称、SQLite 数据库以及容器 `/data` 挂载路径。
- 备份整个 `/data` 目录，而不只是 `db.sqlite3`，包含附件、Send 文件、配置和服务端密钥等数据。
- 备份快照期间停止 Vaultwarden 容器，完成归档后立即尝试启动容器。
- 使用 age 公钥加密，GitHub 只保存密文和 SHA256 校验文件。
- 通过 GitHub Deploy Key（SSH）向专用私有仓库推送备份。
- 可通过 1Panel「计划任务」每天凌晨 05:20 执行。
- 提供交互式管理器 `vw-manager.sh`：自动检测容器和 `/data` 主机目录，向导配置备份仓库与密钥。
- 菜单式立即备份、从 GitHub 选择历史备份恢复、环境检查和日志查看；危险操作均需逐步确认。
- 恢复前先使用 age 公钥将当前 `/data` 加密保存为本地回滚快照；恢复时保留 Docker bind mount/命名卷挂载点，只替换目录内部内容。复制失败时尝试使用原 age 私钥回滚。
- 提供底层恢复准备脚本：校验、解密并解压到临时目录；不会自行覆盖现有数据。

## 项目结构

```text
Vaultwarden_1Panel_GitHub_Project/
├── README.md
├── run.sh
├── .gitignore
├── scripts/
│   ├── vw-manager.sh
│   ├── vw-backup.sh
│   ├── vw-restore-prepare.sh
│   ├── backup.conf.example
│   ├── 1Panel-Vaultwarden-信息记录模板.txt
│   └── README-先阅读.txt
└── docs/
    └── Vaultwarden_1Panel版_交互式备份恢复_新手交付手册.docx
```

## 适用条件与限制

### 适用条件

- VPS 操作系统为 Ubuntu / Debian。
- Docker 已由 1Panel 安装和管理。
- Vaultwarden 已从 1Panel 应用商店安装并运行。
- Vaultwarden 使用 SQLite，数据目录在容器内为 `/data`。
- 主机上能够使用 `docker` 命令管理该容器。
- 已准备 GitHub Private 备份仓库、写入 Deploy Key 和 age 密钥对。

### 当前限制

- **仅适用于 SQLite 版本。** 脚本会检查主机数据目录中是否存在 `db.sqlite3`；若不存在会退出，不会尝试猜测其他数据库的备份方式。
- **容器挂载目标必须是 `/data`。** 脚本会用 `docker inspect` 比较 `/data` 对应的主机路径与配置中的 `DATA_DIR`。
- 备份时会短暂停止 Vaultwarden。归档完成后脚本会立即尝试重新启动容器；如果启动失败，需进入 1Panel 手动启动并查看日志。
- GitHub 普通 Git 仓库单个文件有大小限制。本脚本默认将单份密文限制为 90 MiB；超过限制时会保留本地加密文件，但不会推送。大文件/大量附件场景建议使用 Restic 或对象存储。
- 脚本会从当前分支工作树移除超过保留期的旧备份，但 Git 提交历史仍可能保留旧文件对象，仓库体积仍会增长。请定期检查备份仓库大小。
- 脚本只备份 Vaultwarden `/data`，不备份 1Panel 应用编排、镜像版本、环境变量、站点配置或证书。请离线记录恢复所需的非敏感参数；不要把 Admin Token、SMTP 密码等秘密写入本项目仓库。

## 安全模型：两套不同的密钥

本项目使用两套用途不同的密钥，不能混为一谈。

| 密钥 | 用途 | 保存方式 |
|---|---|---|
| GitHub SSH Deploy Key | 允许 VPS 向备份仓库上传密文 | 私钥保存在 VPS；公钥添加到专用备份仓库并授予写入权限 |
| age 密钥对 | 加密和解密备份文件 | VPS 配置中只填写 `age1...` 公钥；`AGE-SECRET-KEY-1...` 私钥离线保存 |

**age 私钥丢失意味着历史 `.age` 备份无法解密。** 初次生成时私钥会暂时写在 VPS 上；请先复制至少两份离线副本并验证可读，随后建议从 VPS 删除私钥。日后恢复时再临时复制回服务器并在菜单 3 中指定路径。不要将 age 私钥、GitHub SSH 私钥、真实配置文件或用户主密码提交到 GitHub。

生成 age 密钥对的命令示例：

```bash
age-keygen -o /root/vw-age-identity.txt
age-keygen -y /root/vw-age-identity.txt
```

第二条命令显示 `age1...` 公钥。把公钥填入备份配置；将完整的 `/root/vw-age-identity.txt` 文件离线保存，并限制文件权限：

```bash
chmod 600 /root/vw-age-identity.txt
```

不要把私钥内容粘贴到 Issue、Discussion、聊天记录或仓库文件中。

## 将本项目上传到 GitHub

建议先在 GitHub 创建一个专门存放**项目源码和文档**的仓库，例如 `vaultwarden-1panel-backup-toolkit`。首次建议设为 Private；检查确认仓库没有任何个人域名、真实路径、访问令牌、私钥或其他敏感信息后，再自行决定是否公开。

在本项目根目录（包含 `README.md` 的目录）执行：

```bash
git init -b main
git add README.md .gitignore scripts/ docs/
git status --short
```

先检查 `git status --short` 列出的文件，确认没有真实配置文件、密码、Token、SSH 私钥、age 私钥或 `.age` 备份，再提交：

```bash
git commit -m "Add 1Panel Vaultwarden backup and restore toolkit"
git remote add origin git@github.com:你的用户名/vaultwarden-1panel-backup-toolkit.git
git push -u origin main
```

上面的仓库是**项目源码仓库**。自动备份脚本使用的 `GITHUB_REPO` 则必须指向另一个单独创建的、保持空白的 **Private 备份仓库**（例如 `vaultwarden-backup`）。两个仓库不要混用。

## 推荐：使用交互式管理器（新手优先）

项目提供 `run.sh` 启动入口和 `scripts/vw-manager.sh` 交互式管理器。下载完整项目后运行 `sudo bash ./run.sh` 即可进入菜单；不需要手动查容器名、抄写 `/data` 挂载路径、编辑配置文件，再分别执行备份和恢复命令。管理器会一步一步询问，并在关键操作前显示目标信息。

### 第一次运行

先从 GitHub 获取项目源码（将下面 URL 替换成你自己的项目仓库地址；若仓库为 Private，请先配置该源码仓库的读取权限）：

```bash
sudo apt update
sudo apt install -y git
sudo git clone https://github.com/你的用户名/vaultwarden-1panel-backup-toolkit.git /opt/vaultwarden-toolkit
cd /opt/vaultwarden-toolkit
sudo bash ./run.sh
```

上面的 GitHub 地址需要替换成你实际发布的项目仓库地址。管理器要求在交互式终端运行；如果当前 SSH 用户已经是 root，可以省略命令前面的 `sudo`。

首次进入后选择菜单 `1`「首次配置 / 重新检测容器与数据目录」。向导会：

1. 检查 Docker 命令是否可用（不会安装或重装 Docker）。
2. 自动列出名称或镜像包含 `vaultwarden` 的容器；如果有多个，让你选择。
3. 通过 `docker inspect` 查找容器内 `/data` 对应的主机目录，并检查其中是否有 `db.sqlite3`。它不会猜测 1Panel 的路径。
4. 检查并按需安装 `age`、`git`、SSH 客户端等备份依赖。
5. 询问 GitHub 专用 Private 备份仓库地址，创建或复用 SSH Deploy Key，并显示需要添加到 GitHub 的 `.pub` 公钥。
6. 让你输入已有 age 公钥，或生成新的 age 密钥。迁移旧备份时必须使用原来的 age 公钥和原私钥，不能新建密钥替代。
7. 生成权限为 `600` 的本地配置，克隆已有备份仓库历史，安装备份、恢复和管理脚本。

向导结束后，先选择菜单 `4` 检查配置，再选择菜单 `2` 做一次手动备份。备份时 Vaultwarden 会短暂停止；加密快照生成后会马上尝试启动，然后再上传 GitHub。菜单会在执行前显示容器名和数据目录，并要求输入大写 `YES`。

### 管理器菜单

```text
1) 首次配置 / 重新检测容器与数据目录
2) 立即备份当前数据并推送 GitHub
3) 从 GitHub 选择备份并恢复数据
4) 检查当前环境和备份配置
5) 查看最近备份日志
6) 查看 1Panel 每日 05:20 计划任务设置
0) 退出
```

### 从 GitHub 恢复

选择菜单 `3` 后，管理器会自动克隆备份仓库并列出可用的 `.age` 文件。你选择日期后，它会验证 SHA256、要求提供原 age 私钥，并确认该私钥对应的公钥与当前配置一致；随后将数据解密到权限受限的临时目录，重新检测目标 Vaultwarden 容器和 `/data` 挂载路径。

在真正替换数据前，屏幕会显示：备份文件、目标容器、当前数据目录，以及恢复前数据将保留到的 `pre-restore-时间戳.tar.gz.age` 加密快照。只有输入大写 `YES` 才会继续。管理器会先停止容器，再使用 age 公钥加密保存当前 `/data`，然后只替换挂载目录内部的内容，保留 Docker bind mount 或命名卷的挂载点本身。复制失败时，会用本次提供的原 age 私钥尝试从加密回滚快照恢复；若自动回滚失败，容器会保持停止，避免启动不完整的数据。恢复完成后可选择是否启动容器。确认原用户、附件、TOTP 和同步均正常之前，不要删除加密回滚快照。

**新 VPS 恢复前提：** 先用 1Panel 应用商店安装 Vaultwarden，保持新实例停止或不要创建新用户，再运行管理器。首次配置时选择“已有 age 公钥”，填入原备份使用的公钥，并在恢复步骤提供原 age 私钥。若之后还要在新 VPS 上继续每日推送备份，为新 VPS 的 GitHub SSH Deploy Key 授予写权限。

### 配置每日 05:20 自动备份

首次配置完成后，管理器菜单 `6` 会显示计划任务设置。到 1Panel → 计划任务新增 Shell 脚本任务：

- Cron：`20 5 * * *`
- 脚本：`bash /usr/local/sbin/vw-backup.sh`
- 执行用户：`root` 或具备 Docker 管理权限的用户

只使用 1Panel 计划任务这一处定时配置，不要再重复添加 crontab。

> **确认机制：** 菜单浏览和状态检查不修改密码库；备份会短暂停止服务；恢复会替换数据目录。管理器在恢复前要求输入大写 `YES`。不要把 SSH 私钥、age 私钥、Admin Token、SMTP 密码或 `.age` 备份放入项目源码仓库。

---

## 脚本检查范围

当前项目脚本已完成 Bash 语法检查，并对交互菜单和备份/恢复流程做过模拟环境测试。模拟测试使用替代的 Docker、age 和本地 Git 远端，不等同于在真实 1Panel VPS、真实 GitHub 仓库和真实 age 密钥上完成生产验证。首次正式依赖前，请先手动备份并完成一次独立恢复演练。

## 快速使用

交互式管理器是推荐入口；如果需要了解底层脚本参数或手动排错，再阅读完整的新手交付手册：

[`docs/Vaultwarden_1Panel版_交互式备份恢复_新手交付手册.docx`](docs/Vaultwarden_1Panel版_交互式备份恢复_新手交付手册.docx)

以下是底层命令行流程摘要，主要用于手动排错。正常使用优先运行交互式管理器。

### 1. 在 1Panel 中确认 Vaultwarden 数据挂载

先在 1Panel 确认 Vaultwarden 应用正常运行，然后 SSH 登录 VPS：

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

找到 Vaultwarden 容器名称后检查挂载：

```bash
CONTAINER_NAME="替换为 docker ps 显示的实际容器名称"
docker inspect "$CONTAINER_NAME" \
  --format '{{range .Mounts}}{{printf "Type=%s Source=%s Destination=%s\n" .Type .Source .Destination}}{{end}}'
```

找到 `Destination=/data` 对应的 `Source`。该 `Source` 才是配置中的主机数据目录 `DATA_DIR`。不要把容器内的 `/data` 填到 `DATA_DIR`，也不要猜测路径。

确认主机目录内有 SQLite 数据库：

```bash
DATA_DIR="替换为上一步查到的主机 Source 路径"
ls -lah "$DATA_DIR"
```

应能看到 `db.sqlite3`。若没有，请停止，不要使用本项目的 SQLite 脚本。

### 2. 安装脚本运行依赖

Docker 和 Vaultwarden 已由 1Panel 管理；这里只安装备份工具，不安装 Docker：

```bash
apt update
apt install -y age git openssh-client util-linux coreutils tar gzip
```

### 3. 创建 GitHub 专用备份仓库

在 GitHub 新建一个专用 **Private** 仓库，例如 `vaultwarden-backup`。

**仓库必须保持空白：创建时不要勾选 README、License 或 `.gitignore`。** 首次运行备份脚本时，会在 VPS 本地初始化 Git 仓库并推送到这个远端。若远端已经有首次提交，初次推送可能因历史不一致而失败。

请勿将加密备份仓库与本项目源码仓库合并。

### 4. 创建 GitHub SSH Deploy Key

在 VPS 上生成专门用于该备份仓库的 SSH 密钥：

```bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
ssh-keygen -t ed25519 -C "vaultwarden-backup" \
  -f /root/.ssh/vw_github_backup -N ""
chmod 600 /root/.ssh/vw_github_backup
cat /root/.ssh/vw_github_backup.pub
```

把 `.pub` 公钥添加到**备份仓库**的 `Settings → Deploy keys → Add deploy key`，勾选 `Allow write access`。私钥 `/root/.ssh/vw_github_backup` 留在 VPS，不要上传。

首次连接 GitHub 时还需配置 SSH 主机密钥，并确认连接成功。不要关闭 SSH 主机密钥校验。

### 5. 配置备份脚本

将示例配置安装到系统配置目录：

```bash
install -m 600 scripts/backup.conf.example /etc/vaultwarden-backup.conf
nano /etc/vaultwarden-backup.conf
```

按实际情况填写：

- `CONTAINER`：`docker ps` 显示的 Vaultwarden 容器名称。
- `DATA_DIR`：`docker inspect` 中 `Destination=/data` 对应的主机 `Source`。
- `AGE_RECIPIENT`：`age-keygen -y` 输出的 `age1...` 公钥，不是私钥。
- `GITHUB_REPO`：专用备份仓库 SSH 地址，例如 `git@github.com:用户名/vaultwarden-backup.git`。
- `GITHUB_SSH_KEY`：SSH 私钥路径，例如 `/root/.ssh/vw_github_backup`，不要填写 `.pub` 文件。
- 其他目录、保留天数和文件大小参数可按需调整。

真实配置文件 `/etc/vaultwarden-backup.conf` 不要提交到 GitHub。

### 6. 安装并手动测试

```bash
install -m 700 scripts/vw-backup.sh /usr/local/sbin/vw-backup.sh
/usr/local/sbin/vw-backup.sh
tail -n 100 /var/log/vaultwarden-backup.log
```

成功时日志应出现：

```text
SUCCESS: encrypted backup uploaded to GitHub.
```

并在 GitHub **备份仓库**中看到类似文件：

```text
vw-YYYYMMDD-HHMMSS.tar.gz.age
vw-YYYYMMDD-HHMMSS.tar.gz.age.sha256
```

第一次正式依赖这套备份前，必须完成一次恢复演练。

### 7. 配置 1Panel 每日 05:20 计划任务

在 1Panel 左侧进入「计划任务」，新增 Shell 脚本任务：

- 执行周期：每天。
- 执行时间：05:20。
- Cron 表达式：`20 5 * * *`。
- 脚本内容：

```bash
/usr/local/sbin/vw-backup.sh
```

确保任务以具有 Docker 管理权限的系统用户执行。时间以 VPS 系统本地时区为准。使用 1Panel 计划任务后，不要再添加同一脚本的 root crontab，避免重复备份。

## 从 GitHub 恢复

恢复时需要：

1. GitHub 备份仓库的读取权限（只读 Deploy Key 即可；若之后继续每日备份，建议给新 VPS 单独创建写入 Deploy Key）。
2. 原 age 私钥文件 `vw-age-identity.txt`。
3. 需要恢复的 `.tar.gz.age` 和对应 `.sha256` 文件。
4. 新 VPS 已通过 1Panel 安装好 Vaultwarden 应用，且能确认其 `/data` 主机挂载路径。

**推荐直接运行交互式管理器菜单 3**，它会完成克隆仓库、列出备份、校验、解密、目标检测、旧数据留存和恢复。下面的命令行方式仅供手动排错。

**推荐先使用交互式管理器菜单 3。** 下面的 `vw-restore-prepare.sh` 仅用于手动恢复流程，它只负责校验、解密和暂存，不会替你覆盖 1Panel 的数据目录。

```bash
chmod 700 vw-restore-prepare.sh
./vw-restore-prepare.sh \
  /path/to/vw-YYYYMMDD-HHMMSS.tar.gz.age \
  /secure/path/vw-age-identity.txt \
  /root/vw-restore-staging
```

脚本会要求配套 `.sha256` 文件存在并通过校验，再解密并解压到：

```text
/root/vw-restore-staging/data
```

**该底层脚本不会自动覆盖 1Panel 正在管理的 Vaultwarden 数据目录。** 新手请优先使用交互式管理器菜单 `3`，它会在恢复前生成 age 加密回滚快照，并保留 Docker 的 `/data` 挂载点本身。若必须手工恢复，请先停止 Vaultwarden、将当前 `/data` 另行加密备份，再替换挂载目录内部内容；不要移动 Docker 命名卷的 `_data` 挂载目录本身。

恢复后逐项检查：

- 原用户能否使用原主密码登录。
- 密码库条目是否完整。
- TOTP 项目是否存在并能正常生成验证码。
- 附件和 Send 文件是否可用。
- 手机 App 和浏览器扩展是否可以同步。

不要删除恢复前生成的加密回滚快照和 GitHub 加密备份，直到恢复验收完成。

## 新 VPS 恢复后继续每日备份

如果新 VPS 还需要向同一个 GitHub 备份仓库继续推送：

1. 在新 VPS 生成新的 SSH 写入密钥，并将公钥作为新的 Deploy Key 添加到同一个备份仓库，授予写入权限。
2. 保留原来的 `AGE_RECIPIENT` 公钥；不要重新生成 age 密钥对，否则旧备份无法用新私钥解密。
3. 使用新 SSH 写入密钥克隆原有备份仓库到 `REPO_DIR`，保留 Git 历史和远端配置。
4. 更新新 VPS 的 `CONTAINER`、`DATA_DIR`、`GITHUB_SSH_KEY` 等配置。
5. 手动运行备份脚本并确认成功推送，再在 1Panel「计划任务」中恢复每日 05:20 任务。

## 故障排查

| 现象 | 优先检查 |
|---|---|
| `db.sqlite3 not found` | 是否为 SQLite 部署；`DATA_DIR` 是否填了主机目录而不是容器内路径 |
| `/data source does not match DATA_DIR` | 重新执行 `docker inspect`，将 `Destination=/data` 的 `Source` 原样填入配置 |
| `Container not found` | `CONTAINER` 是否与 `docker ps` 显示的名称完全一致 |
| `GitHub SSH authentication failed` | Deploy Key 是否添加到备份仓库；是否勾选写入权限；SSH 私钥路径是否正确 |
| `non-fast-forward` | 远端仓库是否不是空仓库；本地 `REPO_DIR` 是否丢失或未克隆既有仓库 |
| 备份超过 90 MiB | 备份文件会留在本地但不推送；考虑 Restic 或对象存储 |
| Vaultwarden 未重新启动 | 登录 1Panel，手动启动应用/容器并检查容器日志 |
| 解密失败 | 是否使用最初生成的 age 私钥；私钥文件是否完整；备份文件是否损坏 |

## 安全清单

- [ ] 本项目源码仓库与加密备份仓库分开。
- [ ] 加密备份仓库设置为 Private。
- [ ] `AGE_RECIPIENT` 填的是 `age1...` 公钥。
- [ ] age 私钥在服务器之外至少保存一份安全副本。
- [ ] GitHub SSH 私钥、age 私钥、真实配置文件没有提交到仓库。
- [ ] Vaultwarden 主密码由各用户自行妥善保存。
- [ ] 已完成一次从 GitHub 下载、校验、解密、恢复和登录的演练。
- [ ] 定期检查备份日志、GitHub 仓库体积，并再次进行恢复测试。

## 免责声明

本项目为自托管备份脚本和操作文档，不是 Vaultwarden 官方项目，也不隶属于 1Panel 或 GitHub。使用前请先在测试环境验证恢复流程。任何备份策略都不能替代离线密钥保管和实际恢复演练。
