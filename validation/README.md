# Board validation host setup

Host-side setup for the Phase 7 Arty harness. The board procedure itself — programming,
controls, the acceptance run, the UART record and the counter tuples — is in
[docs/phase7_integration.md](../docs/phase7_integration.md); this document covers only
preparing the host Ethernet interface so that nothing but test traffic reaches the board.

| Path | Contents |
| --- | --- |
| `board/` | The Hardcaml harness: Arty top, validation core (port select) and observability sink. |
| `constraints/cme_arty.xdc` | Board constraints, including the DP83848J MII receive model. |
| `phase7/board_cases.py` | Fixed pass/fail acceptance sequence and MII vector generation. |
| `phase7/check.sh` | Regenerates the RTL and runs the full simulation gate. |
| `send_frames.py` | Flexible sender for soak runs, arbitrary shapes and malformed injections. |

## Prepare the host interface

The examples use this USB Ethernet interface, which is also `DEFAULT_IFACE` in
`phase7/board_cases.py`:

```bash
export FPGA_IFACE=enx207bd25880ef
```

Confirm that the cable and PHY have established a link:

```bash
ip -br link show dev "$FPGA_IFACE"
sudo ethtool "$FPGA_IFACE" | grep -E 'Speed:|Duplex:|Link detected:'
```

The expected link is 100 Mb/s, full duplex, with `Link detected: yes`. The validation
profile assumes 100BASE-TX; at 10 Mb/s the PHY drives 2.5 MHz MII clocks, which needs a
different constraint set and breaks the UART divisor.

## Quiet raw-Ethernet setup (recommended)

Both senders open `AF_PACKET`/`SOCK_RAW` bound directly to the interface and only ever
transmit; results come back over the USB UART, never over Ethernet. The interface
therefore needs no IPv4 or IPv6 address, no route and no ARP.

Leaving it managed normally causes the host to emit IPv6 neighbor discovery, multicast
membership, mDNS, ARP and possibly DHCP each time a board reset cycles the PHY link —
which is exactly when the acceptance run starts.

The single most important step is removing the IPv4 address. An address implies a kernel
link route:

```text
192.168.1.0/24 proto kernel scope link src 192.168.1.1
```

and that route makes the interface a legal egress for subnet broadcast and multicast.
Everything else follows from it: host daemons broadcast into the subnet, Avahi advertises
on any interface that has an address, and ARP has something to resolve. Unmanaging the
device in NetworkManager does *not* remove an address that is already configured.

On a NetworkManager host, temporarily make the validation interface unmanaged, disable
IPv6 on that interface, remove its addresses, and leave the link up:

```bash
sudo nmcli device set "$FPGA_IFACE" managed no
sudo sysctl -w "net.ipv6.conf.${FPGA_IFACE}.disable_ipv6=1"
sudo ip address flush dev "$FPGA_IFACE"
sudo ip link set dev "$FPGA_IFACE" arp off        # NOARP: never emit ARP on this port
sudo ip link set dev "$FPGA_IFACE" multicast off  # no group joins, no MLD/mDNS egress
sudo ip link set dev "$FPGA_IFACE" up
ip -br address show dev "$FPGA_IFACE"
```

Omit the `nmcli` command on a system that does not use NetworkManager.

`arp off` and `multicast off` are safe for this harness: a bound raw `AF_PACKET` socket
bypasses ARP, the multicast layer and the routing table entirely, and the harness never
transmits, so there is nothing to receive back. Clear them with `arp on` / `multicast on`
before putting the interface back to ordinary use.

### Why this is not optional here

Port selection protects parser state but not the network counters. `cme_validation_core`
admits only destination UDP port `31337` to the parser, so traffic on other ports drains
without touching sequence state. But in `cme_validation_sink` the network counters are
evaluated per received frame, ahead of that filter:

```text
crc_errors  <- crc_pending & crc_error_i
ip_errors   <- rx_frame_done_i & ~checksum_ok_i
```

