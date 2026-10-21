# Vivado GUI How-To

Practical recipes for the block-design edits that come up in this repo. For
creating a project from a template see [new_project.md](new_project.md); for the
headless scripts see [../scripts/README.md](../scripts/README.md).

## Three ground rules

Almost every "my pin doesn't work" problem is one of these.

**1. The BD port name determines the top-level HDL name, and `ports.xdc` matches
by that name.** `constr/ports.xdc` is shared by every project and binds purely
on port names, so a port named differently in the BD is a port the constraints
cannot see. Names are case-sensitive.

For a plain port the name passes straight through: BD port `exp_p_tri_io` →
`exp_p_tri_io[7:0]` at the top. For an **interface** port, Vivado flattens the
bundle to `<port>_<signal lowercased>`: BD port `Vaux8` carrying a
`diff_analog_io_rtl` interface (signals `V_P`, `V_N`) →
`Vaux8_v_p` / `Vaux8_v_n`, which is exactly what `ports.xdc` asks for. You
control only the `Vaux8` part.

**2. An interface port that isn't connected never reaches the wrapper.** A
dangling *plain* port survives (as an unused `inout`), but a dangling
*interface* port is dropped entirely — so its XDC lines match nothing. This is
not hypothetical: `mca_timestamp_1ch` declares `Vp_Vn`, `Vaux0`, `Vaux1`,
`Vaux8` and `Vaux9` without connecting any of them, and its implementation run
emits **20** of these:

```
WARNING: [Vivado 12-584] No ports matched 'Vaux8_v_p'. [constr/ports.xdc:152]
CRITICAL WARNING: [Common 17-55] 'set_property' expects at least one object.
```

So the order is **create the port, connect it, then** the XDC line does
something. Adding the constraint first achieves nothing on its own.

**3. Regenerate the HDL wrapper after any change to the top-level port list.**
Sources → right-click `system.bd` → **Create HDL Wrapper** → *Let Vivado manage
wrapper and auto-update* → overwrite. Changing a port's direction, name or
existence leaves the imported wrapper stale, and a stale wrapper silently keeps
the old port list.

## Which "Create" do I want?

| What you need | Menu | Shortcut |
|---|---|---|
| Plain scalar/vector port (digital I/O, e.g. `exp_p_tri_io`) | Create Port | Ctrl+K |
| Interface port (a bundle, e.g. `Vaux8`, AXI, `diff_analog_io`) | Create Interface Port | Ctrl+L |
| Either one, auto-named and auto-connected from a block pin | right-click the pin → Make External | Ctrl+T |

**Make External is the safest route** — it picks the right type, the right mode
and names the port after the pin. Its one failure mode is a **name collision**:
if a port of that name already exists, Vivado appends `_0`, you get `Vaux8_0` →
`Vaux8_0_v_p`, and the XDC quietly matches nothing. Since the projects in this
repo are full of dangling ports, **delete the dangling port first**, then Make
External, and no renaming is needed.

To rename a port anyway: select it on the canvas and edit the **Name** field in
the *External Interface Properties* (or *External Port Properties*) pane.
Right-click has no rename entry for ports, which is why it's easy to miss. You
cannot rename onto a name already in use.

## Verify before you build

Two commands in the Tcl console, worth the five seconds before a 20-minute
implementation run:

```
get_ports Vaux8_v_p
```

Non-empty means the port exists at the top level and the XDC will bind. Empty
means you are about to reproduce the critical warning above.

```
report_drc -checks {NSTD-1 UCIO-1}
```

Flags I/O that has no `IOSTANDARD` or no `PACKAGE_PIN`. These two DRCs are
errors at `write_bitstream`, so catching them here saves a full run.

## Enabling an aux analog input (XADC)

### What is physically available

The 16 XADC auxiliary channels map to **fixed device pins** — you do not get to
choose them — and Red Pitaya routes only **four** to the E2 connector. So there
are exactly four aux analog inputs, all already constrained in `ports.xdc`.
Note that the silkscreen labels do **not** match the VAUX numbers:

| E2 label | VAUX | DRP channel | pins (p / n) |
|---|---|---|---|
| Analog IN 0 | VAUX**8** | `0x18` | B19 / A20 |
| Analog IN 1 | VAUX**0** | `0x10` | C20 / B20 |
| Analog IN 2 | VAUX**1** | `0x11` | E17 / D18 |
| Analog IN 3 | VAUX**9** | `0x19` | E18 / E19 |

There is nothing to add to `ports.xdc` for any of them.

### Steps

Reference implementation: `projects/analog_aux`, which reads VAUX8.

1. **Delete the dangling port.** Click the existing `Vaux8` interface port →
   Delete. (Likewise `Vaux0`/`Vaux1`/`Vaux9`/`Vp_Vn` if unused — they are the
   source of those 20 critical warnings.)
