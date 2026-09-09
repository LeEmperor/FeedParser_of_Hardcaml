#!/usr/bin/env python3
# University of Florida
# Author: Bohdan Purtell
# Module: "board_cases.py"
# Synthetic Phase 7 traffic, MII vectors and machine-checked UART board capture.
import argparse
import dataclasses
import datetime
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import termios
import time
import zlib

COUNTERS = ('packets', 'updates', 'end_of_event', 'diagnostics',
            'crc_errors', 'ip_errors', 'sequence_gaps', 'duplicates')
PORT = 31337


def message(entries=1, time_value=123):
    # CME Production schema 1/version 13, template 46; reserved padding is explicit.
    entry = struct.pack('<qiiIiBBBi', -123, 10, 1234, 7, 3, 2, 1, ord('0'), 9) + b'\0'
    body = struct.pack('<QB', time_value, 128) + b'\0\0'
    body += struct.pack('<HB', 32, entries) + entry * entries
    body += struct.pack('<H', 24) + b'\0' * 6  # empty order-ID group
    return struct.pack('<5H', 10 + len(body), 11, 46, 1, 13) + body


@dataclasses.dataclass(frozen=True)
class Case:
    name: str
    sequence: int
    counts: tuple
    expected: tuple
    port: int = PORT
    bad_crc: bool = False
    bad_ip: bool = False

    @property
    def payload(self):
        return struct.pack('<IQ', self.sequence, 99) + b''.join(
            message(count, 123 + index) for index, count in enumerate(self.counts))


def cases(include_errors=False):
    result = [
        Case('single_partial_tail', 100, (1,), (1, 1, 1, 0, 0, 0, 0, 0)),
        Case('multiple_messages', 101, (1, 2), (2, 4, 3, 0, 0, 0, 0, 0)),
        Case('sequence_gap', 103, (1,), (3, 5, 4, 1, 0, 0, 1, 0)),
        Case('duplicate', 103, (1,), (4, 5, 4, 2, 0, 0, 1, 1)),
        Case('after_duplicate', 104, (1,), (5, 6, 5, 2, 0, 0, 1, 1)),
        Case('filtered_port', 900, (1,), (5, 6, 5, 2, 0, 0, 1, 1), port=PORT + 1),
        Case('after_filtered', 105, (1,), (6, 7, 6, 2, 0, 0, 1, 1)),
    ]
    if include_errors:
        result += [
            Case('late_bad_fcs', 106, (1,), (7, 8, 7, 2, 1, 0, 1, 1), bad_crc=True),
            Case('bad_ip_checksum', 107, (1,), (8, 9, 8, 2, 1, 1, 1, 1), bad_ip=True),
        ]
    return result


