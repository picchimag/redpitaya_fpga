# Simulation

Self-checking testbenches, run with the `xsim` that ships with Vivado. No
project needed -- compile the testbench plus the module under test, elaborate,
run. From the repo root:

```bash
cd sim
xvlog tb_trig_logger.v ../rtl/trig_logger.v
xelab tb_trig_logger -s tbsim
xsim tbsim -runall
```

The last line prints one `PASS`/`FAIL` per check and ends with
`=== 0 error(s) ===` / `ALL CHECKS PASSED`. A testbench is worth more than a
bitstream here: the stale-out-of-context-IP trap in `LESSONSLEARNED.md` means a
rebuilt `.bit` can silently carry old RTL, whereas `xvlog` always reads the
file on disk.

`xvlog`/`xelab`/`xsim` live in `C:/Xilinx/Vivado/2024.1/bin` -- add that to
`PATH` or call them by full path. `xelab` leaves an `xsim.dir/` behind; it is
gitignored.

## Testbenches

- **`tb_trig_logger_axi.v`** -- `rtl/trig_logger_axi_wrap.v`. 25 checks over a
  real AXI4-Lite master: every writable register round-trips, the read-only
  words reject writes (including both sides of the regs[11]/regs[12] boundary),
  `wstrb` masks correctly, and the status/live words report the module's actual
  state. Worth having because this wrapper changes the house template's
  geometry (`LOG_NPAR` 4 -> 5, `N_READONLY` 8 -> 20).

  ```bash
  xvlog tb_trig_logger_axi.v ../rtl/trig_logger_axi_wrap.v ../rtl/trig_logger.v
  xelab tb_trig_logger_axi -s axisim && xsim axisim -runall
  ```

- **`tb_trig_logger.v`** -- `rtl/trig_logger.v`. 43 checks: boxcar average
  (constants, a known 4-sample window, negative input, priming, re-priming on a
  window change, `log_n_avg` clamping), direction coding against both
  thresholds, record field packing, the `n_delay` energy latch, re-trigger
  rejection into `skipped`, buffer fill -> `ready`/`ready_count`/`ack` ->
  ping-pong swap, `ts_snap`, `trig_invert`, `trig_sel`.

## Cross-checking the record layout against the host

`tb_trig_logger.v` also writes `records.hex`, one 64-bit record per line,
straight off the BRAM write port. `check_records.py` decodes that file with
`redpitaya_control.trig_logger.unpack` -- the very function that reads the
`.bin` files from a real run:

```bash
xsim tbsim -runall && python check_records.py
```

It prints the decoded timestamp / direction / energy per record and ends with
`RTL AND HOST LAYOUTS AGREE`. This is the check worth having: the event_logger
v1-vs-v2 record layout mismatch was silent on the FPGA and on the host, and
only showed up as an energy axis off by 2x. Run it after touching either the
record packing in `trig_logger.v` or `unpack()` in `trig_logger.py`.

## A note on event_logger

`rtl/event_logger_axi_wrap.v` cannot be compiled by `xvlog` as it stands: it
declares the module's read-only output wires *below* the register-bank `always`
block that samples them, and `xvlog` rejects the forward reference
(`VRFC 10-3380`). Vivado synthesis accepts it, which is why the shipped
bitstream is fine -- but it does mean that wrapper has never been simulated.
`trig_logger_axi_wrap.v` declares those wires above the bank instead, so it
compiles under both front ends. Moving the declarations in `event_logger_axi_wrap.v`
would make it simulable too; that is a one-block edit to a working, deployed
design, so it has deliberately been left alone.
