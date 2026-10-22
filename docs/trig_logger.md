# Trigger Logger Design (`trig_logger`)

Not an MCA. Three inputs, one 64-bit record per external digital trigger: a
boxcar-averaged energy, a piezo direction, and a clock-cycle timestamp. Reuses
`event_logger`'s proven back end (ping-pong BRAM → CDMA → DDR → host) with a
new front end, so the host driver is a close parallel of `event_logger.py`.

```
ADC ─┬─ chA = IN1 (tdata[15:0])  ──► boxcar(n_avg) ──┐
     └─ chB = IN2 (tdata[31:16]) ──► dir thresholds ─┤
                                                     ├─► trig_logger ─► BRAM(64b) ─┐
exp_p[7:0] ++ exp_n[7:0] ──► trig_bus ──► trig_sel ──┘                             │
                                                                      AXI BRAM Ctrl│
                                                                            └─ CDMA ┘──► DDR ──► PC
```

## Record (64-bit, little-endian)

| bits | field | notes |
|---|---|---|
| `[45:0]`  | timestamp | **clock cycles**, 8 ns at 125 MHz; 46-bit ⇒ 6.5-day wrap |
| `[47:46]` | direction | signed 2-bit: `00`=0, `01`=+1, `11`=−1 (`10` unused) |
| `[63:48]` | energy | **signed int16**, the boxcar average as computed |

46 + 2 + 16 = 64 exactly, no spare bits and no padding.

Two deliberate differences from `event_logger`, both of which remove a footgun
that design has:

- **Energy is a plain signed int16**, the whole averaged value — not the low
  15 bits of a positive peak height. There is no 15-vs-16-bit ambiguity to get
  wrong and no silent factor of 2.
- **The timestamp is clock cycles, not microseconds.** There is no prescaler
  register at all, so there is nothing to misconfigure; the cost is the 6.5-day
  wrap. For a longer run, pass the records through `unwrap_ts()` before
  converting to seconds — the tie-point stream makes the rollover unambiguous.
  Do not assert `clear_ts` mid-run.

## Front end

- **Boxcar** — running sum plus a BRAM delay line, `n_avg = 2^log_n_avg` so the
  divide is an exact right shift (no divider, no rounding error). Ceiling is
  `MAX_LOG_AVG` = 11, i.e. 2048 samples = 16.4 µs. The delay line is one power
  of two deeper than the largest window so the read pointer never collides with
  the address being written, which keeps the design off any reliance on
  inferred-BRAM read-before-write behaviour.

  The window is **primed** after reset and after any `log_n_avg` change: the
  subtracted sample is forced to 0 for the first `n_avg` samples, so the sum is
  a true `n_avg`-sample sum the moment `avg_ready` rises. Triggers before
  `avg_ready` are rejected, so no record ever carries a half-filled window —
  the first record of a run is as trustworthy as the last.

- **Direction** — `IN2 ≥ dir_thr_pos` ⇒ +1, `IN2 ≤ dir_thr_neg` ⇒ −1, between
  ⇒ 0, sampled at the trigger edge. Both thresholds reset to 0, which means the
  **default is a hard sign test with no dead zone** — set them before arming if
  the piezo signal sits near zero. If the pair is crossed over (`pos` < `neg`),
  +1 wins.

- **Trigger** — `trig_bus[trig_sel]`, XORed with `trig_invert`, 2FF-synchronised
  and rising-edge detected. `trig_sel` runs 0–15 over `exp_p[0..7]` then
  `exp_n[0..7]`, so **which DIO pin you use is a register write, not a
  rebuild** — worth knowing because no other project in this repo has ever
  wired the expansion pins into the fabric, so the pin numbering is untested in
  hardware. `status[6]` (`trig_level`) reads the synchronised pin state, which
  is the quickest way to confirm you are on the right pin before arming.

## Timing

```
trigger edge ──► latch timestamp + direction
                 wait n_delay cycles
                 latch boxcar output ──► write record ──► trig_dead holdoff
```

The timestamp and direction are the values **at the trigger edge**; the energy
is the boxcar output **`n_delay` cycles later**. The boxcar itself costs 3
clock cycles of pipeline, so the latched value is the average of the `n_avg`
samples ending ~3 cycles before the `n_delay` deadline — fold that into
`n_delay` if it matters at your pulse shape. The record reaches BRAM one cycle
after the latch.