def checksum(data):
    total = sum(struct.unpack('!%dH' % (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xffff) + (total >> 16)
    return (~total) & 0xffff


def ethernet(case):
    udp = struct.pack('!4H', 12345, case.port, 8 + len(case.payload), 0) + case.payload
    ip = bytearray(struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(udp), 0,
                               0x4000, 64, 17, 0, socket.inet_aton('192.168.1.10'),
                               socket.inet_aton('192.168.1.1')))
    struct.pack_into('!H', ip, 10, checksum(ip) ^ int(case.bad_ip))
    return bytes.fromhex('020000000001 deadbeef0002 0800') + ip + udp


def mii_frame(case):
    frame = ethernet(case)
    frame += b'\0' * max(0, 60 - len(frame))
    fcs = zlib.crc32(frame) ^ int(case.bad_crc)
    return b'\x55' * 7 + b'\xd5' + frame + struct.pack('<I', fcs)


def write_vectors(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'mii_vectors.txt').open('w') as stream:
        for case in cases(True):
            frame = mii_frame(case)
            stream.write(f'{len(frame):x} ' + ' '.join(f'{v:02x}' for v in frame)
                         + ' ' + ' '.join(f'{v:x}' for v in case.expected) + '\n')
            (directory / f'{case.name}.bin').write_bytes(case.payload)
    (directory / 'cases.json').write_text(json.dumps([
        dict(name=c.name, payload_bytes=len(c.payload), sequence=c.sequence,
             expected=dict(zip(COUNTERS, c.expected))) for c in cases(True)], indent=2) + '\n')


class UartReader:
    def __init__(self, device):
        self.fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        config = termios.tcgetattr(self.fd)
        config[0] = config[1] = config[3] = 0
        config[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        config[4] = config[5] = termios.B115200
        config[6][termios.VMIN] = config[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, config)
        termios.tcflush(self.fd, termios.TCIFLUSH)
        self.buffer = bytearray()
        self.raw = bytearray()

    def record(self, deadline):
        while time.monotonic() < deadline:
            start = self.buffer.find(b'CME7')
            if start >= 0:
                del self.buffer[:start]
                if len(self.buffer) >= 36:
                    record = struct.unpack('<8I', self.buffer[4:36])
                    del self.buffer[:36]
                    return record
            elif len(self.buffer) > 3:
                del self.buffer[:-3]
            if select.select([self.fd], [], [], max(0, deadline - time.monotonic()))[0]:
                data = os.read(self.fd, 4096)
                self.raw.extend(data)
                self.buffer.extend(data)
        raise TimeoutError('No complete CME7 UART record before timeout')


def provenance(networking):
    # Everything hashed here belongs to this repository except the one generated file
    # hardcaml_networking supplies, which check.sh stages into validation/vendor.
    root = Path(__file__).resolve().parents[2]
    paths = [root / 'cme_board_top.v', root / 'cme_mdp3_feed_parser.v',
             root / 'validation/vendor/hardcaml_udp_rx_64_with_mac.v',
             root / 'validation/constraints/cme_arty.xdc', root / 'docs/templates.xml']
    return dict(networking_revision=subprocess.check_output(
        ['git', '-C', str(networking), 'rev-parse', 'HEAD'], text=True).strip(),
        sha256={str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in paths if p.exists()})


def board_run(args):
    # Never append FCS on a NIC: its hardware generates the actual Ethernet FCS.
    report = dict(started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  device='xc7a100tcsg324-1', application_clock_mhz=25,
                  interface=args.iface, serial=args.serial, results=[], passed=False,
                  **provenance(args.networking))
    reader = UartReader(args.serial)
    try:
        baseline = reader.record(time.monotonic() + args.timeout)
        if baseline != (0,) * 8:
            raise RuntimeError(f'Reset the board before this run; counters are {baseline}')
        with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800)) as tx:
            tx.bind((args.iface, 0))
            for case in cases():
                tx.send(ethernet(case))
                deadline = time.monotonic() + args.timeout
                matched = 0
                observations = []
                result = dict(case=case.name, expected=dict(zip(COUNTERS, case.expected)),
                              observations=observations, passed=False)
                report['results'].append(result)
                while matched < 2:
                    observed = reader.record(deadline)
                    observations.append(dict(zip(COUNTERS, observed)))
                    matched = matched + 1 if observed == case.expected else 0
                    # All counters are monotonic within this short, reset-isolated run.
                    if any(a > b for a, b in zip(observed, case.expected)):
                        break
                result['passed'] = matched == 2
                if matched != 2:
                    raise RuntimeError(f'{case.name}: counter mismatch: {observed}')
                print(f'PASS {case.name}: {observed}', flush=True)
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        os.close(reader.fd)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        args.output.with_suffix('.uart.bin').write_bytes(reader.raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    vectors = commands.add_parser('vectors', help='write deterministic simulation inputs; sends no traffic')
    vectors.add_argument('directory', type=Path)
    run = commands.add_parser('run', help='send board cases and verify UART counters (CAP_NET_RAW required)')
    run.add_argument('--iface', required=True)
    run.add_argument('--serial', required=True)
    run.add_argument('--output', type=Path, required=True)
    run.add_argument('--timeout', type=float, default=8)
    run.add_argument('--networking', type=Path, default=Path('../hardcaml_networking'))
    args = parser.parse_args()
    if args.command == 'vectors':
        write_vectors(args.directory)
    else:
        board_run(args)


if __name__ == '__main__':
    main()
