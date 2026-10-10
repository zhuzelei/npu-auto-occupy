#!/usr/bin/env python3

import os
import sys
from pathlib import Path


MIB = 1024 * 1024
AUTO_PROCESS_NAME = "auto-occupy"
BUSY_PROCESS_NAME = "memory-busy"


def load_npu_api():
    import torch
    import torch_npu

    npu = getattr(torch, "npu", None)
    if npu is None:
        npu = torch_npu.npu
    for method_name in ("device_count", "mem_get_info"):
        if not hasattr(npu, method_name):
            raise RuntimeError(f"torch NPU API does not provide {method_name}()")
    return npu


def query_memory(npu):
    device_count = int(npu.device_count())
    if device_count <= 0:
        raise RuntimeError("torch_npu reported no NPU devices")

    devices = []
    for device_id in range(device_count):
        try:
            memory_info = npu.mem_get_info(device_id)
        except TypeError:
            if not hasattr(npu, "set_device"):
                raise
            npu.set_device(device_id)
            memory_info = npu.mem_get_info()

        if not isinstance(memory_info, (tuple, list)) or len(memory_info) != 2:
            raise RuntimeError(
                f"device {device_id}: mem_get_info() returned invalid data"
            )
        free_bytes, total_bytes = (int(value) for value in memory_info)
        if total_bytes <= 0 or free_bytes < 0 or free_bytes > total_bytes:
            raise RuntimeError(
                f"device {device_id}: invalid memory values "
                f"free={free_bytes} total={total_bytes}"
            )
        devices.append((device_id, free_bytes, total_bytes))
    return devices


def find_auto_workers(proc_root=Path("/proc")):
    workers = []
    try:
        entries = proc_root.iterdir()
    except OSError:
        return workers

    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            process_name = (entry / "comm").read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if process_name != AUTO_PROCESS_NAME:
            continue
        try:
            cwd = os.readlink(entry / "cwd")
        except OSError:
            cwd = ""
        workers.append((int(entry.name), sanitize(cwd)))
    return sorted(workers)


def sanitize(value):
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def proc_record(pid, cards, name, cwd=""):
    card_list = ",".join(str(card) for card in cards)
    fields = (
        "PROC",
        str(pid),
        card_list,
        str(len(cards)),
        "0",
        "",
        name,
        sanitize(cwd),
        "",
    )
    return "\t".join(fields)


def build_records(devices, idle_max_used_bytes, auto_workers):
    cards = [device_id for device_id, _, _ in devices]
    if auto_workers:
        return [
            proc_record(pid, cards, AUTO_PROCESS_NAME, cwd)
            for pid, cwd in auto_workers
        ]

    records = []
    for device_id, free_bytes, total_bytes in devices:
        used_bytes = total_bytes - free_bytes
        if used_bytes > idle_max_used_bytes:
            records.append(proc_record(0, [device_id], BUSY_PROCESS_NAME))
    return records


def read_idle_threshold_bytes():
    raw_value = os.environ.get("NPU_IDLE_MAX_USED_MIB", "512")
    try:
        threshold_mib = int(raw_value)
    except ValueError as exc:
        raise RuntimeError("NPU_IDLE_MAX_USED_MIB must be an integer") from exc
    if threshold_mib < 0:
        raise RuntimeError("NPU_IDLE_MAX_USED_MIB must not be negative")
    return threshold_mib * MIB


def main():
    try:
        devices = query_memory(load_npu_api())
        threshold_bytes = read_idle_threshold_bytes()
        records = build_records(devices, threshold_bytes, find_auto_workers())
    except Exception as exc:
        print(f"torch_query_failed: {exc}", file=sys.stderr)
        return 1

    if records:
        print("\n".join(records))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
