# `rpll` — RedPitaya Phase-Locked Loop project

This repository contains a complete **RedPitaya Zynq** (FPGA + ARM Linux) design:

- **Two-channel digital PLL "phasemeter"** — frequency/phase readout via all-digital phase-locked loop
- **Laser optical phase-locked loop** — lock up to two transponder lasers to a primary laser via an optical phase-locked loop
- **Python GUI client** — connects over TCP, live plots and controls

The code is organized in **three layers**, each in its own directory. These directories are tracked as **git submodules** so that a single clone gives you one aligned snapshot of FPGA, server, and client.

## The three layers

| Directory     | Role |
|---------------|------|
| **rpll_fpga** | RTL + Vivado TCL; builds bitstreams for RedPitaya 125-14 and 250-12 |
| **rpll_server** | C program on the RedPitaya ARM (Zynq PS): maps FPGA memory, streams binary frames over TCP, runs the command protocol |
| **rpll_client** | Python GUI: decodes frames, sends commands, displays plots |

The top-level build and deploy scripts in this repo target these directories.

## Getting an aligned copy (submodule workflow)

Clone the repository and all submodules in one go:

```bash
git clone --recurse-submodules git@github.com:mdovale/rpll.git
```

You then have **rpll_fpga**, **rpll_server**, and **rpll_client** at the exact commits recorded in this repo, so the three layers stay in sync.

If you already cloned without submodules, populate them with:

```bash
git submodule update --init --recursive
```

### Updating the pinned versions

When you want to use a newer (or different) ref of a submodule:

1. Enter the submodule and check out the ref you want (branch or tag):
   ```bash
   cd rpll_client
   git fetch
   git checkout v2.1.0
   cd ..
   ```
2. Record that ref in this repo:
   ```bash
   git add rpll_client
   git commit -m "Pin rpll_client to v2.1.0"
   git push
   ```

Do the same for **rpll_server** and **rpll_fpga** when you change them. Anyone who clones with `--recurse-submodules` will then get that aligned triple.

## Supported boards

- **rp125_14**: RedPitaya 125-14 (Zynq-7010), Vivado **2017.2**
- **rp250_12**: RedPitaya 250-12 (Zynq-7020), Vivado **2020.2**

Details for each board (top modules, output paths) are in **rpll_fpga/README.md**.

## ADC sampling rate (design constraint)

**Both boards use an effective processing rate of 125 MSPS.** Scope, FFT, and phasemeter pipeline run at 125 MHz (Nyquist 62.5 MHz).

- **rp125_14**: ADC samples at 125 MHz → full bandwidth.
- **rp250_12**: ADC samples at 250 MHz, but the data path runs at 125 MHz (`adc_clk2d`); every other sample is used, so effective 125 MSPS.

Using the full 250 MSPS on the 250-12 would require changing the pipeline to 250 MHz.

## Build variants (server)

The server can be built in two modes:

- **laser_lock** (default): phasemeter + servo/lock controls
- **phasemeter**: readout only; server reports this and the GUI hides laser-lock controls

Select with `--variant` on the server build scripts.

## Quick start

You need: a **bitstream** for your board, the **server** binary on the RedPitaya, and the **Python GUI** on your machine.

### 1) Build the FPGA bitstream

From the repo root:

```bash
./fpga-build.sh --target rp125_14
# or
./fpga-build.sh --target rp250_12
```

Output (under **rpll_fpga**):

- `…/work125_14/rpll.runs/impl_1/laser_lock.bit.bin` (125-14)
- `…/work250_12/rpll.runs/impl_1/laser_lock.bit.bin` (250-12)

The scripts generate **.bit.bin** with `bootgen` when available (needed for RedPitaya OS 2.x+).

### 2) Build the server

Cross-compile (needs `gcc-arm-linux-gnueabihf`):

```bash
./server-build-cross.sh
```

Phasemeter-only:

```bash
./server-build-cross.sh --variant phasemeter
```

Docker:

```bash
./server-build-docker.sh --variant phasemeter
```

Binaries go to **build-cross/** or **build-docker/**; deploy with **server-deploy.sh**.

### 3) Deploy to the RedPitaya

**Server** (copy binary):

```bash
./server-deploy.sh --ip <redpitaya-ip>
```

**FPGA** (OS 2.x+ with `fpgautil`):

```bash
./fpga-deploy.sh --target rp125_14 --ip <redpitaya-ip>
# or
./fpga-deploy.sh --target rp250_12 --ip <redpitaya-ip>
```

### 4) Run the GUI client

```bash
cd rpll_client
pip install -e .
python main.py
```

The server listens on **TCP port 1001**.

## Repository layout

- **rpll_client/**: Python GUI client (PySide6 + pyqtgraph)
- **rpll_server/esw/**: embedded server
- **rpll_fpga/**: Vivado TCL + RTL for rp125_14 and rp250_12
- **.gitmodules**: submodule URLs

Build scripts accept **FPGA_DIR** and **SERVER_DIR** so you can overwrite the **rpll_fpga** and **rpll_server** path.

## Protocol and data model

- **Transport**: TCP, default port **1001** (see **rpll_server/rp_protocol.h** or **server/rp_protocol.h**).
- **Frames**: stream of IEEE‑754 doubles; size **RP_FRAME_SIZE_BYTES**.
- **Commands**: binary (address + value) applied by the server to FPGA registers.
- **Handshake**: on connect the server sends one line, e.g. `RP_CAP:laser_lock\n` or `RP_CAP:phasemeter\n`.

Frame layout and parsing are in **rpll_client/frame_schema.py** and **data_models.py**; they must match the server (see **rpll_server/esw/memory_map.h** and **rp_protocol.h**).

## Keeping the three layers in sync

The three codebases share:

- **Wire protocol** (port, frame size, FFT size, command addresses, capability string) — server and client must agree.
- **Frame layout** (order of doubles in each frame) — server fills it, client parses it.
- **Memory map** (FPGA AXI addresses) — server and FPGA must match.

When you change any of these, update the affected subrepos and then update the pinned refs in this repo so that a clone with `--recurse-submodules` still gives a compatible set.

## Tests

**Client** (no Qt, no network):

```bash
cd rpll_client
pip install -e ".[dev]"
pytest
```

**Server** (no FPGA needed):

```bash
cd rpll_server/esw
make test
```
