# 路线图

## 近期：兼容性与稳定性优先

- 跟进 Ubuntu / Debian、1Panel 与 Docker Compose 的版本变化，保持容器发现和 `/data` 路径识别可靠。
- 按 [支持矩阵](docs/支持矩阵.md) 逐项补真实环境实测记录，只写测过的组合。
- 持续积累 [恢复演练记录](docs/恢复演练记录模板.md)，让恢复可信度有据可查。
- 在拿到第一批外部试用反馈前冻结新功能，优先修稳定性问题。

## 明确不做

- 不集成 Restic、S3 兼容对象存储或多 age 密钥；保持 GitHub Private 与 WebDAV 两种异地目标。
- 不安装或升级 Docker / 1Panel / Vaultwarden，不配置域名、HTTPS 或反向代理。
- 不支持 MySQL / PostgreSQL 外部数据库。

## 版本纪律

- 遵循语义化版本：新功能升次版本，缺陷修复升修订号。
- 每次发版同步更新 CHANGELOG 并发布 GitHub Release，说明写清升级步骤和注意事项。
