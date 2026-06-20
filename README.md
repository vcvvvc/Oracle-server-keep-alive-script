# Oracle-server-keep-alive-script

[![Hits](https://hits.spiritlhl.net/Oracle-server-keep-alive-script.svg?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false)](https://hits.spiritlhl.net)

## 甲骨文服务器保活脚本

这个项目是给低负载机器做保活用的，占用项可选：CPU、内存、带宽。

运行脚本已统一为 POSIX `sh` 兼容，也可以直接用 `bash` 启动。

英文文档见 [README_EN.md](README_EN.md)。

## 支持范围

- Linux：Debian、Ubuntu、RHEL/CentOS/Oracle Linux/AlmaLinux/Rocky、Fedora、Amazon Linux、Arch、Alpine、openSUSE/SLES、Void、Gentoo 等常见发行版。
- BSD：FreeBSD、OpenBSD、NetBSD、DragonFly BSD 等带 `cron` 和标准 POSIX 工具的系统。
- 调度：Linux 且有 systemd 时走 systemd；非 systemd 的 Linux 和 BSD 走 cron 监督器。
- 包管理器：`apt-get`、`dnf`、`yum`、`microdnf`、`zypper`、`apk`、`pacman`、`pkg`、`pkg_add`、`pkgin`、`xbps-install`、`emerge`。

系统差异会自动降级处理。比如 BSD 没有 systemd 就走 cron；没有 speedtest 工具时，带宽模式会回退到默认速率估算，不会直接报错退出。

## 安装

使用 `sh`：

```sh
curl -fsSL https://gitlab.com/spiritysdx/Oracle-server-keep-alive-script/-/raw/main/oalive.sh -o oalive.sh
chmod +x oalive.sh
sh oalive.sh
```

或使用 `bash`：

```sh
curl -fsSL https://gitlab.com/spiritysdx/Oracle-server-keep-alive-script/-/raw/main/oalive.sh -o oalive.sh
chmod +x oalive.sh
bash oalive.sh
```

在仓库目录内运行：

```sh
sh oalive.sh
```

脚本需要 root 权限安装服务、cron、配置和日志目录。

## 菜单

- `1`：安装或重装保活服务
- `2`：卸载保活服务
- `3`：更新安装引导脚本
- `4`：退出

也可以使用命令行参数：

```sh
sh oalive.sh --install
sh oalive.sh --uninstall
sh oalive.sh --status
sh oalive.sh --update
```

## 特点

- CPU：默认使用 POSIX 兼容占用逻辑，按“单核配额百分比”工作；2 到 4 核机器默认 `核心数 * 20%`，其他机器默认 `25%`。在 systemd 环境会再写入 `CPUQuota` 做双重限制。
- 内存：默认目标为总内存 `25%`，每轮占用 300 秒、休息 300 秒。会读取 Linux `/proc/meminfo` 或 BSD `sysctl` 指标，并按临时目录可用空间限幅。
- 带宽：默认每 45 分钟触发一次，最长下载 6 分钟，速率按测速结果的 30%。自定义模式可直接指定 Mbps、时长、间隔。
- 调度：systemd 环境安装 `cpu-limit.service`、`memory-limit.service`、`bandwidth_occupier.timer`；cron 环境安装 `oalive-cron-runner.sh` 监督器。
- 安全：所有任务都有原子目录锁，避免并发重入；卸载时按锁和精确脚本路径停止任务，不再靠模糊进程名匹配。
- 日志：日志写入 `/var/log/oalive`，单文件默认 128 KiB 自动轮转到 `.1`。

## Oracle 分支推荐配置

`oracle` 分支记录了当前在 1 OCPU / 2 逻辑 CPU Oracle Always Free 实例上使用的配置。安装交互时可按这些值填写：

- CPU 模式：`1` 本机 POSIX，占用目标 `60`
- 内存：启用，`MEMORY_TARGET_PERCENT=25`，`MEMORY_HOLD_SECONDS=300`，`MEMORY_REST_SECONDS=300`
- 带宽：启用，模式 `2` 受控下载，自定义参数，`BANDWIDTH_RATE_MBPS=10`，`BANDWIDTH_DURATION_MINUTES=6`，`BANDWIDTH_INTERVAL_MINUTES=45`

最终 `/etc/oalive/oalive.conf` 关键项应类似：

```sh
CPU_QUOTA_PERCENT=60
CPU_CYCLE_SECONDS=10
MEMORY_TARGET_PERCENT=25
MEMORY_HOLD_SECONDS=300
MEMORY_REST_SECONDS=300
BANDWIDTH_MODE=wget
BANDWIDTH_INTERVAL_MINUTES=45
BANDWIDTH_DURATION_MINUTES=6
BANDWIDTH_RATE_PERCENT=100
BANDWIDTH_RATE_MBPS=10
```

systemd 环境额外使用 `/etc/systemd/system/cpu-limit.service.d/quota.conf` 限制 CPU 忙时上限：

```ini
[Service]
CPUQuota=70%
```

这个组合的含义是：CPU 脚本按 60% 单核配额做周期占用，`CPUQuota=70%` 再限制忙时最高上限。`CPU_CYCLE_SECONDS=10` 时，大致是忙 6 秒、休 4 秒；在 2 逻辑 CPU 机器上，理论整机平均约 21%，实际会受系统负载和监控采样影响。

带宽下载源按日本东京、香港、新加坡、美西、fallback 顺序尝试。某个源探测失败、下载报错或文件提前下载完，会自动尝试下一个源；每一轮总下载时长仍受 `BANDWIDTH_DURATION_MINUTES` 限制，不会因为切源重新计时。

辅助脚本：

- `scripts/test_bandwidth_urls.sh`：测试内置下载源，日志写入 `/tmp/oalive-bandwidth-url-test.log`。
- `scripts/silent_oalive_check.sh`：静默检查服务、timer、配置和 CPU 采样，默认 5 分钟、5 秒间隔，日志写入 `/tmp/oalive-silent-check-*.log`。
- `scripts/apply_cpu_60_60.sh`：应用当前 CPU 推荐值；默认实际为 `CPU_QUOTA_PERCENT=60` 和 `CPUQuota=70%`，可用 `CPU_TARGET=... CPU_QUOTA=...` 覆盖。

## 文件位置

- 配置：`/etc/oalive/oalive.conf`
- 启用状态：`/etc/oalive/enabled.conf`
- 日志：`/var/log/oalive/`
- 状态：`/var/lib/oalive/`
- 运行锁：`/tmp/oalive-*.lock`
- 运行脚本：`/usr/local/bin/cpu-limit.sh`、`/usr/local/bin/memory-limit.sh`、`/usr/local/bin/bandwidth_occupier.sh`、`/usr/local/bin/oalive-cron-runner.sh`

## 卸载

```sh
sh oalive.sh --uninstall
```

卸载会停止 systemd 服务或删除 cron 块，清理运行脚本、配置、状态文件和锁。重复卸载是安全的。

## 自定义

安装后可以编辑 `/etc/oalive/oalive.conf`，再重启对应调度：

systemd:

```sh
systemctl daemon-reload
systemctl restart cpu-limit.service memory-limit.service
systemctl restart bandwidth_occupier.timer
```

cron:

```sh
sh /usr/local/bin/oalive-cron-runner.sh --check
```

更多手动定时示例见 [README_CRON.md](README_CRON.md)。英文版定时说明见 [README_CRON_EN.md](README_CRON_EN.md)。

## 说明

资源占用能否影响云厂商回收策略，没有确定保证。

这个项目只提供可控、可卸载、低风险的占用任务，请按服务商条款和自己的实际用途自行判断。

## 友链

VPS融合怪测评项目：

- Go版本: <https://github.com/oneclickvirt/ecs>
- Shell版本: <https://github.com/spiritLHLS/ecs>

一键虚拟化项目：

- 国内: <https://virt.spiritlhl.net/>
- 国际: <https://www.spiritlhl.net/>

## Stargazers over time

[![Stargazers over time](https://starchart.cc/spiritLHLS/Oracle-server-keep-alive-script.svg)](https://starchart.cc/spiritLHLS/Oracle-server-keep-alive-script)
