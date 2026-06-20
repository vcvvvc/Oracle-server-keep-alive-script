# Oracle-server-keep-alive-script

[![Hits](https://hits.spiritlhl.net/Oracle-server-keep-alive-script.svg?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false)](https://hits.spiritlhl.net)

## Oracle server keep-alive script

This project provides optional CPU, memory, and bandwidth occupiers for low-load servers.
All runtime scripts are POSIX `sh` compatible and can also be launched with `bash`.

## Compatibility

- Linux: Debian, Ubuntu, RHEL/CentOS/Oracle Linux/AlmaLinux/Rocky, Fedora, Amazon Linux, Arch, Alpine, openSUSE/SLES, Void, Gentoo, and other distributions with standard POSIX userland.
- BSD: FreeBSD, OpenBSD, NetBSD, DragonFly BSD, and other BSD systems with `cron` and standard POSIX tools.
- Scheduling: Linux with systemd uses systemd services and timer; non-systemd Linux and BSD use a cron supervisor.
- Package managers: `apt-get`, `dnf`, `yum`, `microdnf`, `zypper`, `apk`, `pacman`, `pkg`, `pkg_add`, `pkgin`, `xbps-install`, `emerge`.

Platform differences are handled defensively. For example, BSD uses cron instead of systemd; if no speedtest tool is available, bandwidth download mode falls back to a default estimated rate.

## Install

Run with `sh`:

```sh
curl -fsSL https://gitlab.com/spiritysdx/Oracle-server-keep-alive-script/-/raw/main/oalive.sh -o oalive.sh
chmod +x oalive.sh
sh oalive.sh
```

Run with `bash`:

```sh
curl -fsSL https://gitlab.com/spiritysdx/Oracle-server-keep-alive-script/-/raw/main/oalive.sh -o oalive.sh
chmod +x oalive.sh
bash oalive.sh
```

From a local clone:

```sh
sh oalive.sh
```

The installer needs root privileges to install services, cron entries, config files, and log directories.

## Menu

- `1`: Install or reinstall keep-alive services
- `2`: Uninstall keep-alive services
- `3`: Update installer script
- `4`: Exit

You can also use CLI arguments:

```sh
sh oalive.sh --install
sh oalive.sh --uninstall
sh oalive.sh --status
sh oalive.sh --update
```

## Features

- CPU: Uses a POSIX-native workload loop by default. On 2 to 4 cores, default quota is `cores * 20%`; otherwise default is `25%`. On systemd hosts, `CPUQuota` is also written as a second limit.
- Memory: Target is `25%` of total memory by default, with 300 seconds hold and 300 seconds rest. It reads Linux `/proc/meminfo` or BSD `sysctl`, and limits allocation by writable temp space.
- Bandwidth: Runs every 45 minutes by default, downloads for up to 6 minutes, and uses 30% of measured bandwidth. Custom mode supports fixed Mbps, duration, and interval.
- Scheduler: systemd hosts install `cpu-limit.service`, `memory-limit.service`, and `bandwidth_occupier.timer`; cron hosts install `oalive-cron-runner.sh` supervisor.
- Safety: Atomic directory locks are used in all tasks to avoid duplicate runs. Uninstall stops tasks by lock and exact script path instead of fuzzy process matching.
- Logging: Logs go to `/var/log/oalive`; each file rotates at 128 KiB by default.
- Runtime messages: Installer, status, error, and runtime logs include both Chinese and English text.

## Oracle Branch Recommended Config

The `oracle` branch documents the runtime settings currently used on a 1 OCPU / 2 logical CPU Oracle Always Free instance. During install, use these answers:

- CPU mode: `1` native POSIX occupier, target `60`
- Memory: enabled, `MEMORY_TARGET_PERCENT=25`, `MEMORY_HOLD_SECONDS=300`, `MEMORY_REST_SECONDS=300`
- Bandwidth: enabled, mode `2` controlled download, custom parameters, `BANDWIDTH_RATE_MBPS=10`, `BANDWIDTH_DURATION_MINUTES=6`, `BANDWIDTH_INTERVAL_MINUTES=45`

The key `/etc/oalive/oalive.conf` values should look like:

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

On systemd hosts, `/etc/systemd/system/cpu-limit.service.d/quota.conf` also limits the busy-time CPU ceiling:

```ini
[Service]
CPUQuota=70%
```

This means the CPU script targets 60% of one-core quota, while `CPUQuota=70%` caps the busy phase. With `CPU_CYCLE_SECONDS=10`, it is roughly 6 seconds busy and 4 seconds idle. On a 2 logical CPU instance, the theoretical whole-machine average is about 21%; real monitoring values depend on background load and sampling windows.

Bandwidth sources are tried in this order: Tokyo, Hong Kong, Singapore, US West, then fallback sources. If one source fails probing, errors during download, or finishes early, the script continues with the next source. The whole run is still capped by `BANDWIDTH_DURATION_MINUTES`; switching sources does not restart the timer.

Helper scripts:

- `scripts/test_bandwidth_urls.sh`: tests built-in download sources and writes `/tmp/oalive-bandwidth-url-test.log`.
- `scripts/silent_oalive_check.sh`: silently checks services, timer, config, and CPU samples. Defaults to 5 minutes with 5-second samples, writing `/tmp/oalive-silent-check-*.log`.
- `scripts/apply_cpu_60_60.sh`: applies the current recommended CPU config. Despite the historical file name, defaults are `CPU_QUOTA_PERCENT=60` and `CPUQuota=70%`; override with `CPU_TARGET=... CPU_QUOTA=...`.

## Paths

- Config: `/etc/oalive/oalive.conf`
- Enabled flags: `/etc/oalive/enabled.conf`
- Logs: `/var/log/oalive/`
- State: `/var/lib/oalive/`
- Runtime locks: `/tmp/oalive-*.lock`
- Runtime scripts: `/usr/local/bin/cpu-limit.sh`, `/usr/local/bin/memory-limit.sh`, `/usr/local/bin/bandwidth_occupier.sh`, `/usr/local/bin/oalive-cron-runner.sh`

## Uninstall

```sh
sh oalive.sh --uninstall
```

Uninstall stops systemd services or removes cron entries, then cleans scripts, config, state files, and locks. Re-running uninstall is safe.

## Customization

Edit `/etc/oalive/oalive.conf` after install, then reload scheduler settings.

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

For manual cron scheduling examples, see [README_CRON_EN.md](README_CRON_EN.md).

## Notes

Resource activity does not guarantee any cloud-provider retention outcome.
This project only provides controlled, removable, low-risk occupier tasks.
Use it according to your provider terms and your real workload needs.

## Links

VPS benchmark project:

- Go version: <https://github.com/oneclickvirt/ecs>
- Shell version: <https://github.com/spiritLHLS/ecs>

One-click virtualization project:

- CN site: <https://virt.spiritlhl.net/>
- Global site: <https://www.spiritlhl.net/>

## Stargazers over time

[![Stargazers over time](https://starchart.cc/spiritLHLS/Oracle-server-keep-alive-script.svg)](https://starchart.cc/spiritLHLS/Oracle-server-keep-alive-script)
