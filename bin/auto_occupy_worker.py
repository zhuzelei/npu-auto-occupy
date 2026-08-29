#!/usr/bin/env python3

import ctypes
import os
import signal
import time


def set_process_name(name):
    try:
        libc = ctypes.CDLL("libc.so.6")
        libc.prctl(15, name.encode(), 0, 0, 0)
    except Exception:
        try:
            with open("/proc/self/comm", "w", encoding="utf-8") as comm_file:
                comm_file.write(name[:15])
        except OSError:
            pass


set_process_name("auto-occupy")

import torch
import torch_npu


STOP = False


def stop_handler(signum, frame):
    del frame
    global STOP
    STOP = True
    release_file = os.environ.get("WORKER_RELEASE_FILE")
    if release_file:
        try:
            with open(release_file, "w", encoding="utf-8") as marker:
                marker.write(f"signal={signum}\n")
        except OSError:
            pass


def main():
    memory_gib = int(os.environ.get("MEMORY_GIB_PER_DEVICE", "50"))
    device_count = torch_npu.npu.device_count()
    if device_count <= 0:
        raise RuntimeError("torch_npu reported no NPU devices")

    bytes_per_device = memory_gib * 1024 * 1024 * 1024
    holders = []
    for device_index in range(device_count):
        torch_npu.npu.set_device(device_index)
        holders.append(torch.empty(bytes_per_device, dtype=torch.uint8, device=f"npu:{device_index}"))

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    signal.signal(signal.SIGHUP, stop_handler)
    while not STOP:
        time.sleep(5)

    holders.clear()
    for device_index in range(device_count):
        try:
            torch_npu.npu.set_device(device_index)
            torch_npu.npu.empty_cache()
        except Exception:
            pass


if __name__ == "__main__":
    main()
