# Jool pacing measurements — 2026-10-06

These measurements use the nftpf v0.3.0 translation path plus the optional namespace-egress pacing implementation on this branch. They are observations of one WAN path, not a Jool performance ceiling or a general bandwidth guarantee.

Subsequent isolated tests inside Hytron and Akari HK reached multiple Gbps with pacing off. The 300 Mbps cap reduced their throughput. Keep it as an opt-in candidate for problematic WAN conditions; see the [configuration recommendations and four-test summary (Chinese)](jool-configuration-recommendations.zh-CN.md), [all 102 earlier WAN cases](benchmarks/jool-wan-2026-10-05-06.csv), and [164 controlled internal cases](benchmarks/jool-internal-2026-10-06.csv). Different durations and topologies are reported separately.

## Path and method

- Relay: Akari HK, one AMD EPYC vCPU, Debian 12, kernel `6.1.0-52-cloud-amd64`.
- Client and backend: Akari TW, one Xeon vCPU, Debian 12, kernel `6.1.0-49-cloud-amd64`.
- TW client → HK entry/translator → TW backend. This traverses two WAN legs and shares a TW CPU; it differs from a single-leg direct test.
- Jool kernel/userspace 4.1.15, iperf3 3.12, Realm 2.9.6. Both endpoints and the relay originally use BBR and `fq`.
- Each throughput sample measures 30 seconds after a three-second warmup. Reported rates are receiver payload rates. CPU is whole-machine utilization during measurement, not isolated Jool CPU.
- Use the same public addresses and isolated ports, alternate defaults and candidates, and repeat promising candidates. No data tests run concurrently.
- Record iperf JSON, 250 ms CPU samples, Jool statistics, link counters, qdisc counters, and TCP/softnet statistics around every case.
- Specify `-C bbr` in BBR tests and check both reported congestion algorithms. One deliberate comparator used CUBIC on both endpoints. A persistent iperf server retained CUBIC afterward; four mixed-algorithm samples (two forward and two reverse) were excluded.

## Results

IPv6 entry → IPv4 backend, four forward TCP streams:

| Configuration | Receiver Mbps, repeated samples | HK CPU | Meaning |
| --- | --- | --- | --- |
| Default v0.3.0 | 520.85, 505.38, 430.18, 412.21, 390.92 | 7–35% | Median 430.18 Mbps; substantial variation and retransmissions |
| Namespace egress `fq maxrate 300mbit` | 1096.35, 1116.35, 1114.65 | 48–50% | Median 1114.65 Mbps, about 2.59× default median |
| Same behavior through the new nftpf setting | 1120.20 | 48% | Runtime setting preserved the translator namespace |
| Sender socket pacing, 300 Mbps × 4 | 1149.43, 1154.90 | 34–35% | Useful where the sender exposes pacing; not equivalent to relay-only tuning |
| Realm default relay | 1222.27 | 54% | One 30-second comparator; no claim that tuned Jool universally exceeds Realm |

Namespace-only pacing at 300 Mbps also produced 1095.98 Mbps in reverse, 1092.97 Mbps through an IPv4 entry → IPv6 backend, and 1107.83 Mbps in reverse through that entry. A single forward stream was 275.63 Mbps under the cap, with 2,828 reported retransmissions. The rate cap limits that stream; the four-stream result is not a single-stream gigabit result.

The integrated nftpf command produced 1120.20/1097.57 Mbps through the IPv6 entry and 1096.03/1116.13 Mbps through the IPv4 entry. At 100 Mbps UDP with 1200-byte payloads, it delivered 99.98/99.96 Mbps with client-reported loss of 0.028%/0.053%. The later controlled tests identified inconsistent UDP omission accounting in iperf3 3.12's client-transferred report. Those legacy percentages are retained as reported and should not be compared precisely with the later receiver-local loss values. The new dataset uses backend-local JSON and checks its bytes/packet/loss accounting. Idle TCP/UDP echo medians were 26.78–26.90 ms paced and 26.81–26.84 ms unpaced, 30 requests per group with no errors; this is not a loaded-latency measurement. Unpaced IPv4-entry samples varied from 53.85 to 211.89 Mbps forward and 159.21 to 790.55 Mbps reverse, reinforcing the need for repeats.

Default forward retransmission counts across the five IPv6-entry samples had a median of 321,361; the three repeated namespace-pacing samples had a median of 26,826. Kernel and Jool counters did not show a corresponding translator, veth, softnet, or physical-qdisc drop increase in the initial slow sample. This does not prove the absence of WAN loss or locate its exact cause.

## Candidates not selected as defaults

