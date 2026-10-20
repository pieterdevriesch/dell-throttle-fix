#!/usr/bin/env bash
set -euo pipefail

PROGRAM_NAME="DellThrottleFix"
SCRIPT_NAME=$(basename "$0")
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")

WORKER="/usr/local/sbin/dell-throttle-fix-worker"
SERVICE="/etc/systemd/system/dell-throttle-fix.service"
SERVICE_NAME="dell-throttle-fix.service"

show_help() {
    cat <<EOF
$PROGRAM_NAME

Adaptive Linux workaround for Dell OptiPlex systems that remain limited
to approximately 800 MHz when the power adapter cannot be identified.

Usage:
  $SCRIPT_NAME --help
  $SCRIPT_NAME --check
  $SCRIPT_NAME --status
  $SCRIPT_NAME --run-once
  $SCRIPT_NAME --install
  $SCRIPT_NAME --uninstall
  $SCRIPT_NAME --apply        (internal, used by the systemd service)

Options:
  --help, -h
      Show this help. Running without arguments also shows this help.

  --check
      Perform a read-only compatibility check.

      This checks:
        - Secure Boot state
        - Linux kernel lockdown state
        - msr-tools availability
        - Intel MSR access
        - HWP support and whether HWP is enabled
        - Current and proposed MSR values
        - Current CPU frequency limits

      The only system change is loading the msr kernel module if it is
      not loaded yet (not persistent across reboots). No packages, files,
      services or MSRs are changed.

  --status
      Show:
        - Secure Boot and kernel lockdown state
        - Installation and service state
        - Current and proposed MSR values
        - Current CPU frequencies
        - Current CPUFreq limits

  --run-once
      Apply the workaround immediately without installing a service.

      The command displays the relevant MSR values and CPU frequencies
      before and after applying the workaround.

      The changes normally last until the next reboot.

  --install
      Install msr-tools if necessary, install a copy of this script as the
      worker, install and enable the systemd service, and apply the
      workaround immediately.

      The service runs at boot and again after resume from suspend or
      hibernate, because the values can be reset by the firmware or by
      the intel_pstate driver.

  --uninstall
      Disable and remove the systemd service and worker script.

      Reboot afterwards to restore the firmware-programmed MSR defaults.

  --apply
      Internal. Applies the workaround without any extra output or
      installation. Used by the systemd service.

How it works:
  - Clears bit 38 of IA32_MISC_ENABLE while preserving all other bits.
  - Reads IA32_HWP_CAPABILITIES from each CPU.
  - Extracts the advertised Highest_Performance value.
  - Replaces only the Maximum_Performance field in IA32_HWP_REQUEST.
  - Leaves BD PROCHOT untouched (use other tools for that).
  - Calculates the required values separately for each logical CPU.
  - Validates all CPUs before writing anything, and verifies each write
    by reading the value back.
  - Requires HWP to be enabled (IA32_PM_ENABLE bit 0).
  - CPUs that are offline have no MSR device and are skipped.

Safety:
  --install and --run-once abort when Secure Boot or Linux kernel
  lockdown is active because kernel lockdown blocks raw MSR writes.

  This workaround removes Dell's CPU restriction for an unidentified
  power adapter. Only use it when the connected adapter is electrically
  suitable for the system.
EOF
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: This operation must be run as root." >&2
        exit 1
    fi
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Prints the MSR value as a decimal number.
read_msr() {
    local out

    out=$(rdmsr -p "$1" "$2" 2>/dev/null) || return 1
    [ -n "$out" ] || return 1

    echo $((16#$out))
}

list_cpus() {
    local path

    for path in /dev/cpu/[0-9]*; do
        [ -e "$path/msr" ] || continue
        echo "${path#/dev/cpu/}"
    done | sort -n
}

# Writes a value only when the masked bits differ, then reads it back
# and verifies that the masked bits have the requested value.
write_msr_verified() {
    local cpu=$1
    local reg=$2
    local value=$3
    local mask=$4
    local current
    local readback

    current=$(read_msr "$cpu" "$reg") || return 1

    if (((current & mask) == (value & mask))); then
        return 0
    fi

    wrmsr -p "$cpu" "$reg" "$(printf '0x%x' "$value")" 2>/dev/null ||
        return 1

    readback=$(read_msr "$cpu" "$reg") || return 1

    (((readback & mask) == (value & mask)))
}

get_secure_boot_state() {
    if command -v mokutil >/dev/null 2>&1; then
        local output
        output=$(mokutil --sb-state 2>/dev/null || true)

        if grep -qi "SecureBoot enabled" <<< "$output"; then
            echo "enabled"
            return
        fi

        if grep -qi "SecureBoot disabled" <<< "$output"; then
            echo "disabled"
            return
        fi
    fi

    local secure_boot_var
    secure_boot_var=$(
        find /sys/firmware/efi/efivars \
            -maxdepth 1 \
            -name 'SecureBoot-*' \
            -print \
            -quit 2>/dev/null || true
    )

    if [ -n "$secure_boot_var" ] && [ -r "$secure_boot_var" ]; then
        local value
        value=$(
            od -An -t u1 -j 4 -N 1 "$secure_boot_var" 2>/dev/null |
                tr -d '[:space:]'
        )

        case "$value" in
            1)
                echo "enabled"
                return
                ;;
            0)
                echo "disabled"
                return
                ;;
        esac
    fi

    if [ ! -d /sys/firmware/efi ]; then
        echo "not-uefi"
    else
        echo "unknown"
    fi
}

get_lockdown_state() {
    if [ ! -r /sys/kernel/security/lockdown ]; then
        echo "unavailable"
        return
    fi

    local value
    value=$(cat /sys/kernel/security/lockdown)

    if grep -q '\[none\]' <<< "$value"; then
        echo "none"
    elif grep -q '\[integrity\]' <<< "$value"; then
        echo "integrity"
    elif grep -q '\[confidentiality\]' <<< "$value"; then
        echo "confidentiality"
    else
        echo "$value"
    fi
}

security_check() {
    local secure_boot
    local lockdown

    secure_boot=$(get_secure_boot_state)
    lockdown=$(get_lockdown_state)

    printf '%-22s %s\n' "Secure Boot:" "$secure_boot"
    printf '%-22s %s\n' "Kernel lockdown:" "$lockdown"

    if [ "$secure_boot" = "enabled" ]; then
        cat >&2 <<EOF

ERROR: Secure Boot is enabled.

$PROGRAM_NAME requires writing Intel CPU model-specific registers.
Secure Boot normally activates Linux kernel lockdown, which blocks
these writes.

Disable Secure Boot in the Dell UEFI/BIOS, boot Linux again, and run:

  $SCRIPT_NAME --check
EOF
        return 1
    fi

    case "$lockdown" in
        integrity|confidentiality)
            cat >&2 <<EOF

ERROR: Linux kernel lockdown is active in '$lockdown' mode.

Kernel lockdown blocks the raw MSR writes required by this workaround.

Disable Secure Boot or otherwise disable kernel lockdown, reboot, and run:

  $SCRIPT_NAME --check
EOF
            return 1
            ;;
    esac

    if [ "$secure_boot" = "unknown" ]; then
        echo
        echo "WARNING: Secure Boot state could not be determined."
        echo "Kernel lockdown is not currently reported as active."
    fi

    return 0
}

