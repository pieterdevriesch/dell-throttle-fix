# DellThrottleFix

DellThrottleFix is a small Linux workaround for Dell OptiPlex systems that become locked at approximately **800 MHz** when the connected power adapter cannot be correctly identified.

Some Dell systems restrict CPU performance when the adapter identification signal is missing, even when the connected power supply is capable of providing sufficient power.

## Warning

> **Only use DellThrottleFix with a power adapter that is actually capable of powering the system at full load.**

Dell's adapter identification mechanism allows the system to determine the available power capacity. DellThrottleFix bypasses the resulting CPU restriction.

Using an undersized or unsuitable adapter may cause instability, unexpected shutdowns, adapter overheating, or other power-related problems.

The system this utility was developed for uses a **90 W Dell adapter**, but the identification signal is lost when using a barrel-jack converter.

## Tested hardware

Developed and tested on:

- Dell OptiPlex 5070 Micro
- Intel Core i5-9500T
- Linux / Proxmox VE
- Dell 90 W power adapter connected through a barrel-jack converter

Other Intel-based Dell systems exhibiting the same behaviour may also work, but have not been tested.

## Requirements

- Linux
- Intel CPU with HWP support, with HWP enabled (`IA32_PM_ENABLE` bit 0)
- Root access
- `msr-tools` (installed automatically with `apt-get` by `--run-once` and `--install` if missing)
- Secure Boot disabled
- Linux kernel lockdown disabled

DellThrottleFix will refuse to apply or install the workaround if Secure Boot or kernel lockdown prevents MSR writes, if the CPU is not an Intel CPU, or if HWP is not enabled.

## Installation

Download `dell-throttle-fix` and make it executable:

```bash
chmod +x dell-throttle-fix
```

Running it without arguments displays the built-in help:

```bash
./dell-throttle-fix
```

## Check compatibility

Run a compatibility check:

```bash
./dell-throttle-fix --check
```

This checks:

- Secure Boot
- Kernel lockdown
- Intel CPU and HWP support, and whether HWP is enabled
- MSR access
- Current performance restrictions
- Current CPU frequency limits
- Values DellThrottleFix would apply, and how many CPUs would need changes

No MSRs, services, files, or packages are changed. The only side effect is that the `msr` kernel module is loaded if it is not loaded yet; this does not persist across reboots.

## Temporary test

Apply the workaround for the current boot only:

```bash
./dell-throttle-fix --run-once
```

DellThrottleFix displays the relevant MSR values and CPU frequencies before and after applying the workaround, and reports the result per CPU.

If any CPU fails validation (for example because HWP is not enabled), nothing is written. Every write is read back and verified.

No systemd service is installed.

A reboot normally restores the firmware defaults.

## Permanent installation

```bash
./dell-throttle-fix --install
```

This will:

1. Install `msr-tools` if necessary.
2. Install a copy of the script as the worker (the service runs it with the internal `--apply` option):

   ```text
   /usr/local/sbin/dell-throttle-fix-worker
   ```

3. Create and enable:

   ```text
   /etc/systemd/system/dell-throttle-fix.service
   ```

4. Apply the workaround immediately.
5. Automatically apply it after future boots **and after resuming from suspend or hibernate**, because the values can be reset by the firmware or by the `intel_pstate` driver.

The service is a `oneshot` unit without `RemainAfterExit`, so it becomes inactive after each run. This is normal and allows it to run again after every resume.

If you installed an older version, run `--install` again to update the worker and the service unit.

## Status

```bash
./dell-throttle-fix --status
```

This displays:

- Secure Boot and kernel lockdown state
- Installation/service state, including the result of the last service run (the service is normally "inactive" because it exits after each run)
- Relevant MSR values, including a per-CPU summary
- Intel HWP limits
- Current CPU frequencies
- Current CPUFreq limits

## Uninstall

```bash
./dell-throttle-fix --uninstall
```

The systemd service and worker are removed.

Reboot afterwards to restore the firmware-programmed MSR values.

## How it works

DellThrottleFix dynamically reads the capabilities of each logical CPU rather than relying on CPU-specific hard-coded HWP values.

First, every CPU is read and validated (HWP enabled, sane `Highest_Performance`). Nothing is written unless all CPUs pass. Then, for each CPU it:

- Reads `IA32_MISC_ENABLE`.
- Clears only bit 38 (Turbo Mode Disable).
- Reads `IA32_HWP_CAPABILITIES`.
- Obtains the CPU's advertised `Highest_Performance` value.
- Updates only `Maximum_Performance` in `IA32_HWP_REQUEST`. The value is only ever raised, never lowered.
- Preserves the remaining MSR fields.
- Reads each written value back to verify it.
- Leaves BD PROCHOT untouched (see below).

CPUs that are offline have no MSR device and are skipped; the script reports how many.

This allows normal Intel hardware-controlled frequency scaling to operate again instead of leaving the CPU capped at approximately 800 MHz.

## Why BD PROCHOT is not touched

BD PROCHOT (Bi-Directional Processor Hot) is a separate throttling mechanism, controlled by bit 0 of `MSR_POWER_CTL` (`0x1FC`). It lets other components, such as the embedded controller or the power delivery circuitry, force the CPU to throttle.

DellThrottleFix deliberately does not modify it:

- **It did not help on the system this was developed for.** Disabling BD PROCHOT did not change the 800 MHz limit on the Dell OptiPlex 5070 Micro. The restriction on that system is applied through `IA32_MISC_ENABLE` and the HWP maximum, which is what this tool changes.
- **Other tools already cover it.** Several existing scripts and methods clear BD PROCHOT. If your throttling is caused by it, use one of those. DellThrottleFix is intended for systems where that approach does not work.
- **It is a protective signal.** BD PROCHOT can also be asserted for genuine thermal or power reasons. Leaving it alone keeps that hardware protection working, which matters because this workaround already bypasses the adapter-based limit.

If your system is still stuck at a low frequency after running `--check` and `--run-once`, BD PROCHOT may be the cause on your hardware, and a BD PROCHOT-specific tool is the right next step.

## Example

Before:

```text
CPU max MHz: 800.0000
CPU min MHz: 800.0000
```

After applying DellThrottleFix on the tested i5-9500T system:

```text
cpu MHz : 3680.488
cpu MHz : 3467.928
cpu MHz : 3100.605
cpu MHz : 3142.495
cpu MHz : 3560.497
cpu MHz : 3148.800
```

CPU frequencies will naturally vary depending on workload, temperature, power management, and turbo behaviour.

## Limitations

- The workaround is applied at boot and after resume. Other software that rewrites `IA32_HWP_REQUEST` at runtime (for example `intel_pstate` when the governor or `scaling_max_freq` changes, `thermald`, or `power-profiles-daemon`) can undo it. If the limit returns, run `--run-once` again or restart the service with `systemctl start dell-throttle-fix.service`.
- Offline CPUs are skipped.

## Disclaimer

DellThrottleFix modifies Intel model-specific registers to override a firmware-imposed CPU performance restriction.

**Use at your own risk. Verify that the connected power supply provides the correct voltage and sufficient current/power for the system before using this workaround.**
