#!/usr/bin/env python3
# University of Florida
# Author: Bohdan Purtell
# Module: "send_frames.py"
# Flexible CME MDP 3.0 test-frame sender for the Phase 7 Arty board harness.
#
# Unlike validation/phase7/board_cases.py -- which sends one fixed acceptance
# sequence and pass/fails it -- this script builds arbitrary traffic: chosen
# sequence numbers, messages per packet, entries per message, destination port,
# repeats and deliberate gap/duplicate injection. It can send on a raw socket,
# or just write frames to disk (no CAP_NET_RAW needed). With --serial it reads
# the harness UART snapshots and reports the counter deltas the traffic caused,
# next to the deltas the reference model predicts.
#
# Packet construction is imported from board_cases.py so the SBE encoding stays
# single-sourced and stays covered by the XML oracle in phase7_contracts.ml.
import argparse
import json
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / 'phase7'))
import board_cases  # noqa: E402
from board_cases import COUNTERS, PORT, Case, UartReader, ethernet, mii_frame  # noqa: E402


class Model:
    """Predicts harness counters. Mirrors the single-feed sequencer rules the
    Phase 7 cases exercise: sequence advances one per accepted packet; a forward
    jump raises a gap and still parses; a stale sequence raises a duplicate and
    drops the payload. Predictions are a convenience, not the acceptance oracle."""

    def __init__(self):
        self.counts = dict.fromkeys(COUNTERS, 0)
        self.next_sequence = None

    def observe(self, case):
        if case.port != PORT:
            return  # filtered before the parser; only network status can move
        self.counts['packets'] += 1
        duplicate = self.next_sequence is not None and case.sequence < self.next_sequence
        gap = self.next_sequence is not None and case.sequence > self.next_sequence
        if gap:
            self.counts['diagnostics'] += 1
            self.counts['sequence_gaps'] += 1
        if duplicate:
            self.counts['diagnostics'] += 1
            self.counts['duplicates'] += 1
            return
        self.counts['updates'] += sum(case.counts)
        self.counts['end_of_event'] += len(case.counts)
        self.next_sequence = case.sequence + 1

    @property
    def expected(self):
        return tuple(self.counts[name] for name in COUNTERS)


def plan(args):
    """Expand the command line into the ordered list of packets to transmit."""
    counts = tuple(args.entries for _ in range(args.messages))
    sequence = args.sequence
    packets = []
    for index in range(args.count):
        packets.append(Case(f'packet_{index}', sequence, counts, (), port=args.port))
        if index in args.duplicate_after:
            packets.append(Case(f'duplicate_{index}', sequence, counts, (), port=args.port))
        sequence += 1
        if index in args.gap_after:
            sequence += args.gap_size
    return packets


def snapshot(reader, timeout, settle):
    """Return a counter record that is stable across two consecutive snapshots."""
    deadline = time.monotonic() + timeout
    previous = reader.record(deadline)
    while time.monotonic() < deadline:
        current = reader.record(deadline)
        if current == previous:
            return current
        previous = current
    raise TimeoutError('UART counters never settled; traffic may still be arriving')


