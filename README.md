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
- Intel CPU with HWP support
- Root access
- `msr-tools`
- Secure Boot disabled
- Linux kernel lockdown disabled

DellThrottleFix will refuse to apply or install the workaround if Secure Boot or kernel lockdown prevents MSR writes.

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

Run a read-only compatibility check:

```bash
./dell-throttle-fix --check
```

This checks:

- Secure Boot
- Kernel lockdown
- Intel CPU and HWP support
- MSR access
- Current performance restrictions
- Current CPU frequency limits
- Values DellThrottleFix would apply

No MSRs, services, files, or packages are changed.

## Temporary test

Apply the workaround for the current boot only:

```bash
./dell-throttle-fix --run-once
```

DellThrottleFix displays the relevant MSR values and CPU frequencies before and after applying the workaround.

No systemd service is installed.

A reboot normally restores the firmware defaults.

## Permanent installation

```bash
./dell-throttle-fix --install
```

This will:

1. Install `msr-tools` if necessary.
2. Create the adaptive worker:

   ```text
   /usr/local/sbin/dell-throttle-fix-worker
   ```

3. Create and enable:

   ```text
   /etc/systemd/system/dell-throttle-fix.service
   ```

4. Apply the workaround immediately.
5. Automatically apply it after future boots.

## Status

```bash
./dell-throttle-fix --status
```

This displays:

- Secure Boot and kernel lockdown state
- Installation/service state
- Relevant MSR values
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

For each CPU it:

- Reads `IA32_MISC_ENABLE`.
- Clears only the relevant Dell/BIOS performance restriction bit.
- Reads `IA32_HWP_CAPABILITIES`.
- Obtains the CPU's advertised `Highest_Performance` value.
- Updates only `Maximum_Performance` in `IA32_HWP_REQUEST`.
- Preserves the remaining MSR fields.
- Leaves BD PROCHOT enabled.

This allows normal Intel hardware-controlled frequency scaling to operate again instead of leaving the CPU capped at approximately 800 MHz.

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

## Disclaimer

DellThrottleFix modifies Intel model-specific registers to override a firmware-imposed CPU performance restriction.

**Use at your own risk. Verify that the connected power supply provides the correct voltage and sufficient current/power for the system before using this workaround.**
