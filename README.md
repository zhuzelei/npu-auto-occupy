# NPU 自动占用

这是一套针对已有 Docker 容器的 NPU 空闲自动占用方案。镜像不在本仓库
中，请自行准备包含 CANN、`torch`、`torch_npu` 及对应 Python 运行时的镜像。

## 方案结构与精简结论

```text
宿主 systemd（Restart=always）
    └─ 宿主 watchdog
         ├─ docker exec → query_host_npu.sh
         └─ docker exec → auto_occupy_worker.py
```

- 容器内没有常驻 monitor/supervisor，只有探测脚本和需要时才启动的 worker。
- 默认连续空闲 1200 秒（20 分钟）后才自动占用，轮询间隔 30 秒。
- `USER_IN_USE`、`AUTO_OCCUPIED`、`IDLE` 等状态写入
  `<宿主代码目录>/.state/auto-occupy.tsv`。
- `auto_occupy.sh` 仅保留 `once/kill/status/check` 手工入口，不作为常驻进程。
- watchdog、探测脚本和 worker 不能继续删除；删除任意一个都会破坏计时、状态记录或自动拉起。
- 手动停止保护仍保留，用于给出释放提示；真正释放请使用 `pkill -f auto-occupy`。

### 无 `npu-smi` 环境

探测脚本默认使用 `auto` 后端：宿主机上的 `npu-smi` 查询成功时保持原有
进程探测逻辑；否则在容器内使用 `torch_npu` 的 `device_count()` 和
`mem_get_info()` 判断每张卡的显存占用。

Torch 后端采用保守策略。只有每张卡的已用显存都不超过
`NPU_IDLE_MAX_USED_MIB`（默认 512 MiB）时才报告空闲；查询失败、返回值异常
或未发现 NPU 时均返回错误，watchdog 不会累计空闲时间。Torch 无法枚举其他
进程的 PID，因此该后端只能判断显存是否接近空闲，不能替代 `npu-smi` 的进程
级信息。

可以在安装时显式选择后端和阈值：

```bash
sudo ./install.sh --query-backend torch --idle-max-used-mib 512
```

`--query-backend auto` 是默认值，也可设置为 `npu-smi`，使查询失败时不回退。

### 状态快照（9 列）

状态行用于统计某一时刻的 NPU 使用情况。状态变化立即记录；同一状态最多
每 300 秒补记一次。

以下为实际格式示例（时间和路径仅作展示）：

| 时间 | 状态 | 总卡数 | 总 Die 数 | 用户卡数 | 自动卡数 | 空闲计数 | 用户详情 | 自动详情 |
|---|---|---:|---:|---:|---:|---:|---|---|
| 2026-08-29 11:28 | `USER_IN_USE` | 5 | 9 | 5 | 0 | 0 | `die0 cwd=/data/p00465316/override/... docker=/panchao_override` | — |
| 2026-08-29 09:38 | `AUTO_OCCUPIED` | 8 | 16 | 0 | 8 | 0 | — | `die0-die15 cwd=/ docker=/cann_900_torchtitan_master_zdp` |
| 2026-08-29 08:55 | `IDLE` | 0 | 0 | 0 | 0 | 0 | — | — |

- `总卡数`、`总 Die 数`：当前所有进程合计占用的卡和 Die。
- `用户卡数`、`自动卡数`：分别排除/识别进程名 `auto-occupy` 后的统计。
- `用户详情`、`自动详情`：按 `Die 范围 + cwd + Docker 容器名` 展开，可用分号分隔多组。
- `空闲计数`：旧格式兼容字段；20 分钟判断使用实际经过时间，不依赖这一列。

### 事件行（3 列）

同一个 TSV 文件还会追加事件行，格式是“时间、事件、说明”：

| 时间 | 事件 | 说明 |
|---|---|---|
| 2026-08-29 09:16 | `BROADCAST_OK` | 空闲 20 分钟后广播并开始占用 |
| 2026-08-29 09:16 | `AUTO_START` | `memory_gib_per_device=50` |
| 2026-08-29 09:40 | `AUTO_RELEASE_RESET` | worker 消失，重新开始空闲计时 |
| 2026-08-29 09:45 | `QUERY_ERROR` | NPU 查询或 Docker 执行失败 |

常见事件还包括 `AUTO_START_MANUAL`、`AUTO_RELEASE`、`AUTO_STARTING` 和
`USER_IN_USE_AND_AUTO_OCCUPIED`。因此解析时可按列数区分：9 列是状态快照，
3 列是事件记录。

## 一键部署

先创建并启动目标容器，然后在目标宿主机执行：

```bash
git clone git@github.com:depeng1994/npu-auto-occupy.git
cd npu-auto-occupy
sudo ./install.sh
```

也可以不克隆仓库，直接一行安装：

```bash
curl -fsSL https://raw.githubusercontent.com/depeng1994/npu-auto-occupy/main/bootstrap.sh | sudo bash
```

安装脚本会完成以下动作：

1. 将三个运行脚本同步到宿主代码目录和容器代码目录。
2. 安装宿主 watchdog、systemd 单元和手动停止保护脚本。
3. 生成 `/etc/default/auto-occupy-docker`。
4. 执行 `systemctl daemon-reload` 并启用服务。

默认值适配当前 A3 环境：

```text
容器：       cann_900_torchtitan_master_zdp
Docker socket：unix:///data/z00894965/docker-daemon/docker.sock
宿主目录：   /data/z00894965/code/auto-occupy
Docker 单元：docker-z00894965.service
```

如果目标环境不同，覆盖必要参数即可：

```bash
sudo ./install.sh \
  --container <容器名> \
  --docker-socket /var/run/docker.sock \
  --docker-service docker.service \
  --host-base /data/z00894965/code/auto-occupy \
  --container-base /opt/auto-occupy
```

完整参数可执行：

```bash
./install.sh --help
```

## 安全验证

首次验证前，按环境规范先执行 `npu-smi info`。建议只降低每卡占用内存，
不要降低 20 分钟阈值：

```bash
sudo ./install.sh --memory-gib-per-device 1
```

验证通过后，如需完整占用，再执行：

```bash
sudo ./install.sh --memory-gib-per-device 50
```

## 常用操作

查看服务和日志：

```bash
systemctl status auto-occupy-docker.service
journalctl -u auto-occupy-docker.service -f
tail -f /data/z00894965/code/auto-occupy/.state/auto-occupy.tsv
```

释放 NPU worker（不要停止 watchdog）：

```bash
pkill -f auto-occupy
```

`systemctl stop/restart auto-occupy-docker.service` 会被拒绝。修改配置后重新
运行 `sudo ./install.sh`，脚本会只重启 watchdog 主进程，不会主动终止容器
内的 worker。

## 文件说明

```text
bin/auto_occupy.sh             容器内手工入口（非常驻）
bin/query_host_npu.sh          容器内 NPU 进程探测
bin/query_npu_torch.py         无 npu-smi 时的保守 Torch 显存探测
bin/auto_occupy_worker.py      NPU worker，进程名为 auto-occupy
host/auto-occupy-watchdog      宿主 systemd watchdog
systemd/auto-occupy-docker.service
systemd/guard.conf             手动停止保护 drop-in
systemd/auto-occupy-refuse-stop
install.sh                     宿主一键安装
bootstrap.sh                   curl 一行安装入口
make-archive.sh                生成不含镜像/状态的源码压缩包
```

生成源码压缩包：

```bash
./make-archive.sh
```