ensure_msr_tools() {
    if command -v rdmsr >/dev/null 2>&1 &&
       command -v wrmsr >/dev/null 2>&1; then
        return
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "ERROR: msr-tools is missing and apt-get is unavailable." >&2
        echo "Install msr-tools manually, then run this command again." >&2
        exit 1
    fi

    echo "Installing msr-tools..."
    apt-get update
    apt-get install -y msr-tools

    if ! command -v rdmsr >/dev/null 2>&1 ||
       ! command -v wrmsr >/dev/null 2>&1; then
        die "msr-tools was installed but rdmsr/wrmsr are still not available."
    fi
}

load_msr_module() {
    if ! modprobe msr; then
        echo "ERROR: Unable to load the Linux msr module." >&2
        exit 1
    fi

    if [ ! -e /dev/cpu/0/msr ]; then
        echo "ERROR: /dev/cpu/0/msr was not created." >&2
        exit 1
    fi
}

check_msr_access() {
    if ! command -v rdmsr >/dev/null 2>&1; then
        printf '%-22s %s\n' "MSR tools:" "not installed"
        return 1
    fi

    if ! modprobe msr 2>/dev/null; then
        printf '%-22s %s\n' "MSR module:" "unavailable"
        return 1
    fi

    if [ ! -e /dev/cpu/0/msr ]; then
        printf '%-22s %s\n' "MSR device:" "unavailable"
        return 1
    fi

    if ! rdmsr -p 0 0x1a0 >/dev/null 2>&1; then
        printf '%-22s %s\n' \
            "MSR access:" \
            "unable to read IA32_MISC_ENABLE"
        return 1
    fi

    if ! rdmsr -p 0 0x771 >/dev/null 2>&1; then
        printf '%-22s %s\n' \
            "HWP support:" \
            "unable to read IA32_HWP_CAPABILITIES"
        return 1
    fi

    if ! rdmsr -p 0 0x774 >/dev/null 2>&1; then
        printf '%-22s %s\n' \
            "HWP support:" \
            "unable to read IA32_HWP_REQUEST"
        return 1
    fi

    if ! grep -qw hwp /proc/cpuinfo; then
        printf '%-22s %s\n' "HWP support:" "not reported by the CPU"
        return 1
    fi

    local pm_enable
    pm_enable=$(read_msr 0 0x770) || pm_enable=0

    if ! ((pm_enable & 1)); then
        printf '%-22s %s\n' "HWP enabled:" "no (IA32_PM_ENABLE bit 0 clear)"
        return 1
    fi

    printf '%-22s %s\n' "HWP enabled:" "yes"
    printf '%-22s %s\n' "MSR access:" "available"
    return 0
}

