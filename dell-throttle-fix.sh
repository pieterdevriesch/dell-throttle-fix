#!/usr/bin/env bash
set -euo pipefail

PROGRAM_NAME="DellThrottleFix"
SCRIPT_NAME=$(basename "$0")

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

Options:
  --help
      Show this help. Running without arguments also shows this help.

  --check
      Perform a read-only compatibility check.

      This checks:
        - Secure Boot state
        - Linux kernel lockdown state
        - msr-tools availability
        - Intel MSR access
        - HWP support
        - Current and proposed MSR values
        - Current CPU frequency limits

      No packages, files, services or MSRs are changed.

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
      Install msr-tools if necessary, create the adaptive worker script,
      install and enable the systemd service, and apply the workaround
      immediately.

  --uninstall
      Disable and remove the systemd service and worker script.

      Reboot afterwards to restore the firmware-programmed MSR defaults.

How it works:
  - Clears bit 38 of IA32_MISC_ENABLE while preserving all other bits.
  - Reads IA32_HWP_CAPABILITIES from each CPU.
  - Extracts the advertised Highest_Performance value.
  - Replaces only the Maximum_Performance field in IA32_HWP_REQUEST.
  - Leaves BD PROCHOT enabled.
  - Calculates the required values separately for each logical CPU.

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
    local misc_hex
    local hwp_cap_hex
    local hwp_req_hex

    local misc
    local hwp_cap
    local hwp_req

    local new_misc
    local hwp_max
    local current_hwp_max
    local new_hwp

    misc_hex=$(rdmsr -p 0 0x1a0)
    hwp_cap_hex=$(rdmsr -p 0 0x771)
    hwp_req_hex=$(rdmsr -p 0 0x774)

    misc=$((16#$misc_hex))
    hwp_cap=$((16#$hwp_cap_hex))
    hwp_req=$((16#$hwp_req_hex))

    new_misc=$((misc & ~(1 << 38)))
    hwp_max=$((hwp_cap & 0xff))
    current_hwp_max=$(((hwp_req >> 8) & 0xff))
    new_hwp=$(((hwp_req & ~(0xff << 8)) | (hwp_max << 8)))

    echo
    echo "MSR analysis:"
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
            "Dell/BIOS restriction bit:" \
            "set"
    else
        printf '%-31s %s\n' \
            "Dell/BIOS restriction bit:" \
            "clear"
    fi

    if ((current_hwp_max == hwp_max)); then
        printf '%-31s %s\n' \
            "HWP maximum request:" \
            "already unrestricted"
    else
        printf '%-31s %s\n' \
            "HWP maximum request:" \
            "currently restricted"
    fi
}

show_all_msr_values() {
    echo
    echo "Per-CPU MSR values:"

    echo
    echo "IA32_MISC_ENABLE:"
    rdmsr -a 0x1a0

    echo
    echo "IA32_HWP_CAPABILITIES:"
    rdmsr -a 0x771

    echo
    echo "IA32_HWP_REQUEST:"
    rdmsr -a 0x774
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
    local path
    local cpu

    local current
    local cap
    local request

    local current_value
    local cap_value
    local request_value

    local new_misc
    local hwp_max
    local new_hwp

    modprobe msr

    for path in /dev/cpu/[0-9]*; do
        [ -d "$path" ] || continue
        cpu=${path#/dev/cpu/}

        current=$(rdmsr -p "$cpu" 0x1a0)
        current_value=$((16#$current))

        # Clear only IA32_MISC_ENABLE bit 38.
        new_misc=$((current_value & ~(1 << 38)))

        wrmsr -p "$cpu" 0x1a0 \
            "$(printf '0x%x' "$new_misc")"

        cap=$(rdmsr -p "$cpu" 0x771)
        request=$(rdmsr -p "$cpu" 0x774)

        cap_value=$((16#$cap))
        request_value=$((16#$request))

        # IA32_HWP_CAPABILITIES bits 7:0 contain Highest_Performance.
        hwp_max=$((cap_value & 0xff))

        # Replace only IA32_HWP_REQUEST Maximum_Performance bits 15:8.
        new_hwp=$(
            (request_value & ~(0xff << 8)) |
            (hwp_max << 8)
        )

        wrmsr -p "$cpu" 0x774 \
            "$(printf '0x%x' "$new_hwp")"
    done
}

write_worker() {
    cat > "$WORKER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

modprobe msr

for path in /dev/cpu/[0-9]*; do
    [ -d "$path" ] || continue
    cpu=${path#/dev/cpu/}

    current=$(rdmsr -p "$cpu" 0x1a0)
    current_value=$((16#$current))

    # Clear only IA32_MISC_ENABLE bit 38.
    new_misc=$((current_value & ~(1 << 38)))

    wrmsr -p "$cpu" 0x1a0 \
        "$(printf '0x%x' "$new_misc")"

    cap=$(rdmsr -p "$cpu" 0x771)
    request=$(rdmsr -p "$cpu" 0x774)

    cap_value=$((16#$cap))
    request_value=$((16#$request))

    # Use this logical CPU's advertised Highest_Performance value.
    hwp_max=$((cap_value & 0xff))

    # Replace only HWP Maximum_Performance bits 15:8.
    new_hwp=$(
        (request_value & ~(0xff << 8)) |
        (hwp_max << 8)
    )

    wrmsr -p "$cpu" 0x774 \
        "$(printf '0x%x' "$new_hwp")"
done
EOF

    chmod 755 "$WORKER"
}

write_service() {
    cat > "$SERVICE" <<EOF
[Unit]
Description=DellThrottleFix adaptive CPU unthrottle workaround
After=multi-user.target
ConditionPathExists=$WORKER

[Service]
Type=oneshot
ExecStart=$WORKER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
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
        show_calculated_values
        show_frequencies
    fi

    echo

    if [ "$failed" -ne 0 ]; then
        echo "CHECK RESULT: Not ready."
        exit 1
    fi

    echo "CHECK RESULT: Ready."
    echo "No packages, files, services or MSRs were changed."
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
        printf '%-22s %s\n' "Service active:" "no"
    fi

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
        show_calculated_values
        show_all_msr_values
        show_frequencies
    fi
}

do_run_once() {
    require_root

    show_cpu_identity
    security_check
    ensure_msr_tools
    load_msr_module

    echo
    echo "Before:"
    show_calculated_values
    show_frequencies

    echo
    echo "Applying temporary workaround..."
    apply_workaround

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

    show_cpu_identity
    security_check
    ensure_msr_tools
    load_msr_module

    echo
    echo "Detected configuration:"
    show_calculated_values

    echo
    echo "Creating adaptive worker and systemd service..."
    write_worker
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
    echo "$PROGRAM_NAME will now run automatically during boot."
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
    *)
        echo "ERROR: Unknown option: $1" >&2
        echo >&2
        show_help >&2
        exit 2
        ;;
esac
