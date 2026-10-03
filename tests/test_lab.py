import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import lab


class LabSafetyTests(unittest.TestCase):
    def test_pid_reuse_cannot_select_the_controller_process(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(lab,'RUNTIME',Path(directory)):
            (Path(directory)/'qemu.pid').write_text(str(os.getpid()))
            with self.assertRaises(RuntimeError):lab.owned_pid()

    def test_prepare_refuses_existing_disk_before_downloading(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(lab,'RUNTIME',Path(directory)),patch.object(lab.urllib.request,'urlopen') as fetch:
            (Path(directory)/'proxmox-test.qcow2').touch()
            with self.assertRaises(RuntimeError):lab.prepare()
            fetch.assert_not_called()

    def test_running_lab_is_not_killed_or_replaced(self):
        with patch.object(lab,'owned_pid',return_value=123),patch.object(lab,'run') as run:
            lab.start()
            run.assert_not_called()

    def test_new_lab_binds_only_loopback(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(lab,'RUNTIME',Path(directory)),patch.object(lab,'owned_pid',return_value=None),patch.object(lab.os,'access',return_value=True),patch.object(lab,'run') as run,patch.object(lab.socket,'socket'):
            (Path(directory)/'proxmox-test.qcow2').touch()
            lab.start()
            args=run.call_args.args[0]
            nic=args[args.index('-nic')+1]
            self.assertIn('hostfwd=tcp:127.0.0.1:12222-:22',nic)
            self.assertIn('hostfwd=tcp:127.0.0.1:18006-:8006',nic)
            self.assertNotIn('hostfwd=tcp::',nic)


if __name__=='__main__':unittest.main()