show_cpu_identity() {
    local vendor
    local model

    vendor=$(awk -F ': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)
    model=$(awk -F ': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)

    printf '%-22s %s\n' "CPU vendor:" "${vendor:-unknown}"
    printf '%-22s %s\n' "CPU model:" "${model:-unknown}"

    if [ "${vendor:-unknown}" != "GenuineIntel" ]; then
        echo
        echo "WARNING: This utility is intended for Intel processors."
        return 1
    fi

    return 0
}

show_calculated_values() {
    local misc
    local hwp_cap
    local hwp_req

    local new_misc
    local hwp_max
    local current_hwp_max
    local new_hwp

    local cpu
    local total=0
    local pending=0
    local c_misc
    local c_cap
    local c_req

    misc=$(read_msr 0 0x1a0) || { echo "ERROR: cannot read IA32_MISC_ENABLE." >&2; return 1; }
    hwp_cap=$(read_msr 0 0x771) || { echo "ERROR: cannot read IA32_HWP_CAPABILITIES." >&2; return 1; }
    hwp_req=$(read_msr 0 0x774) || { echo "ERROR: cannot read IA32_HWP_REQUEST." >&2; return 1; }

    new_misc=$((misc & ~(1 << 38)))
    hwp_max=$((hwp_cap & 0xff))
    current_hwp_max=$(((hwp_req >> 8) & 0xff))
    new_hwp=$hwp_req

    if ((current_hwp_max < hwp_max)); then
        new_hwp=$(((hwp_req & ~(0xff << 8)) | (hwp_max << 8)))
    fi

    echo
    echo "MSR analysis (CPU 0):"
    printf '%-31s 0x%x\n' "IA32_MISC_ENABLE:" "$misc"
    printf '%-31s 0x%x\n' "Proposed IA32_MISC_ENABLE:" "$new_misc"
    printf '%-31s 0x%x\n' "IA32_HWP_CAPABILITIES:" "$hwp_cap"
    printf '%-31s 0x%x\n' "Advertised HWP maximum:" "$hwp_max"
    printf '%-31s 0x%x\n' "Current HWP maximum:" "$current_hwp_max"
    printf '%-31s 0x%x\n' "IA32_HWP_REQUEST:" "$hwp_req"
    printf '%-31s 0x%x\n' "Proposed HWP request:" "$new_hwp"

    echo

    if ((misc & (1 << 38))); then
        printf '%-31s %s\n' \
            "Turbo disable bit (38):" \
            "set (turbo disabled)"
    else
        printf '%-31s %s\n' \
            "Turbo disable bit (38):" \
            "clear"
    fi

    if ((current_hwp_max >= hwp_max)); then
        printf '%-31s %s\n' \
            "HWP maximum request:" \
            "already unrestricted"
    else
        printf '%-31s %s\n' \
            "HWP maximum request:" \
            "currently restricted"
    fi

    for cpu in $(list_cpus); do
        total=$((total + 1))

        c_misc=$(read_msr "$cpu" 0x1a0) || continue
        c_cap=$(read_msr "$cpu" 0x771) || continue
        c_req=$(read_msr "$cpu" 0x774) || continue

        if ((c_misc & (1 << 38))) ||
           ((((c_req >> 8) & 0xff) < (c_cap & 0xff))); then
            pending=$((pending + 1))
        fi
    done

    printf '%-31s %s of %s\n' "CPUs needing changes:" "$pending" "$total"
}

show_all_msr_values() {
    echo
    echo "Per-CPU MSR values:"

    echo
    echo "IA32_MISC_ENABLE:"
    rdmsr -a 0x1a0 || true

    echo
    echo "IA32_HWP_CAPABILITIES:"
    rdmsr -a 0x771 || true

    echo
    echo "IA32_HWP_REQUEST:"
    rdmsr -a 0x774 || true
}

show_frequencies() {
    echo
    echo "Current CPU frequencies:"

    if grep -q '^cpu MHz' /proc/cpuinfo; then
        grep '^cpu MHz' /proc/cpuinfo
    else
        echo "Frequency information unavailable."
    fi

    echo
    echo "CPUFreq limits:"

    if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
        grep . \
            /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver \
            /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor \
            /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq \
            /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq \
            /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq \
            /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq \
            /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference \
            2>/dev/null || true
    else
        echo "CPUFreq interface unavailable."
    fi
}

apply_workaround() {
    local -a cpus=()
    local -a plan_cpu=()
    local -a plan_misc=()
    local -a plan_hwp=()

    local cpu
    local i
    local pm_enable
    local misc
    local cap
    local req
    local hwp_max
    local cur_max
    local min_perf
    local new_misc
    local new_hwp
    local total
    local failed=0

    mapfile -t cpus < <(list_cpus)

    if [ "${#cpus[@]}" -eq 0 ]; then
        echo "ERROR: No /dev/cpu/N/msr devices found." >&2
        return 1
    fi

    # Phase 1: read and validate every CPU before changing anything.
    for cpu in "${cpus[@]}"; do
        pm_enable=$(read_msr "$cpu" 0x770) || pm_enable=0

        if ! ((pm_enable & 1)); then
            echo "ERROR: HWP is not enabled on CPU $cpu." >&2
            return 1
        fi

        misc=$(read_msr "$cpu" 0x1a0) || {
            echo "ERROR: Cannot read IA32_MISC_ENABLE on CPU $cpu." >&2
            return 1
        }
        cap=$(read_msr "$cpu" 0x771) || {
            echo "ERROR: Cannot read IA32_HWP_CAPABILITIES on CPU $cpu." >&2
            return 1
        }
        req=$(read_msr "$cpu" 0x774) || {
            echo "ERROR: Cannot read IA32_HWP_REQUEST on CPU $cpu." >&2
            return 1
        }

        # IA32_HWP_CAPABILITIES bits 7:0 contain Highest_Performance.
        hwp_max=$((cap & 0xff))

        # IA32_HWP_REQUEST bits 15:8 are Maximum_Performance,
        # bits 7:0 are Minimum_Performance.
        cur_max=$(((req >> 8) & 0xff))
        min_perf=$((req & 0xff))

        if [ "$hwp_max" -eq 0 ] || [ "$hwp_max" -lt "$min_perf" ]; then
            printf 'ERROR: CPU %s advertises an invalid Highest_Performance (0x%x, minimum request 0x%x).\n' \
                "$cpu" "$hwp_max" "$min_perf" >&2
            return 1
        fi

        # Clear only IA32_MISC_ENABLE bit 38.
        new_misc=$((misc & ~(1 << 38)))

        # Only ever raise Maximum_Performance, never lower it.
        new_hwp=$req
        if [ "$cur_max" -lt "$hwp_max" ]; then
            new_hwp=$(((req & ~(0xff << 8)) | (hwp_max << 8)))
        fi

        plan_cpu+=("$cpu")
        plan_misc+=("$new_misc")
        plan_hwp+=("$new_hwp")
    done

    # Phase 2: apply and verify.
    for i in "${!plan_cpu[@]}"; do
        cpu=${plan_cpu[$i]}

        if ! write_msr_verified "$cpu" 0x1a0 "${plan_misc[$i]}" $((1 << 38)); then
            echo "ERROR: Failed to update IA32_MISC_ENABLE on CPU $cpu." >&2
            failed=1
            continue
        fi

        if ! write_msr_verified "$cpu" 0x774 "${plan_hwp[$i]}" $((0xff << 8)); then
            echo "ERROR: Failed to update IA32_HWP_REQUEST on CPU $cpu." >&2
            failed=1
            continue
        fi

        echo "CPU $cpu: OK"
    done

    total=$(nproc --all 2>/dev/null || echo "${#cpus[@]}")
    if [ "$total" -gt "${#cpus[@]}" ]; then
        echo "NOTE: $((total - ${#cpus[@]})) offline CPU(s) were skipped."
    fi

    return "$failed"
}

install_worker() {
    if [ ! -f "$SELF" ]; then
        die "Cannot locate this script on disk (\$0=$0); run it from a file."
    fi

    if [ "$SELF" != "$WORKER" ]; then
        install -m 755 "$SELF" "$WORKER"
    fi
}

# No RemainAfterExit: the unit must become inactive after each run so
# that the sleep targets can start it again after resume.
write_service() {
    cat > "$SERVICE" <<EOF
[Unit]
Description=DellThrottleFix adaptive CPU unthrottle workaround
After=systemd-modules-load.service suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
ConditionPathExists=$WORKER

[Service]
Type=oneshot
ExecStart=$WORKER --apply

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
EOF
}

do_check() {
    require_root

    echo "$PROGRAM_NAME compatibility check"
    echo

    local failed=0

    show_cpu_identity || failed=1

    echo

    security_check || failed=1

    echo

    if ! check_msr_access; then
        failed=1
    else
        show_calculated_values || failed=1
        show_frequencies
    fi

    echo

    if [ "$failed" -ne 0 ]; then
        echo "CHECK RESULT: Not ready."
        exit 1
    fi

    echo "CHECK RESULT: Ready."
    echo "No packages, files, services or MSRs were changed."
    echo "(The msr kernel module may have been loaded; this does not persist across reboots.)"
}

do_status() {
    require_root

    echo "$PROGRAM_NAME status"
    echo

    show_cpu_identity || true

    echo

    security_check || true

    echo

    if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
        printf '%-22s %s\n' "Service enabled:" "yes"
    else
        printf '%-22s %s\n' "Service enabled:" "no"
    fi

    if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
        printf '%-22s %s\n' "Service active:" "yes"
    else
        printf '%-22s %s\n' "Service active:" "no (normal: it exits after each run)"
    fi

    printf '%-22s %s\n' \
        "Last run result:" \
        "$(systemctl show -p Result --value "$SERVICE_NAME" 2>/dev/null || echo unknown)"

    if [ -f "$WORKER" ]; then
        printf '%-22s %s\n' "Worker installed:" "yes"
    else
        printf '%-22s %s\n' "Worker installed:" "no"
    fi

    if [ -f "$SERVICE" ]; then
        printf '%-22s %s\n' "Service installed:" "yes"
    else
        printf '%-22s %s\n' "Service installed:" "no"
    fi

    echo

    if check_msr_access; then
        show_calculated_values || true
        show_all_msr_values
        show_frequencies
    fi
}

require_intel_and_unlocked() {
    show_cpu_identity || die "An Intel processor is required."
    security_check || exit 1
}

do_apply() {
    require_root

    security_check || exit 1

    if ! command -v rdmsr >/dev/null 2>&1 ||
       ! command -v wrmsr >/dev/null 2>&1; then
        die "rdmsr/wrmsr are not installed (msr-tools)."
    fi

    load_msr_module
    apply_workaround
}

do_run_once() {
    require_root

    require_intel_and_unlocked
    ensure_msr_tools
    load_msr_module

    echo
    echo "Before:"
    show_calculated_values
    show_frequencies

    echo
    echo "Applying temporary workaround..."
    apply_workaround || die "The workaround could not be fully applied."

    sleep 1

    echo
    echo "After:"
    show_calculated_values
    show_all_msr_values
    show_frequencies

    echo
    echo "Temporary workaround applied."
    echo "No systemd service was installed."
    echo "A reboot normally restores the firmware defaults."
}

do_install() {
    require_root

    require_intel_and_unlocked
    ensure_msr_tools
    load_msr_module

    echo
    echo "Detected configuration:"
    show_calculated_values

    echo
    echo "Installing worker and systemd service..."
    install_worker
    write_service

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"

    sleep 1

    echo
    echo "Installation state:"
    systemctl status "$SERVICE_NAME" --no-pager || true

    show_calculated_values
    show_all_msr_values
    show_frequencies

    echo
    echo "Installation completed successfully."
    echo "$PROGRAM_NAME will now run automatically during boot and after resume."
}

do_uninstall() {
    require_root

    echo "Removing $PROGRAM_NAME..."

    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true

    rm -f "$SERVICE"
    rm -f "$WORKER"

    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

    echo
    echo "Uninstallation completed."
    echo
    echo "The currently active MSR values were not modified."
    echo "Reboot the system to restore the firmware-programmed defaults."
}

if [ "$#" -eq 0 ]; then
    show_help
    exit 0
fi

if [ "$#" -ne 1 ]; then
    echo "ERROR: Specify exactly one option." >&2
    echo >&2
    show_help >&2
    exit 2
fi

case "$1" in
    --help|-h)
        show_help
        ;;
    --check)
        do_check
        ;;
    --status)
        do_status
        ;;
    --run-once)
        do_run_once
        ;;
    --install)
        do_install
        ;;
    --uninstall)
        do_uninstall
        ;;
    --apply)
        do_apply
        ;;
    *)
        echo "ERROR: Unknown option: $1" >&2
        echo >&2
        show_help >&2
        exit 2
        ;;
esac