**Dead time is `n_delay + trig_dead`.** A trigger arriving inside it is ignored
and counted in `skipped`; it is not queued and not logged. So `skipped` is a
*rate* problem (triggers faster than the module can service) and `dropped` is a
*host* problem (both BRAM buffers full because the PC did not drain in time) —
two different counters for two different failures, worth checking separately.
`trig_dead` also doubles as debounce for a noisy trigger.

## Back end

Unchanged from `event_logger`: ping-pong double buffer (2 × 4096 × 64-bit),
fills one while the PS drains the other, swaps on full or on the `flush_ticks`
timeout so a low trigger rate still yields data. A full buffer whose
predecessor has not been acked is held, not overwritten. `snap` latches the
counter for a coherent 46-bit read, and the host keeps writing `tiepoints.csv`
exactly as before.

`flush_ticks` counts **clock cycles**, not microseconds — there is no
prescaler. 100 ms = 12 500 000. `TrigLogger.configure(flush_ms=...)` does this
conversion for you.

## Register map (base `0x40004000` + 4·index)

| off | reg | fields |
|---|---|---|
| 0x00 | control | `[0]`arm `[1]`clear_ts `[2]`reset `[3]`snap `[4]`ack |
| 0x04 | frame_len | records/buffer, 1..4096 (`2^(ADDR_BITS-1)`) |
| 0x08 | flush_ticks | **clock cycles** before a partial-buffer swap (0=never) |
| 0x0C | log_n_avg | `[3:0]` boxcar = 2^log_n_avg samples, clamped to 11 |
| 0x10 | n_delay | `[31:0]` cycles from trigger to energy latch |
| 0x14 | trig_dead | `[31:0]` holdoff cycles after a record |
| 0x18 / 0x1C | dir_thr_pos / dir_thr_neg | signed (both reset to 0) |
| 0x20 | trig_cfg | `[3:0]`trig_sel `[4]`trig_invert |
| 0x30 | status (ro) | `[0]`ready `[1]`ready_buf `[2]`dropped≠0 `[3]`skipped≠0 `[4]`busy `[5]`avg_ready `[6]`trig_level |
| 0x34 / 0x38 | ready_count / dropped | ro |
| 0x3C / 0x40 | ts_snap_lo / hi | ro (tie-point read; hi = ts`[45:32]`, 14 bits) |
| 0x44 / 0x48 | events_lo / hi | ro |
| 0x4C | skipped | ro (triggers ignored: busy, dead, or not primed) |
| 0x50 | live | ro `[15:0]`energy_now (signed) `[17:16]`dir_now |

The register bank is 32 words (`LOG_NPAR=5`), regs 0–11 writable and 12–31
read-only, so there is room to add fields without moving anything.

## Simulation

`rtl/trig_logger.v` has a self-checking testbench — 43 checks covering the
boxcar (constants, a known 4-sample window, negative input, priming, re-priming,
clamping), direction coding, record packing, the `n_delay` latch, re-trigger
rejection, the ping-pong/ack cycle, `trig_invert` and `trig_sel`. It also dumps
`records.hex`, which `sim/check_records.py` decodes with the **real host
driver**, so an RTL-vs-host layout disagreement fails in simulation instead of
surfacing as a mangled energy axis weeks into an experiment. See
[../sim/README.md](../sim/README.md).

```bash
cd sim
xvlog tb_trig_logger.v ../rtl/trig_logger.v && xelab tb_trig_logger -s tbsim
xsim tbsim -runall && python check_records.py
```

## Block design: what still has to be done in the GUI

`projects/trig_logger/bd.tcl` is currently a **byte-identical copy of
`mca_timestamp_1ch`** — the seed, per [new_project.md](new_project.md) step 1.
The RTL, the config and the host driver are finished and tested; the block
design is not, and it needs the GUI because `write_bd_tcl` output is not safe
to hand-edit around address segments and interconnect master counts.

Regenerate and open it:

```bash
vivado -mode batch -source scripts/make_project.tcl -tclargs trig_logger
```

Then, in the block design:

