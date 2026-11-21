#!/usr/bin/env python3
"""Read the Vaultwarden Backup Manager TSV performance history."""
from __future__ import annotations
import argparse
import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

FIELDS = ["timestamp", "operation", "run_id", "stage", "duration_ms", "status", "bytes"]
OP_LABELS = {"backup": "备份", "restore": "恢复"}
STAGE_LABELS = {
    "container_discovery_preflight": "容器发现与预检查",
    "manifest_generation": "部署清单生成",
    "snapshot_stop_sqlite_tar_age": "停止/SQLite检查/快照加密",
    "container_restart_health": "容器重启与健康检查",
    "local_validation_manifest_checksum": "本地校验/清单加密/SHA256",
    "github_sync_retention_push_verify": "GitHub同步/推送/远端核验",
    "github_clone_and_list": "GitHub克隆与备份列表",
    "restore_decrypt_validate": "age解密/归档/SQLite校验",
    "restore_target_preflight": "恢复目标检查",
    "pre_restore_rollback_snapshot": "恢复前回滚快照",
    "replace_production_data": "替换生产数据",
    "container_start_health_check": "恢复后启动/健康检查",
    "TOTAL": "总耗时",
}

def read_rows(path: Path):
    if not path.exists():
        return []
    rows = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            try:
                row["duration_ms"] = int(row.get("duration_ms") or 0)
                row["bytes"] = int(row.get("bytes") or 0)
            except ValueError:
                continue
            if row.get("run_id") and row.get("stage"):
                rows.append(row)
    return rows

def fmt(ms: int) -> str:
    return f"{ms/1000:.3f}s"

def main():
    ap = argparse.ArgumentParser(description="Vaultwarden backup/restore performance report")
    ap.add_argument("file", nargs="?", default="/var/lib/vaultwarden-backup/performance.tsv")
    ap.add_argument("--recent", action="store_true", help="show recent stage rows")
    ap.add_argument("--details", metavar="RUN_ID", help="show stages for one run id")
    ap.add_argument("--csv", metavar="OUTPUT", help="export all rows as CSV")
    args = ap.parse_args()
    path = Path(args.file)
    rows = read_rows(path)
    if not rows:
        if path.exists():
            print(f"性能记录文件存在，但目前只有表头或没有有效记录：{path}")
        else:
            print(f"尚无性能记录文件：{path}")
        print("v1.4.2 手动备份会调用当前项目中的计时版 worker。")
        print("systemd 后台任务使用 /usr/local/sbin/vw-backup.sh；项目更新后请先运行菜单 07 同步后台脚本。")
        print("完成一次手动备份或恢复后，请检查日志中是否出现 [性能] 和 [耗时] 行。")
        return 0
    if args.csv:
        out = Path(args.csv)
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open("w", encoding="utf-8-sig", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=FIELDS)
            writer.writeheader()
            writer.writerows(rows)
        print(f"已导出 {len(rows)} 条性能记录：{out}")
        return 0
    if args.recent:
        print("最近阶段记录（最多 80 条）：")
        print(f"{'时间':22} {'操作':10} {'阶段':34} {'耗时':>12} {'状态':>10}")
        for r in reversed(rows[-80:]):
            print(f"{r['timestamp'][:22]:22} {r['operation'][:10]:10} {STAGE_LABELS.get(r['stage'], r['stage'])[:34]:34} {fmt(r['duration_ms']):>12} {r['status']:>10}")
        return 0
    if args.details:
        selected = [r for r in rows if r["run_id"] == args.details]
        if not selected:
            print(f"没有找到运行记录：{args.details}", file=sys.stderr)
            return 1
        print(f"运行详情：{args.details}")
        print(f"{'阶段':30} {'耗时':>12} {'状态':>10} {'字节':>14}")
        for r in selected:
            print(f"{STAGE_LABELS.get(r['stage'], r['stage'])[:30]:30} {fmt(r['duration_ms']):>12} {r['status']:>10} {r['bytes']:>14}")
        return 0

    total_rows = [r for r in rows if r["stage"] == "TOTAL"]
    stage_rows = [r for r in rows if r["stage"] != "TOTAL"]
    recent_totals = total_rows[-20:]
    print("Vaultwarden 性能监控与执行耗时分析")
    print(f"记录文件：{path}")
    print(f"历史运行次数：{len(total_rows)}；阶段记录：{len(stage_rows)}")
    print("\n最近运行：")
    print(f"{'时间':22} {'操作':12} {'耗时':>12} {'状态':>10} {'运行 ID':24}")
    for r in reversed(recent_totals):
        print(f"{r['timestamp'][:22]:22} {OP_LABELS.get(r['operation'], r['operation'])[:12]:12} {fmt(r['duration_ms']):>12} {r['status']:>10} {r['run_id'][:24]:24}")

    # Summarize stage timings over the last 30 operation ids.
    recent_ids = {r["run_id"] for r in total_rows[-30:]}
    by_stage = defaultdict(list)
    for r in stage_rows:
        if r["run_id"] in recent_ids and r["status"] in ("success", "failed", "interrupted"):
            by_stage[(r["operation"], r["stage"])].append(r["duration_ms"])
    if by_stage:
        print("\n最近 30 次操作的阶段统计（按平均耗时排序）：")
        print(f"{'操作/阶段':38} {'次数':>6} {'平均':>12} {'最大':>12}")
        sorted_items = sorted(by_stage.items(), key=lambda item: statistics.mean(item[1]), reverse=True)
        for (op, stage), values in sorted_items[:15]:
            label = f"{OP_LABELS.get(op, op)}/{STAGE_LABELS.get(stage, stage)}"[:38]
            print(f"{label:38} {len(values):6d} {fmt(round(statistics.mean(values))):>12} {fmt(max(values)):>12}")
    print("\n提示：GitHub 同步/推送耗时主要受 VPS 到 GitHub 的网络影响；快照/恢复耗时主要受磁盘、CPU 和数据量影响。")
    print("总耗时包含交互式操作等待时间；分析纯处理性能时，请重点比较各阶段耗时。")
    print("性能文件仅记录阶段名称、时长、状态和字节数，不记录密码或 Token。")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
