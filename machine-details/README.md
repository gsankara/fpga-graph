# Machine details for the Design P measurements

Captured 2026-10-31 for the three-arm latency comparison in
`../RESULTS_PARTITION.md`. One file per machine.

| file | role | machine |
|---|---|---|
| `nrp-csg-2fpga.txt` | **NRP arm**, both partitions | NRP Coder `csg-2fpga`, 2 of 6 U55C exposed |
| `nrp-compile-boxes.txt` | built all 4 bitstreams | `csg-fpga-compile0` (U280), `csg-fpga-compile3` (U55C) |
| `oct-pc170.txt` | **OCT arm**, partition 0 (coordinator) | CloudLab UMass `pc170` |
| `oct-pc174.txt` | **OCT arm**, partition 1 (worker) | CloudLab UMass `pc174` |
| `fabric-part0-losa.txt` | **FABRIC arm**, partition 0 (coordinator) | FABRIC LOSA, host `losa-w2` |
| `fabric-part1-gpn.txt` | **FABRIC arm**, partition 1 (worker) | FABRIC GPN, host `gpn-w3` |

## Summary

| | NRP `csg-2fpga` | OCT `pc170` / `pc174` | FABRIC `part0` / `part1` |
|---|---|---|---|
| card | 2 × U55C (of 6 present) | 1 × U280 each | 1 × U280 each |
| PCI id | `505c`/`505d` | `500c`/`500d` | `500c`/`500d` |
| shell | `..._u55c_..._base_3` | `..._u280_..._base_1` | `..._u280_..._base_1` |
| logic UUID | `97088961-FEAE-DA91-52A2-1D9DFD63CCEF` | `283BAB8F-654D-8674-968F-4DA57F7FA5D7` | `283BAB8F-654D-8674-968F-4DA57F7FA5D7` |
| CPU | 4 cores | Intel Xeon Gold 6142 @ 2.60 GHz, 64 threads | AMD EPYC 7543 / 7532, 8 vCPU |
| RAM | 187 GB | 566 GB | 32 GB |
| OS | Ubuntu 24.04.5 | Ubuntu 22.04.2, kernel 5.15.0-198 | Ubuntu 22.04.5, kernel 5.15.0-185 |
| XRT | 2.19.194 (2025.1) | 2.16.204 (2023.2) | 2.16.204 (2023.2) |
| g++ | 13.3.0 | 11.4.0 | 11.4.0 |
| machine kind | container/VM on a shared host | bare metal | VM, PCI passthrough |

Both OCT nodes are identical hardware (same CPU, same kernel, same BIOS), which
is why they make a clean pair. The two FABRIC nodes differ slightly in CPU model
(EPYC 7543 vs 7532) — irrelevant here, since the FPGA does the work and the
exchange is network-bound.

## Two reading traps in these files

**1. `lspci` overcounts on NRP.** `csg-2fpga` shows **6** U55C cards (12
functions), all bound to `xclmgmt`/`xocl`, but only **2** are exposed to the
workspace — there are exactly two `/dev/dri/renderD*` and two `/dev/xclmgmt*`
nodes. `xbutil examine` shows the two you can actually open. Trust it over
`lspci`.

**2. `DLActive-` is meaningless on the FABRIC VMs.** Both FABRIC nodes report:

```
bus 1f via 00:05.6 : Speed 8GT/s Width x16 DLActive-
```

while their cards are fully `Ready`. The root port there is a **virtual**
bridge inside the VM, so its link-state bits do not reflect the physical slot.
On bare metal (OCT) the same query is meaningful and reads
`Speed 8GT/s Width x16 DLActive+`.

This matters because `Width x0 / DLActive-` on bare metal *is* the signature of
an electrically dark card — it is how `pc171`, `pc172` and `pc175` were
diagnosed as unrecoverable. Applying that test to a VM would produce a false
positive. Check `Width`, not `DLActive`, and only trust either on bare metal.

## Provenance

`oct-*` and `fabric-*` are single live capture runs of
`scratchpad/capture-machine.sh` (read-only).

`nrp-csg-2fpga.txt` and `nrp-compile-boxes.txt` are **assembled from
timestamped session captures**, not single runs: the Coder agent for
`csg-2fpga` lost connection at 05:58, 06:00 and 06:03 UTC (a Coder-side fault,
the workspace was still running), and `csg-fpga-compile3` had been stopped.
Every value in them was read off those machines during the session; fields that
were never probed are marked `not probed` rather than guessed.
