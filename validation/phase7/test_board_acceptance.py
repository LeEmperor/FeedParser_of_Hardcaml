# University of Florida
# Author: Bohdan Purtell
# Module: "test_board_cases.py"
# Host capture must recover framing and preserve deadline/failure behavior.
import os
import pty
import struct
import time
import unittest

from board_cases import UartReader, cases, checksum, ethernet, mii_frame


class BoardCasesTests(unittest.TestCase):
    def test_network_fixtures(self):
        for case in cases(True):
            frame = ethernet(case)
            self.assertEqual(checksum(frame[14:34]) == 0, not case.bad_ip)
            self.assertEqual(struct.unpack('!H', frame[38:40])[0], len(case.payload) + 8)
            self.assertEqual(frame[42:], case.payload)
            self.assertEqual(mii_frame(case)[:8], b'\x55' * 7 + b'\xd5')

    def test_uart_resynchronizes_and_keeps_consecutive_records(self):
        master, slave = pty.openpty()
        reader = UartReader(os.ttyname(slave))
        try:
            # Keep a partial magic through a timeout, then finish it next read.
            os.write(master, b'garbageCME')
            with self.assertRaises(TimeoutError):
                reader.record(time.monotonic() + 0.02)
            expected = (6, 7, 6, 2, 0, 0, 1, 1)
            os.write(master, b'7' + struct.pack('<8I', *expected)
                     + b'CME7' + struct.pack('<8I', *expected))
            self.assertEqual(reader.record(time.monotonic() + 1), expected)
            self.assertEqual(reader.record(time.monotonic() + 1), expected)
            self.assertTrue(reader.raw.startswith(b'garbageCME7'))
        finally:
            os.close(reader.fd)
            os.close(master)
            os.close(slave)


if __name__ == '__main__':
    unittest.main()
