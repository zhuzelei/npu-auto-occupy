import importlib.util
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "bin" / "query_npu_torch.py"
SPEC = importlib.util.spec_from_file_location("query_npu_torch", MODULE_PATH)
QUERY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QUERY)


class FakeNpu:
    def __init__(self, memory):
        self.memory = memory

    def device_count(self):
        return len(self.memory)

    def mem_get_info(self, device_id):
        return self.memory[device_id]


class QueryNpuTorchTest(unittest.TestCase):
    def test_empty_devices_produce_no_records(self):
        devices = QUERY.query_memory(
            FakeNpu([(90 * QUERY.MIB, 90 * QUERY.MIB)] * 8)
        )
        self.assertEqual(QUERY.build_records(devices, 512 * QUERY.MIB, []), [])

    def test_busy_device_produces_user_compatible_record(self):
        devices = QUERY.query_memory(
            FakeNpu(
                [
                    (90 * 1024 * QUERY.MIB, 90 * 1024 * QUERY.MIB),
                    (89 * 1024 * QUERY.MIB, 90 * 1024 * QUERY.MIB),
                ]
            )
        )
        records = QUERY.build_records(devices, 512 * QUERY.MIB, [])
        fields = records[0].split("\t")
        self.assertEqual(len(fields), 9)
        self.assertEqual(fields[0], "PROC")
        self.assertEqual(fields[2], "1")
        self.assertEqual(fields[6], "memory-busy")

    def test_auto_worker_takes_precedence_over_memory_heuristic(self):
        devices = QUERY.query_memory(FakeNpu([(1, 100), (1, 100)]))
        records = QUERY.build_records(devices, 0, [(42, "/opt/auto-occupy")])
        fields = records[0].split("\t")
        self.assertEqual(fields[1], "42")
        self.assertEqual(fields[2], "0,1")
        self.assertEqual(fields[6], "auto-occupy")

    def test_find_auto_workers_reads_proc_comm(self):
        with tempfile.TemporaryDirectory() as directory:
            proc_root = Path(directory)
            worker = proc_root / "42"
            worker.mkdir()
            (worker / "comm").write_text("auto-occupy\n", encoding="utf-8")
            other = proc_root / "43"
            other.mkdir()
            (other / "comm").write_text("python\n", encoding="utf-8")
            self.assertEqual(QUERY.find_auto_workers(proc_root), [(42, "")])

    def test_invalid_memory_data_fails_closed(self):
        with self.assertRaises(RuntimeError):
            QUERY.query_memory(FakeNpu([(101, 100)]))


if __name__ == "__main__":
    unittest.main()
