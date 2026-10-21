"""Decode the records tb_trig_logger.v produced with the real host driver.

Closes the loop between the RTL's record packing and the host's unpack(): the
testbench writes records.hex straight out of the BRAM write port, and this
script decodes it with redpitaya_control.trig_logger.unpack -- the same
function that will read the .bin files off a real run. A layout disagreement
between RTL and host shows up here instead of as a mangled energy axis weeks
into an experiment.

Run from sim/ after `xsim tbsim -runall`:

    python check_records.py

Expects redpitaya_control to be importable (it is installed, or sits next to
redpitaya_fpga -- both are tried).
"""
import os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
for cand in (os.path.join(HERE, "..", "..", "redpitaya_control"),):
    if os.path.isdir(cand):
        sys.path.insert(0, os.path.abspath(cand))

from redpitaya_control.trig_logger import unpack

# What tb_trig_logger.v drives, in testbench order.
# (energy, direction) for each record; None = do not check.
EXPECTED = [
    (4000,  -1),   # 5. first armed trigger
    (4000,  -1),   # 6. re-trigger test (second edge skipped, this is the first)
    (8000,  -1),   # 7. energy latched n_delay after the trigger
    (8000,  -1),   # 8. fourth record, fills the buffer
    (8000,  -1),   # 8. fifth record, lands in buffer 1
    (8000,  -1),   # 10. trig_invert, falling edge
    (8000,  -1),   # 11. trig_sel = 7
]

path = os.path.join(HERE, "records.hex")
if not os.path.exists(path):
    sys.exit(f"{path} not found -- run `xsim tbsim -runall` in this directory first")

raw = np.array([int(l, 16) for l in open(path) if l.strip()], dtype='<u8')
ts, energy, direction = unpack(raw)

errors = 0
print(f"{len(raw)} records")
print(f"{'#':>3} {'timestamp':>12} {'dir':>4} {'energy':>7}   raw")
for i in range(len(raw)):
    print(f"{i:>3} {int(ts[i]):>12} {int(direction[i]):>4} "
          f"{int(energy[i]):>7}   {int(raw[i]):016x}")

if len(raw) != len(EXPECTED):
    print(f"FAIL  expected {len(EXPECTED)} records, got {len(raw)}")
    errors += 1
else:
    for i, (e_exp, d_exp) in enumerate(EXPECTED):
        if e_exp is not None and int(energy[i]) != e_exp:
            print(f"FAIL  record {i}: energy {int(energy[i])} != {e_exp}")
            errors += 1
        if d_exp is not None and int(direction[i]) != d_exp:
            print(f"FAIL  record {i}: direction {int(direction[i])} != {d_exp}")
            errors += 1

# Timestamps must be strictly increasing and must not have leaked into the
# other fields (a 46-bit counter never reaches the dir/energy bits here).
if len(raw) > 1 and not np.all(np.diff(ts.astype(np.int64)) > 0):
    print("FAIL  timestamps are not strictly increasing")
    errors += 1

print(f"=== {errors} error(s) ===")
print("RTL AND HOST LAYOUTS AGREE" if errors == 0 else "LAYOUT MISMATCH")
sys.exit(1 if errors else 0)
