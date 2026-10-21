"""Check a config JSON's register offsets against its AXI wrapper's HDL.

The `base` + `offset` in each redpitaya_control config must match the register
index the Verilog wrapper actually uses -- `regs[N]` sits at offset 4*N. Nothing
enforces that: a register moved in the HDL and not in the JSON reads plausible
rubbish, which is how `Fix MCA timestamp IIR and FIR addresses` happened.

    python scripts/check_regmap.py rtl/trig_logger_axi_wrap.v \
        ../redpitaya_control/config/trig_logger.json trig_logger

Exits non-zero on any mismatch. It reads the wrapper's
`wire NAME = regs[N]` lines for writable registers and the `regs[N] <= ...`
bodies for read-only ones, so it follows the house wrapper template rather
than a hand-maintained table.

ALIAS covers the few places a JSON name deliberately differs from the HDL
signal: `reset` is `ctrl_reset`, a 64-bit counter is split into `_lo`/`_hi`,
and several status bits share one packed word.
"""
import json
import re
import sys

ALIAS = {
    'reset': 'ctrl_reset',
    'status': 'ready',
    'ts_snap_lo': 'ts_snap', 'ts_snap_hi': 'ts_snap',
    'events_lo': 'total_events', 'events_hi': 'total_events',
    'trig_invert': 'trig_sel',
    'chb_threshold': 'chb_thr',       # event_logger shortens it in the HDL
}


def check(wrapper_path, config_path, module):
    v = open(wrapper_path).read()
    regs = json.load(open(config_path))['modules'][module]['registers']

    rw = {m.group(1): int(m.group(2)) for m in re.finditer(
        r'wire\s+(?:signed\s+)?(?:\[[^\]]+\]\s+)?(\w+)\s*=\s*regs\[(\d+)\]', v)}
    bodies = {int(m.group(1)): m.group(2) for m in re.finditer(
        r'regs\[(\d+)\]\s*<=\s*([^;]+);', v)}
    ctrl = {m.group(1) for m in re.finditer(
        r'wire\s+(\w+)\s*=\s*control\[\d+\]', v)}

    fails = []
    for name, r in sorted(regs.items(), key=lambda kv: kv[1]['offset']):
        sig, idx = ALIAS.get(name, name), r['offset'] // 4
        if r.get('readonly'):
            # the hi word of a split counter sits one register above the lo word
            body = bodies.get(idx, '')
            good, why = bool(re.search(rf'\b{sig}\b', body)), f'regs[{idx}] body'
        elif sig in ctrl:
            good, why = idx == 0, 'control bit field, regs[0]'
        else:
            good, why = rw.get(sig) == idx, f'wire = regs[{rw.get(sig)}]'
        print(f"  {'ok  ' if good else 'BAD '} {name:<14} 0x{r['offset']:02x} -> {why}")
        if not good:
            fails.append(name)

    print(f"\n{len(regs) - len(fails)} agree, {len(fails)} mismatched")
    if fails:
        print("MISMATCHES: " + ", ".join(fails))
        return 1
    print("ALL REGISTER OFFSETS AGREE")
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(check(*sys.argv[1:4]))