`Ipv4_rx` only asserts `checksum_ok` for EtherType `0x0800` with a `0x45` first header
byte, so background IPv6 mDNS, ARP or DHCP frames arrive with `checksum_ok_i` low and are
eligible to move `ip_errors`. The acceptance sequence asserts absolute counters —
`13, 237, 33, 4, 0, 0, 2, 2`, with `crc_errors` and `ip_errors` at zero — from a baseline
that `board_cases.py` requires to be all zeros. Host chatter after the reset can break the
baseline check, the final tuple, or both.

`send_frames.py --serial` compares before/after deltas against its own model rather than
absolute values, so it tolerates a noisy link better, but the counters it reports are still
polluted.

## Confirming the interface is actually idle

With the board programmed and sitting untouched, the correct steady state is: PHY link LED
solid, PHY activity LED dark, and only `led0_r` blinking on the Arty. Any blinking of the
PHY activity LED at idle means the host is still talking to the board.

```bash
ip -br address show dev "$FPGA_IFACE"           # want: UP, no addresses listed
ip route show dev "$FPGA_IFACE"                 # want: empty
sudo timeout 30 tcpdump -ni "$FPGA_IFACE" -c 20 # want: no packets for 30 s
```

If packets still appear, identify the sender by port rather than guessing:

```bash
ss -ulpn | grep <port>
```

Two sources are easy to miss because they are not part of the normal desktop network
stack:

- **Vivado broadcasts on UDP port 1534.** An open Vivado session — likely open, since it
  programmed the board — binds `0.0.0.0:1534` and beacons to the subnet broadcast address
  of every addressed interface, which shows up in Wireshark as
  `192.168.1.1 -> 192.168.1.255  UDP  1534 -> 1534  Len=8`. There is no setting to scope
  this to one interface; leaving the validation interface unaddressed is the fix.
- **`avahi-daemon` emits mDNS** to `224.0.0.251:5353` on any interface that has an
  address, and `cups-browsed` browses over it. Flushing the address is enough, but the
  exclusion can be made durable in `/etc/avahi/avahi-daemon.conf` so that re-adding an
  address later does not reopen it:

  ```bash
  sudo sed -i 's/^#deny-interfaces=eth1/deny-interfaces=enx207bd25880ef/' \
      /etc/avahi/avahi-daemon.conf
  sudo systemctl restart avahi-daemon
  ```

## Wireshark filters

The senders craft frames for MAC `02:00:00:00:00:01`, IPv4 `192.168.1.10 -> 192.168.1.1`,
UDP `12345 -> 31337`, with a fixed source MAC that is not the host NIC's:

```text
eth.dst == 02:00:00:00:00:01    # every frame aimed at the harness
udp.dstport == 31337            # only the traffic the parser will admit
eth.src == 02:00:00:00:00:01    # must stay empty: see below
```

The last filter should never match. The harness ties `eth_tx_en` low and `eth_txd` to
zero, so the FPGA never transmits; anything on this link that the senders did not put
there came from the host.

## Restore normal host networking

After a quiet run:

```bash
sudo sysctl -w "net.ipv6.conf.${FPGA_IFACE}.disable_ipv6=0"
sudo ip link set dev "$FPGA_IFACE" arp on
sudo ip link set dev "$FPGA_IFACE" multicast on
sudo nmcli device set "$FPGA_IFACE" managed yes
sudo ip link set dev "$FPGA_IFACE" up
```

The `arp on` and `multicast on` lines undo the flags set above. Without them the interface
stays `NOARP` after it is handed back to NetworkManager, which breaks normal IPv4 use in a
way that is not obvious from `ip -br link`.

Reapply a static address manually if the connection is meant to keep one:

```bash
sudo ip address replace 192.168.1.1/24 dev "$FPGA_IFACE"
```

## Upstream

This procedure is adapted from the `hardcaml_networking` board validation runbook
(`validation/README.md` in that repository), which covers the same host setup for its
five MAC/UDP harnesses. Those harnesses use Scapy and are full-duplex, so their runbook
also documents an addressed setup and echo testing; neither applies to this receive-only
harness.