1. **Add the trigger pins.** `exp_p_tri_io` and `exp_n_tri_io` exist as `IO`
   ports in every project in this repo but have never been connected to
   anything. Delete both and re-create them as **inputs**
   (`-dir I -from 7 -to 0`, same names — `constr/ports.xdc` matches by name and
   only sets `PACKAGE_PIN`/`IOSTANDARD`, so direction comes from the HDL).
   Add one `xlconcat` (2 ports, 8 bits each): `In0` = `exp_p_tri_io`,
   `In1` = `exp_n_tri_io`, giving `trig_bus[15:0]` with `exp_p` in the low
   bits — which is what `trig_sel` 0–15 assumes.

2. **Swap the logger.** Inside the `event_log` hierarchy, delete
   `event_logger_0` and add a module reference to `trig_logger_axi_wrap`
   (`trig_logger_0`). Reconnect, in place of the three old boundary pins
   (`peak_detected`, `peak_value_in`, `chb_raw`):

   | `trig_logger_0` pin | source |
   |---|---|
   | `x_in` | `adc/Dout0` — `tdata[15:0]`, channel A = IN1 |
   | `dir_in` | `adc/Dout1` — `tdata[31:16]`, channel B = IN2 |
   | `trig_bus` | the new `xlconcat` output |

   `bram_addr` / `bram_din` / `bram_en` / `bram_we` go back to the same
   `bram_interface_0` Port-B pins, and `s_axi` / `s_axi_aclk` / `s_axi_aresetn`
   to the same interconnect master and clock nets. The BRAM port widths are
   identical (13-bit address, 64-bit data), so nothing downstream changes.

3. **Keep the address.** `trig_logger_0/s_axi/reg0` must land at
   `0x40004000`, matching `config/trig_logger.json`. It inherits
   `event_logger_0`'s segment if you reassign in the Address Editor.

4. **Optional — strip the MCA chain.** `iir1st_minimal_0`, `fir9_minimal_0`,
   `peak_detector_0` and `peak_height_binning_0` are no longer in the signal
   path. Leaving them in place costs LUTs/DSPs/BRAM but is the smaller change,
   so it is the better first build: get a bitstream working, confirm the
   trigger pin and direction thresholds against hardware, *then* delete them
   (and their interconnect masters and address segments) and rebuild.

5. Save the recipe back and build:

```
write_bd_tcl -force -include_layout projects/trig_logger/bd.tcl
```

```bash
vivado -mode batch -source scripts/build.tcl -tclargs trig_logger
cp projects/trig_logger/trig_logger.bit ../redpitaya_control/bitfiles/
```

> **Re-run `make_project.tcl`, not just `build.tcl`, after any edit to
> `rtl/trig_logger.v`.** Editing the RTL behind a module-reference block does
> not invalidate that block's out-of-context synthesis run, so `build.tcl`
> alone links the stale `.dcp` and silently ships a bitstream mixing new
> top-level logic with an old module. See `LESSONSLEARNED.md` — this is exactly
> what produced the `event_logger` veto-tag mismatch.

## Host usage

```python
from redpitaya_control import redpitaya_dev
from redpitaya_control.trig_logger import (
    TrigLogger, unpack, load_run, unwrap_ts, fit_clock, counter_to_unix)

dev = redpitaya_dev("171.64.56.120", "config/trig_logger.json")
dev.base.load_bitfile()

log = TrigLogger(dev)
log.configure(n_avg=4,          # boxcar samples, power of two, <= 2048
              n_delay=16,       # CYCLES, trigger -> energy latch (16 = 128 ns)
              dir_thr=0.1,      # +/- volts on IN2; outside = +1/-1, inside = 0
              trig_sel=0,       # exp_p[0]
              flush_ms=100)
print(log.status())             # check trig_level / avg_ready before arming
log.run(duration=60, output_dir="run1")   # None = until Ctrl+C

ts, energy, direction = unpack(load_run("run1/events_*.bin"))
a, b, ppm = fit_clock("run1/tiepoints.csv")       # b ~ 8.0 ns/cycle
t_abs = counter_to_unix(unwrap_ts(ts), a, b)
```

`log.status()` is the bring-up tool: `trig_level` confirms the pin, `avg_ready`
confirms the boxcar primed, `energy_now` / `dir_now` show the live front end
without arming, and `skipped` vs `dropped` separate a rate problem from a host
problem.
