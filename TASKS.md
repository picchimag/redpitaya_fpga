

## Live streaming

### Verilog module

- [ ] Optimize BRAM access timing
- [ ] use dma for faster stream

### Python Interface To-Do List

- [ ] Script to read timetraces when works in hardware
- [x] CDMA-based fast acquisition working (8-9 Hz with live plot, 21 Hz raw)
- [ ] Create optimized redpitaya_base functions:
  - [ ] `read_cdma_frame`: Arm capture, smart wait (only if acquisition_time > 1ms), CDMA transfer via base64/SSH, return data
  - [ ] `setup_cdma(sampling_frequency, frame_len, n_of_frames)`: Configure CDMA once, calculate/return actual sampling freq & frame time based on log_div quantization
- [ ] make little app that plots live timetrace and spectrum, allows setting of scale, sampling rate, averaging...
  - [ ] Enhanced live plot with PSD:
    - Top: 4-channel time-domain (with matplotlib blitting for speed)
    - Bottom: Power Spectral Density with averaging over N frames
    - Controls: averaging window, frequency zoom, save data/screenshots
  - [ ] Simple GUI app:
    - Start/Stop acquisition, sampling frequency selector, frame length selector
    - Live plot display (time + PSD), frame rate indicator
    - Save configuration/data options
    - Consider tkinter (simple) or PyQt (more features)



## Noise performance improvement

### Verilog Module
 - [ ] make CIC decimator (3rd order, LOG_DIV)
 - [ ] make CIC interpolator


  
PS C:\Users\magrini\Documents\programming\redpitaya> git commit -m "Added mca, works; Added sreaming functionality through dma on feedbacks, works; fixe saturation of filers and pid outputs, now works (as long as the internal state does not saturate!); restructured the python module, now its installable, "

## Trigger logger (`trig_logger`)

Digitally triggered 3-input logger: IN1 boxcar energy, IN2 piezo direction,
DIO pulse trigger. Record = 46-bit cycle timestamp + 2-bit direction + signed
int16 energy. Design notes in `docs/trig_logger.md`.

- [x] `rtl/trig_logger.v` + `rtl/trig_logger_axi_wrap.v`
- [x] Simulated: 43 module checks + 25 AXI checks, plus an RTL-vs-host record
      layout cross-check (`sim/`)
- [x] `redpitaya_control`: `config/trig_logger.json`, `trig_logger.py`,
      `examples/trig_logger_example.py`
- [x] **Block design wired** -- `exp_p_tri_io[7:0]` and `exp_n_tri_io[7:0]` as
      input ports -> `xlconcat_0` (In0 = exp_p, In1 = exp_n) -> `trig_bus`,
      `chb_raw` -> `dir_in`, MCA removed, `trig_logger_axi_wrap_0` at
      `0x40000000` and the record BRAM at `0x41000000` (64K in both the PS and
      the CDMA space). Recipe re-exported to `projects/trig_logger/bd.tcl`.
- [x] Bitstream built and staged to `projects/trig_logger/trig_logger.bit` and
      `redpitaya_control/bitfiles/trig_logger.bit`. Timing met (WNS +0.691 ns,
      WHS +0.022 ns), 0 routing errors, 47% LUT / 32% FF / 30% BRAM. The only
      critical warnings are the shared `constr/ports.xdc` XADC pin constraints
      and the IIR/PID multicycle paths, neither of which this design contains.
- [ ] **Deploy to the board** -- not yet loaded on real hardware.
- [ ] Hardware bring-up: confirm the DIO pin numbering (`trig_sel` 0-15 over
      `exp_p[0..7]` then `exp_n[0..7]`) -- no project in this repo has ever
      used the expansion pins, so the mapping is untested. `status.trig_level`
      reads the live pin.
- [ ] Set `dir_thr_pos`/`dir_thr_neg` against the real piezo signal; they reset
      to 0, which is a hard sign test with no dead zone.