2. **Add the core.** Add IP → Add Module → `xadc_4ch` (or `xadc_1ch`).
3. **Make the pin external.** Right-click the block's `Vaux8` pin → Make
   External. With the dangling port gone it is named `Vaux8`, so
   `Vaux8_v_p`/`Vaux8_v_n` appear at the top and the XDC binds.
4. **Clock and reset.** `clk` ← the 125 MHz `pll_0/clk_out1` net (the core
   divides DCLK by 5 → 25 MHz); `rst` ← an `xlconstant` with
   `CONST_VAL = 0`, i.e. tied low — this is what `analog_aux` does.
5. **Route the output.** `out_aux_8` is a plain 16-bit wire from there on. Send
   it wherever you need it — `analog_aux` sends it to `dac/In0` to scope it, and
   bundles `dbg_raw`/`dbg_channel`/`dbg_drdy`/`dbg_cycles_per_sample` through an
   `xlconcat` into an `axi_gpio` at `0x41200000` to read from software.
6. Regenerate the wrapper, `get_ports Vaux8_v_p`, build.

The manual equivalent of step 3, if you prefer Ctrl+L — mode **Slave**, since
it is an input to the FPGA:

```
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 Vaux8
```

### Which core to use

- **`cores/xadc_1ch.v`** — VAUX8 only, *single-channel* mode
  (`INIT_41` SEQ=`0011`). The channel is selected by `INIT_40[4:0] = 0x18`.
- **`cores/xadc_4ch.v`** — declares VAUX0/1/8/9, *continuous sequence* mode
  (`INIT_41` SEQ=`0010`). Gives `out_aux_0/1/8/9`, `valid_*` and the `dbg_*`
  bundle. Note its Verilog declares all four but `analog_aux` connects only
  `Vaux8`; the rest sit tied low.

**Adding a channel needs no Verilog edit.** All 16 VAUX channels are already
enabled in the sequencer, so connecting the port and routing `out_aux_N` is the
whole job.

### Two mislabelled constants

Both work, but the comments will mislead you if you try to "enable" a channel by
editing them.

**`xadc_4ch.v` has `INIT_48`/`INIT_49` swapped in its comments.** Per UG480,
register `48h` is Sequence Register 0 (on-chip sensors + VP/VN) and `49h` is
Sequence Register 1 (VAUX`[15:0]`, bit N = VAUX N). So `INIT_48(16'h0303)`,
commented *"Enable VAUX0,1,8,9"*, actually enables on-chip sensor channels, and
`INIT_49(16'hFFFF)`, commented *"Disable all calibration channels"*, actually
**enables all 16 VAUX channels**. The design works because of that `0xFFFF`.

A side effect: the sequencer scans ~20 channels when you care about one to four,
so the per-channel update rate is several times lower than necessary. Trimming
`INIT_49` to just the bits in use speeds it up roughly proportionally;
`dbg_cycles_per_sample` measures the DCLK cycles between samples, so you can see
the difference directly.

