# NPU Auto-Occupy

Host-driven NPU idle occupancy for an existing Docker image. The image is not
included: it must already contain CANN, `torch`, `torch_npu`, and the Python
runtime used by the worker.

## One-click deployment

On the target host, after the image/container has been created and started:

```bash
git clone git@github.com:depeng1994/npu-auto-occupy.git
cd npu-auto-occupy
sudo ./install.sh
```

If `curl` is available, the same install can be bootstrapped without a local
clone:

```bash
curl -fsSL https://raw.githubusercontent.com/depeng1994/npu-auto-occupy/main/bootstrap.sh | sudo bash
```

The defaults match the current A3 setup (`cann_900_torchtitan_master_zdp`,
`/data/z00894965/docker-daemon/docker.sock`, and
`/data/z00894965/code/auto-occupy`). For another layout, pass overrides, for
example:

```bash
sudo ./install.sh \
  --container my-npu-container \
  --docker-socket /var/run/docker.sock \
  --docker-service docker.service \
  --host-base /data/z00894965/code/auto-occupy \
  --container-base /opt/auto-occupy
```

`install.sh` synchronizes the three container-side scripts, installs the host
watchdog and stop-guard, writes `/etc/default/auto-occupy-docker`, reloads
systemd, and enables `auto-occupy-docker.service`. It does not run a manual
occupancy test and does not package an image.

To make a portable source archive (without `.git`, state, logs, or an image):

```bash
./make-archive.sh
```

The watchdog records `USER_IN_USE`, `AUTO_OCCUPIED`, `IDLE`, and related states
to `<host-base>/.state/auto-occupy.tsv`. Auto-start remains wall-clock based:
the default idle threshold is 1200 seconds (20 minutes), polled every 30
seconds.

## Operations

```bash
systemctl status auto-occupy-docker.service
journalctl -u auto-occupy-docker.service -f
tail -f /data/z00894965/code/auto-occupy/.state/auto-occupy.tsv
```

Release the worker without stopping the watchdog:

```bash
pkill -f auto-occupy
```

Manual `systemctl stop`/`restart` is intentionally refused. After editing the
configuration, rerun `sudo ./install.sh`; it refreshes an active watchdog by
killing only its main process so `Restart=always` takes effect.

## Layout

```text
bin/auto_occupy.sh             Container one-shot command layer
bin/auto_occupy_worker.py      NPU worker (process name: auto-occupy)
bin/query_host_npu.sh          Host NPU process probe
host/auto-occupy-watchdog      Host systemd watchdog
systemd/auto-occupy-docker.service
systemd/guard.conf             Manual-stop protection drop-in
systemd/auto-occupy-refuse-stop
install.sh                     One-click installer
bootstrap.sh                   Optional curl-based one-line bootstrap
```