def run(args):
    packets = plan(args)
    model = Model()
    for case in packets:
        model.observe(case)
    report = dict(interface=args.iface, serial=args.serial, port=args.port,
                  packets=[dict(name=c.name, sequence=c.sequence, port=c.port,
                                messages=len(c.counts), payload_bytes=len(c.payload),
                                frame_bytes=len(ethernet(c))) for c in packets],
                  predicted_delta=dict(zip(COUNTERS, model.expected)))

    if args.dump is not None:
        args.dump.mkdir(parents=True, exist_ok=True)
        for case in packets:
            (args.dump / f'{case.name}.eth.bin').write_bytes(ethernet(case))
            (args.dump / f'{case.name}.mii.bin').write_bytes(mii_frame(case))
        print(f'Wrote {2 * len(packets)} frame files to {args.dump}')

    reader = before = None
    if args.serial is not None:
        reader = UartReader(args.serial)
        before = snapshot(reader, args.timeout, args.settle)
        report['before'] = dict(zip(COUNTERS, before))
        print(f'UART before: {dict(zip(COUNTERS, before))}')

    try:
        if args.iface is not None:
            # The NIC generates the real Ethernet FCS: never append the simulation one.
            import socket
            with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800)) as tx:
                tx.bind((args.iface, 0))
                for case in packets:
                    tx.send(ethernet(case))
                    print(f'sent {case.name}: seq={case.sequence} port={case.port} '
                          f'{len(case.counts)} message(s)', flush=True)
                    if args.interval:
                        time.sleep(args.interval)

        if reader is not None:
            after = snapshot(reader, args.timeout + args.settle, args.settle)
            delta = tuple(b - a for a, b in zip(before, after))
            report['after'] = dict(zip(COUNTERS, after))
            report['observed_delta'] = dict(zip(COUNTERS, delta))
            report['matched'] = delta == model.expected
            print(f'UART after:  {dict(zip(COUNTERS, after))}')
            for name, observed, predicted in zip(COUNTERS, delta, model.expected):
                flag = ' ' if observed == predicted else '<-- differs'
                print(f'  {name:<13} observed {observed:>6}  predicted {predicted:>6} {flag}')
            print('MATCH' if report['matched'] else 'MISMATCH')
    finally:
        if reader is not None:
            import os
            os.close(reader.fd)
            if args.raw_uart is not None:
                args.raw_uart.parent.mkdir(parents=True, exist_ok=True)
                args.raw_uart.write_bytes(reader.raw)
        if args.output is not None:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2) + '\n')

    if reader is not None and not report.get('matched'):
        raise SystemExit(1)


def integers(text):
    return set() if not text else {int(v) for v in text.split(',')}


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='Examples:\n'
               '  # dump frames only, no privileges and no board needed\n'
               '  python3 validation/send_frames.py --dump _build/frames --count 4\n'
               '  # send 20 packets with a gap after #5 and a duplicate after #9,\n'
               '  # then compare the UART counter delta against the model\n'
               '  sudo python3 validation/send_frames.py --iface enp1s0 \\\n'
               '      --serial /dev/ttyUSB1 --count 20 --gap-after 5 --duplicate-after 9\n')
    parser.add_argument('--iface', help='network interface to transmit on (needs CAP_NET_RAW)')
    parser.add_argument('--serial', help='harness UART device, e.g. /dev/ttyUSB1')
    parser.add_argument('--dump', type=Path, help='write .eth.bin/.mii.bin frames here instead of/besides sending')
    parser.add_argument('--count', type=int, default=1, help='number of packets to send (default 1)')
    parser.add_argument('--sequence', type=int, default=100, help='starting MDP packet sequence (default 100)')
    parser.add_argument('--messages', type=int, default=1, help='SBE messages per packet (default 1)')
    parser.add_argument('--entries', type=int, default=1, help='MBP entries per message (default 1)')
    parser.add_argument('--port', type=int, default=PORT,
                        help=f'destination UDP port; only {PORT} reaches the parser (default {PORT})')
    parser.add_argument('--gap-after', type=integers, default=set(), metavar='N[,N...]',
                        help='skip sequence numbers after these zero-based packet indices')
    parser.add_argument('--gap-size', type=int, default=1, help='sequence numbers skipped per gap (default 1)')
    parser.add_argument('--duplicate-after', type=integers, default=set(), metavar='N[,N...]',
                        help='resend these zero-based packet indices immediately')
    parser.add_argument('--interval', type=float, default=0.0, help='seconds between packets (default 0)')
    parser.add_argument('--timeout', type=float, default=8.0, help='UART record timeout in seconds (default 8)')
    parser.add_argument('--settle', type=float, default=3.0,
                        help='extra seconds allowed for counters to settle after sending (default 3)')
    parser.add_argument('--output', type=Path, help='write a JSON report here')
    parser.add_argument('--raw-uart', type=Path, help='write captured raw UART bytes here')
    args = parser.parse_args()
    if args.iface is None and args.dump is None:
        parser.error('nothing to do: pass --iface to transmit, --dump to write frames, or both')
    if args.messages < 1 or args.entries < 1 or args.count < 1:
        parser.error('--count, --messages and --entries must all be at least 1')
    run(args)


if __name__ == '__main__':
    main()