**`xadc_1ch.v`'s `INIT_48(16'h0100)` is a no-op.** Single-channel mode ignores
the sequencer registers entirely, so the comment *"Enable VAUX8 in sequencer
(bit 8)"* is wrong twice over — wrong register, and bit 8 of `48h` is
Temperature, not VAUX8. `INIT_40` is what selects the channel there.

### Reading the value

The XADC returns its 12-bit result left-justified in `DO[15:4]`, and the cores
do `out_aux_N <= data >> 2`, which leaves the 12-bit code in `[13:2]`. So
**`out_aux_N` is the code × 4**, despite the header comment saying the useful
sample is `[15:4]`; divide by 4 host-side. The input-mode registers `4Ch`/`4Dh`
are never written, so all channels default to **unipolar**: 0 → +1 V at the ADC
pin. Red Pitaya's E2 front end divides down from a larger range, so calibrate
against a known voltage rather than assuming a scale factor.

## Enabling a digital input (DIO)

### What is available

All 16 expansion-connector pins are already constrained in `ports.xdc`
(`PACKAGE_PIN` + `IOSTANDARD LVCMOS33`), so again **nothing to add there**. The
catch is different: no project in this repo has ever connected them to the
fabric, so the mapping is untested in hardware.

**`_p` and `_n` are not a differential pair.** Despite the naming these are 16
independent single-ended 3.3 V pins; `exp_n_tri_io[3]` is just as usable on its
own as `exp_p_tri_io[3]`. Pick whichever is convenient on the connector.

| BD port bit | FPGA pin | E1 signal | bit in a p-then-n concat |
|---|---|---|---|
| `exp_p_tri_io[0]` | G17 | DIO0_P | 0 |
| `exp_p_tri_io[1]` | H16 | DIO1_P | 1 |
| `exp_p_tri_io[2]` | J18 | DIO2_P | 2 |
| `exp_p_tri_io[3]` | K17 | DIO3_P | 3 |
| `exp_p_tri_io[4]` | L14 | DIO4_P | 4 |
| `exp_p_tri_io[5]` | L16 | DIO5_P | 5 |
| `exp_p_tri_io[6]` | K16 | DIO6_P | 6 |
| `exp_p_tri_io[7]` | M14 | DIO7_P | 7 |
| `exp_n_tri_io[0]` | G18 | DIO0_N | 8 |
| `exp_n_tri_io[1]` | H17 | DIO1_N | 9 |
| `exp_n_tri_io[2]` | H18 | DIO2_N | 10 |
| `exp_n_tri_io[3]` | K18 | DIO3_N | 11 |
| `exp_n_tri_io[4]` | L15 | DIO4_N | 12 |
| `exp_n_tri_io[5]` | L17 | DIO5_N | 13 |
| `exp_n_tri_io[6]` | J16 | DIO6_N | 14 |
| `exp_n_tri_io[7]` | M15 | DIO7_N | 15 |

### Check what state the port is in

You will already see `exp_p_tri_io[7:0]` and `exp_n_tri_io[7:0]` on the canvas —
they are in every project here. Two Tcl-console checks tell you whether they are
usable:

```
get_property DIRECTION [get_bd_ports exp_n_tri_io]
```

Returns `IO` in every stock project — bidirectional, so there is nothing for a
module input to consume.

```
get_bd_nets -of_objects [get_bd_ports exp_n_tri_io]
```

Returns empty, i.e. dangling. Note the name has a single underscore before
`tri` (`exp_n_tri_io`), and `ports.xdc` matches purely on that spelling.

### Steps

Unlike the Vaux case these are **plain vector ports**, so it is Ctrl+K, not
Ctrl+L or Make External. And because they already exist with the wrong
direction, you **delete and recreate** rather than edit — direction comes from
the HDL, and there is no way to flip it on an existing BD port.

1. Click the `exp_p_tri_io` port → Delete.
2. Right-click empty canvas → **Create Port…** (Ctrl+K):
   - Port name: `exp_p_tri_io` — exactly, the XDC matches by name
   - Direction: **Input**
   - Type: Other
   - ☑ Create vector, from **7** down to **0**
3. Repeat for `exp_n_tri_io` if you need the N pins too.
4. Wire it to your module. To expose all 16 as one bus, add an `xlconcat`
   (2 ports × 8 bits): `In0` ← `exp_p_tri_io`, `In1` ← `exp_n_tri_io`, then
   `dout[15:0]` → your module's input. `In0` takes the low bits, which is what
   produces the concat column in the table above.
5. Regenerate the wrapper, `get_ports exp_p_tri_io[0]`, build.

For a single pin you can skip the concat and slice instead — an `xlslice` with
`DIN_FROM`/`DIN_TO` both set to the bit you want — but the concat is worth it if
the consuming module selects its pin at runtime, since then the choice of
physical pin is a register write rather than a rebuild. `trig_logger` is built
that way: see its `trig_sel` register, where the concat column above *is* the
`trig_sel` value ([trig_logger.md](trig_logger.md)).

### Before wiring anything to the connector

**The DIO pins are 3.3 V LVCMOS and are not 5 V tolerant.** A 5 V TTL source
needs a divider or level shifter; this is the one mistake here that damages
hardware.

**A floating input will self-trigger.** On an edge-detecting input an
unconnected pin picks up noise and produces phantom events. There is no pull
configuration anywhere in `constr/` today; if you want one:

```
set_property PULLTYPE PULLDOWN [get_ports {exp_p_tri_io[*]}]
set_property PULLTYPE PULLDOWN [get_ports {exp_n_tri_io[*]}]
```

Bear in mind `ports.xdc` is shared by all projects, so that goes into every
future bitstream — harmless on an otherwise-dangling pin, but it is a global
change.

## Saving back and building

The `build/` directory is disposable; your work is not saved until the recipe is
rewritten. In the Tcl console:

```
write_bd_tcl -force -include_layout projects/<name>/bd.tcl
```

Then commit that `bd.tcl` — it is the only tracked output. Build with:

```
vivado -mode batch -source scripts/build.tcl -tclargs <name>
```

> **After editing any `rtl/*.v`, re-run `make_project.tcl`, not just
> `build.tcl`.** Editing RTL behind a module-reference block does not
> invalidate that block's out-of-context synthesis run, so `build.tcl` alone
> relinks the stale `.dcp` and silently ships a bitstream mixing new top-level
> logic with an old module. See `LESSONSLEARNED.md`.

> A headless run can throw `Could not create slave interpreter 'rodin:slave0'`
> or an axi4 rule error. Not a real defect — re-run the same command once.
