# Build scripts

Vivado projects are treated as disposable build output. The single source of
truth for each project is `projects/<name>/bd.tcl` (the block-design recipe),
together with the shared `rtl/`, `cores/` and `constr/` directories. Everything
else under `projects/<name>/` is generated and gitignored.

All scripts run headless: `vivado -mode batch -source scripts/<script>.tcl -tclargs <project_name>`.

## One-time: capture a legacy project into git

```
vivado -mode batch -source scripts/export_bd.tcl -tclargs mca_simple_1ch
```

Opens the existing `projects/mca_simple_1ch/mca_simple_1ch.xpr`, writes
`projects/mca_simple_1ch/bd.tcl`, and closes. Commit that file. Repeat per
project. Validate the round-trip (below) for at least the tricky designs before
trusting it.

## Regenerate a project from its recipe

```
vivado -mode batch -source scripts/make_project.tcl -tclargs mca_simple_1ch
```

Creates `projects/mca_simple_1ch/build/mca_simple_1ch.xpr` from scratch: adds
`rtl/` + `cores/` + `constr/`, rebuilds the block design from `bd.tcl`,
generates and imports the wrapper, sets it as top. Open that `.xpr` in the GUI
to work as usual.

## Build a bitstream

```
vivado -mode batch -source scripts/build.tcl -tclargs mca_simple_1ch
```

Runs implementation to `write_bitstream` and stages the result at
`projects/mca_simple_1ch/mca_simple_1ch.bit`. Copy that into the
`redpitaya_control` repo's `bitfiles/` directory.

## Validate a round-trip

After exporting, confirm the recipe reproduces the design:

```
vivado -mode batch -source scripts/make_project.tcl -tclargs mca_simple_1ch
```

Open the regenerated project, compare the block design against the original,
and (ideally) build and diff the bitstream. `write_bd_tcl` occasionally mangles
unusual IP configuration, so this check matters most for the streaming (CDMA /
BRAM) and z_control_v* projects.

## Transient batch-mode failures

Running many headless Vivado sessions back-to-back can trip a flaky Tcl
sub-interpreter, surfacing as one of:

```
ERROR: Could not create slave interpreter 'rodin:slave0'
couldn't read file ".../design_assist/conn/axi4/utils.tcl": No error
ERROR: [Ip 78-90] Error in initialization of Rule object 'xilinx.com:bd_rule:axi4:1.0'
```

These are not recipe or script defects (the named file exists and is
readable) -- just re-run the same command and it will normally pass. Seen
during both `make_project.tcl` and `build.tcl`; a single retry has always
cleared it.

## Check a config against its wrapper

```
python scripts/check_regmap.py rtl/trig_logger_axi_wrap.v ../redpitaya_control/config/trig_logger.json trig_logger
```

Confirms every `offset` in the config JSON lands on the register index the
Verilog wrapper actually uses (`regs[N]` is at offset `4*N`). Nothing else
enforces that, and a register moved in the HDL but not in the JSON reads
plausible rubbish rather than failing -- which is what
`Fix MCA timestamp IIR and FIR addresses` was. Run it after touching either
side. Exits non-zero on a mismatch, so it drops straight into a pre-commit hook.

## Everyday workflow

- **New design:** regenerate (or GUI Save As) a starting project, edit the block
  design and add modules in the GUI, build. When done, in the Tcl console run
  `write_bd_tcl -force -include_layout projects/<name>/bd.tcl` and commit.
- **Modify a design:** open the regenerated project, edit, rebuild, then re-run
  `write_bd_tcl -force` and commit the diff.