- Disabling GSO, TSO, or all three GSO/TSO/GRO features did not establish a throughput improvement. TSO off increased relay CPU at similar throughput.
- Enabling veth GRO alone gave 590.72 Mbps in one case, insufficient to establish a robust benefit.
- MSS 1280 gave 398.64 Mbps; no corresponding MTU-exceeded counter growth was observed. No blanket MSS/MTU change was made.
- CUBIC gave 14.66 Mbps on this path. The relay's congestion-control setting does not select the algorithm of transparently forwarded TCP connections.
- `fq` without a cap on both ends of the veth gave 283.14 Mbps. A 250 Mbps cap on both ends gave 798.40 Mbps with about 60% relay CPU.
- A TBF at 1.2 Gbps on both ends gave 368.85/479.44 Mbps. Namespace-only `fq` pacing schedules each translated packet once and was selected.
- Raising the namespace flow cap to 500 Mbps gave 881.29/814.75 Mbps, with many retransmissions. Higher configured caps did not imply higher delivered rates on this path.
- Sender-only pacing did not fix every reverse sample. Gateway pacing and endpoint pacing must be evaluated separately.

## Using and reproducing the setting

The command below belongs to this development branch; the published v0.3.0 asset does not implement it.

```bash
sudo nftpf --jool-pacing 300
sudo nftpf --jool-status
# Repeat the same client test with pacing on and off.
sudo nftpf --jool-pacing off
```

The value is Mbps per scheduler flow, in each direction, for TCP and UDP. It is not an aggregate bandwidth cap. Actual payload throughput is lower than the configured cap and also depends on headers, loss, path capacity, and the kernel's flow classification. Pick a value for your line and concurrency. The default is off.

Use a separate client and backend when available. For a controlled port-forward test, start an iperf server on the backend and point the client at the forwarding entry:

```bash
# Backend: restrict access to the test peer and bind an appropriate address.
iperf3 -s -B BACKEND_ADDRESS -p BACKEND_PORT

# Client: preserve address/port/family and concurrency across all candidates.
iperf3 -c ENTRY_ADDRESS -p ENTRY_PORT -B CLIENT_ADDRESS \
  -t 30 -O 3 -P 4 -C bbr -J > forward.json
iperf3 -c ENTRY_ADDRESS -p ENTRY_PORT -B CLIENT_ADDRESS \
  -t 30 -O 3 -P 4 -C bbr -R -J > reverse.json

# Per-socket pacing comparison, separate from relay pacing.
iperf3 -c ENTRY_ADDRESS -p ENTRY_PORT -B CLIENT_ADDRESS \
  -t 30 -O 3 -P 4 -C bbr --fq-rate 300M -J > socket-paced.json
```

Validate both entry families, forward/reverse TCP, one and several streams, UDP at your intended rate, latency, and existing connections. Repeat and alternate configurations. Use equivalent load when comparing CPU. Record receiver throughput and packet-loss/retransmission evidence; do not infer usable speed from configuration values or relay CPU alone.

## Lifecycle and primary references

The implementation owns only a named `fq` queue on `nftpf0` inside each owned Jool namespace. It preserves the Jool instance and connections, leaves physical interfaces unchanged, and rejects foreign queues. The saved setting is included in backups; old backups restore it to off. Kernel integration tests verify enable/disable, reapply, an existing TCP connection, partial-update rollback, backup/import rollback, and foreign-resource coexistence.

The WAN tests used peer-restricted temporary listeners, separate nftables tables/namespaces and temporary binaries, with automatic cleanup timers. All remote test resources and locally built deployment payloads are removed after verification. Original services, addresses, routes, rules, packages, sysctls, offloads, and physical queues are compared with the saved baselines.

Final cleanup verification passed 36/36 checks on each host. All test listeners, processes, namespaces, links, tables, loaded Jool modules, timers, stage directories and scoped conntrack entries were removed. Original service PIDs and configuration hashes matched. An unused TBF module left by an earlier candidate was separately verified unused and unloaded. The first batch's automatic cleanup also completed without errors. Raw local evidence contains 44 throughput cases; 40 are eligible after excluding the four mixed-algorithm CUBIC-retention samples, plus eight 30-request latency groups. Rejected samples are retained with their actual congestion-algorithm metadata.

- [Jool FAQ](https://www.jool.mx/en/faq.html): translator statistics and throughput troubleshooting.
- [Jool issue 366](https://github.com/NICMx/Jool/issues/366): the historical GRO bug was fixed in 4.1.8; it is not evidence of the same bug in 4.1.15.
- [Linux segmentation offloads](https://docs.kernel.org/networking/segmentation-offloads.html): GSO/TSO metadata and segmentation behavior.
- [Linux TCP sysctls](https://docs.kernel.org/networking/ip-sysctl.html#tcp-variables): endpoint congestion-control behavior.
- [iperf3 manual](https://software.es.net/iperf/invoking.html): bitrate, socket pacing, warmup, reverse tests, and JSON output.
