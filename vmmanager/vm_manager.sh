#!/bin/ksh

# Check root privileges and curl
[ "$(id -u)" -ne 0 ] && { echo "Not root, trying doas..." >&2; command -v doas >/dev/null 2>&1 && exec doas "$0" "$@" || { echo "Run as root or with doas." >&2; exit 1; }; }
command -v curl >/dev/null 2>&1 || { echo "Requires curl. Install with 'pkg_add curl'." >&2; exit 1; }

# Config
VM_DIR="/var/vmm"
VM_BASE_DIR="$VM_DIR/vms"
ISO_DIR="$VM_DIR/isos"
ARCHIVE_DIR="$VM_DIR/archive"
METADATA_FILE="$VM_DIR/vm_metadata"
VM_CONF="/etc/vm.conf"
BASE_URL="https://cdn.openbsd.org/pub/OpenBSD"
SNAPSHOT_URL="${BASE_URL}/snapshots/amd64"
ROCKY_URL="https://dl.rockylinux.org/pub/rocky"
DHCPD_LEASES="/var/db/dhcpd.leases"
HOSTS_FILE="/etc/hosts"

# Ensure directory with perms
ensure_dir() { [ -d "$1" ] || { mkdir -p "$1" && chown root:wheel "$1" && chmod 0700 "$1"; } || { echo "Error: Failed to create $1" >&2; exit 1; }; }

# Setup environment
setup_environment() {
    [ -f "/etc/hostname.vport0" ] && [ -f "/etc/hostname.veb0" ] || {
        echo "inet 10.0.0.1 255.255.255.0 up" > /etc/hostname.vport0
        echo "add vport0 up" > /etc/hostname.veb0
        sh /etc/netstart vport0 veb0 || { echo "Error: Network setup failed" >&2; exit 1; }
    }
    [ -f "$VM_CONF" ] && grep -q "switch \"vmswitch\"" "$VM_CONF" || {
        echo "switch \"vmswitch\" { interface veb0 }" > "$VM_CONF"
        chown root:wheel "$VM_CONF" && chmod 0640 "$VM_CONF" && rcctl reload vmd || { echo "Error: vm.conf setup failed" >&2; exit 1; }
    }
    if [ -f "/etc/dhcpd.conf" ] && ! grep -q "subnet 10.0.0.0[ \t]*netmask 255.255.255.0" "/etc/dhcpd.conf"; then
        cat >> /etc/dhcpd.conf << EOF
subnet 10.0.0.0 netmask 255.255.255.0 {
    range 10.0.0.100 10.0.0.200;
    option routers 10.0.0.1;
    option domain-name-servers 1.1.1.1;
}
EOF
    fi
    rcctl get dhcpd flags | grep -q "vport0" || { rcctl enable dhcpd && rcctl set dhcpd flags vport0 || { echo "Error: dhcpd setup failed" >&2; exit 1; }; }
    rcctl check unwind >/dev/null 2>&1 || rcctl enable unwind
    grep -q "match out on egress from vport0:network" /etc/pf.conf || {
        echo "match out on egress from vport0:network to any nat-to (egress)\npass in proto { udp tcp } from 10.0.0.0/24 to any port domain rdr-to 127.0.0.1 port domain\npass all" >> /etc/pf.conf
        pfctl -f /etc/pf.conf || { echo "Error: PF setup failed" >&2; exit 1; }
    }
    rcctl check dhcpd >/dev/null 2>&1 || rcctl start dhcpd || { echo "Error: dhcpd start failed" >&2; exit 1; }
    rcctl check unwind >/dev/null 2>&1 || rcctl start unwind || { echo "Error: unwind start failed" >&2; exit 1; }
    rcctl check vmd >/dev/null 2>&1 || rcctl enable vmd
    rcctl check vmd >/dev/null 2>&1 || rcctl start vmd || { echo "Error: vmd start failed" >&2; exit 1; }
}

# Migrate metadata to include owner field
migrate_metadata() {
    if [ -f "$METADATA_FILE" ] && [ -s "$METADATA_FILE" ]; then
        if grep -v "^[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:" "$METADATA_FILE" >/dev/null 2>&1; then
            echo "Migrating metadata to include owner field" >&2
            mv "$METADATA_FILE" "$METADATA_FILE.bak" || { echo "Error: Backup failed" >&2; exit 1; }
            while IFS=: read -r vm_name os disk_size memory qcow2 archived; do
                [ -z "$vm_name" ] && continue
                os_val=$(echo "$os" | cut -d= -f2)
                disk_val=$(echo "$disk_size" | cut -d= -f2)
                mem_val=$(echo "$memory" | cut -d= -f2)
                qcow_val=$(echo "$qcow2" | cut -d= -f2)
                arch_val=$(echo "$archived" | cut -d= -f2)
                echo "$vm_name:os=$os_val:disk_size=$disk_val:memory=$mem_val:qcow2=$qcow_val:archived=$arch_val:owner=root" >> "$METADATA_FILE"
            done < "$METADATA_FILE.bak" || { echo "Error: Migration failed" >&2; mv "$METADATA_FILE.bak" "$METADATA_FILE"; exit 1; }
            echo "Migration complete. Backup at $METADATA_FILE.bak" >&2
        fi
    fi
}

# Remove VM metadata
remove_metadata() {
    [ ! -f "$METADATA_FILE" ] && { touch "$METADATA_FILE" && chown root:wheel "$METADATA_FILE" && chmod 0600 "$METADATA_FILE"; echo "Created empty $METADATA_FILE" >&2; return; }
    if [ -s "$METADATA_FILE" ] && grep -q "^$1:" "$METADATA_FILE"; then
        grep -v "^$1:" "$METADATA_FILE" > "$METADATA_FILE.tmp"
        status=$?
        [ $status -ge 2 ] && { echo "Error: Failed to filter $METADATA_FILE (grep failed, exit code: $status)" >&2; ls -l "$METADATA_FILE" >&2; exit 1; }
        mv "$METADATA_FILE.tmp" "$METADATA_FILE" || { echo "Error: Failed to update $METADATA_FILE" >&2; ls -l "$METADATA_FILE.tmp" "$METADATA_FILE" >&2; exit 1; }
    fi
}

# Update /etc/hosts from dhcpd.leases with VM override
update_hosts_with_vm_name() {
    [ ! -f "$DHCPD_LEASES" ] && { echo "No lease file found" >&2; return; }
    tmp_hosts="/tmp/hosts.tmp"
    cp "$HOSTS_FILE" "$tmp_hosts" || { echo "Error: Failed to copy $HOSTS_FILE" >&2; exit 1; }
    
    local lease_ip="" hostname="" vm_entries=""
    if [ -f "/tmp/hosts.tmp.vm" ]; then
        vm_entries=$(cat "/tmp/hosts.tmp.vm")
        rm -f "/tmp/hosts.tmp.vm"
    fi
    
    while read -r line; do
        case $line in
            lease\ 10.0.0.[0-9]{1,3})
                lease_ip=$(echo "$line" | sed 's/lease \(10\.0\.0\.[0-9]\{1,3\}\) .*/\1/')
                ;;
            *\ client-hostname\ *)
                hostname=$(echo "$line" | sed 's/.*client-hostname "\(.*\)";/\1/')
                ;;
            *\ ends\ *)
                end_time=$(echo "$line" | sed 's/.*ends [0-9] \(.*\) UTC;/\1/')
                end_epoch=$(date -j -f "%Y/%m/%d %H:%M:%S" "$end_time" "+%s" 2>/dev/null) || continue
                if [ "$end_epoch" -gt "$(date +%s)" ] && [ -n "$lease_ip" ] && [ -n "$hostname" ]; then
                    if echo "$vm_entries" | grep -q "^$lease_ip "; then
                        continue
                    fi
                    echo "$lease_ip $hostname" >> "$tmp_hosts.new"
                fi
                lease_ip=""; hostname=""
                ;;
        esac
    done < "$DHCPD_LEASES"
    
    if [ -n "$vm_entries" ]; then
        echo "$vm_entries" >> "$tmp_hosts.new"
    fi
    
    cat "$tmp_hosts" "$tmp_hosts.new" 2>/dev/null | grep -v "^$" | sort -u > "$tmp_hosts.final"
    mv "$tmp_hosts.final" "$HOSTS_FILE" && chown root:wheel "$HOSTS_FILE" && chmod 0644 "$HOSTS_FILE"
    rm -f "$tmp_hosts" "$tmp_hosts.new"
}

# Init dirs and env
ensure_dir "$VM_DIR" "$VM_BASE_DIR" "$ISO_DIR" "$ARCHIVE_DIR"
[ -f "$METADATA_FILE" ] || touch "$METADATA_FILE" && chown root:wheel "$METADATA_FILE" && chmod 0600 "$METADATA_FILE"
setup_environment
migrate_metadata

# Fetch ISO
fetch_iso() {
    case $1 in
        "debian") url="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"; iso_file=$(curl -s "$url/" | grep -o "debian-[0-9.]*-amd64-netinst.iso" | tail -1); ;;
        "ubuntu") url="http://releases.ubuntu.com"; latest_ver=$(curl -s "$url/" | grep -o "[0-9][0-9]\.[0-9][0-9]" | sort -V | tail -1); url="$url/$latest_ver"; iso_file="ubuntu-$latest_ver-live-server-amd64.iso"; ;;
        "alpine") url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64"; iso_file=$(curl -s "$url/" | grep -o "alpine-virt-[0-9.]*-x86_64.iso" | tail -1); ;;
        "openbsd-snapshot") url="$SNAPSHOT_URL"; iso_file=$(curl -s "$url/" | grep -o "install[0-9][0-9].iso" | tail -1); ;;
        "openbsd-stable") latest_ver=$(curl -s "$BASE_URL/" | grep -o "[0-9]\.[0-9]" | sort -V | tail -1); iso_ver=$(echo "$latest_ver" | sed 's/\.//'); iso_file="install${iso_ver}.iso"; url="${BASE_URL}/$latest_ver/amd64"; ;;
        "rocky") url="${ROCKY_URL}/9/isos/x86_64"; iso_file=$(curl -s "$url/" | grep -o "Rocky-9\.[0-9]-x86_64-minimal.iso" | sort -V | tail -1); echo "Warning: Rocky unsupported by vmd" >&2; ;;
        *) echo "Error: Unsupported OS: $1" >&2; exit 1; ;;
    esac
    [ -z "$iso_file" ] && { echo "Error: Failed to find ISO for $1" >&2; exit 1; }
    iso_path="$ISO_DIR/$iso_file"
    partial="$iso_path.partial"
    if [ "$1" = "openbsd-snapshot" ] || [ ! -f "$iso_path" ]; then
        [ -f "$partial" ] && [ "$1" != "openbsd-snapshot" ] && curl -L -C - --progress-bar -o "$partial" "$url/$iso_file" || curl -L --progress-bar -o "$partial" "$url/$iso_file" || { echo "Error: ISO fetch failed" >&2; exit 1; }
        mv "$partial" "$iso_path" && chown root:wheel "$iso_path" && chmod 0600 "$iso_path" || { echo "Error: ISO finalize failed" >&2; exit 1; }
    fi
    printf "%s" "$iso_file"
}

# Update metadata with owner
update_metadata() {
    if [ -f "$METADATA_FILE" ] && [ -s "$METADATA_FILE" ]; then
        grep -v "^$1:" "$METADATA_FILE" > "$METADATA_FILE.tmp"
        status=$?
        [ $status -ge 2 ] && { echo "Error: Failed to filter $METADATA_FILE (grep failed, exit code: $status)" >&2; ls -l "$METADATA_FILE" >&2; exit 1; }
        mv "$METADATA_FILE.tmp" "$METADATA_FILE" || { echo "Error: Failed to update $METADATA_FILE" >&2; ls -l "$METADATA_FILE.tmp" "$METADATA_FILE" >&2; exit 1; }
    else
        [ -f "$METADATA_FILE" ] || { touch "$METADATA_FILE" && chown root:wheel "$METADATA_FILE" && chmod 0600 "$METADATA_FILE"; }
    fi
    echo "$1:os=$2:disk_size=$3:memory=$4:qcow2=${6:-$VM_BASE_DIR/$1/$1.qcow2}:archived=${5:-no}:owner=${7:-root}" >> "$METADATA_FILE" || { echo "Error: Metadata append failed" >&2; ls -l "$METADATA_FILE" >&2; exit 1; }
}

# Update vm.conf with owner and allow-instance
update_vm_conf() {
    tmp_conf="$VM_CONF.tmp"
    (
        echo "switch \"vmswitch\" {"
        echo "    interface veb0"
        echo "}"
        while IFS=: read -r vm_name os disk_size memory qcow2 archived owner; do
            [ -z "$vm_name" ] && continue
            if [ "${archived#*=}" = "no" ]; then
                owner=${owner:-owner=root}
                echo "vm \"$vm_name\" {"
                echo "    owner ${owner#*=}"
                echo "    memory ${memory#*=}"
                echo "    disk \"${qcow2#*=}\""
                echo "    interface { switch \"vmswitch\" }"
                [ "${owner#*=}" != "root" ] && echo "    allow instance { boot, disk, memory }"
                echo "    disable"
                echo "}"
            fi
        done < "$METADATA_FILE"
    ) > "$tmp_conf" || { echo "Error: Failed to write $tmp_conf" >&2; exit 1; }
    mv "$tmp_conf" "$VM_CONF" || { echo "Error: Failed to move $tmp_conf to $VM_CONF" >&2; exit 1; }
    rcctl reload vmd || { echo "Error: vmd reload failed" >&2; cat "$VM_CONF" >&2; exit 1; }
}

# Create VM
create_vm() {
    vm_name="$1"
    os="$2"
    disk_size="${3:-20G}"
    memory="${4:-1G}"
    vm_dir="$VM_BASE_DIR/$vm_name"
    qcow2="$vm_dir/$vm_name.qcow2"
    
    iso_file=$(fetch_iso "$os") || exit 1
    iso_path="$ISO_DIR/$iso_file"
    
    ensure_dir "$vm_dir"
    [ -f "$qcow2" ] || { vmctl create -s "$disk_size" "$qcow2" && chown root:wheel "$qcow2" && chmod 0600 "$qcow2" || { echo "Error: Disk creation failed" >&2; exit 1; }; }
    ln -sf "$iso_path" "$vm_dir/install.iso" || { echo "Error: ISO symlink failed" >&2; exit 1; }
    update_metadata "$vm_name" "$os" "$disk_size" "$memory"
    [ -f "$iso_path" ] || { echo "Error: ISO missing: $iso_path" >&2; remove_metadata "$vm_name"; exit 1; }
    
    echo "Starting $vm_name with installer. Complete installation, then exit with ~." >&2
    vmctl start -m "$memory" -n vmswitch -i 1 -r "$iso_path" -d "$qcow2" -c "$vm_name" || \
        { echo "Error: VM start failed" >&2; remove_metadata "$vm_name"; exit 1; }
    # No wait needed; vmctl -c runs in foreground and returns when console exits
    
    if [ "$(stat -f %z "$qcow2")" -lt 10485760 ]; then
        echo "Error: Installation incomplete (qcow2 size too small: $(stat -f %z "$qcow2") bytes)" >&2
        vmctl stop "$vm_name" >/dev/null 2>&1
        remove_metadata "$vm_name"
        rm -f "$vm_dir/install.iso" "$qcow2"
        rmdir "$vm_dir" 2>/dev/null
        exit 1
    fi
    
    update_vm_conf >/dev/null 2>&1 || { echo "Error: Failed to update vm.conf" >&2; exit 1; }
    update_hosts_with_vm_name >/dev/null 2>&1 || { echo "Error: Failed to update hosts" >&2; exit 1; }
    echo "Installation complete. Start with 'doas ./vm_manager.sh start $vm_name' to boot from disk." >&2
}

# Clone VM
clone_vm() {
    src_vm="$1"
    new_vm="$2"
    src_entry=$(grep "^$src_vm:" "$METADATA_FILE") || { echo "Error: Source VM $src_vm not found" >&2; exit 1; }
    src_qcow2=$(echo "$src_entry" | cut -d: -f5 | cut -d= -f2)
    [ -f "$src_qcow2" ] || { echo "Error: Source qcow2 $src_qcow2 not found" >&2; exit 1; }
    new_dir="$VM_BASE_DIR/$new_vm"
    new_qcow2="$new_dir/$new_vm.qcow2"
    ensure_dir "$new_dir"
    cp "$src_qcow2" "$new_qcow2" && chown root:wheel "$new_qcow2" && chmod 0600 "$new_qcow2" || { echo "Error: Failed to clone qcow2" >&2; exit 1; }
    os=$(echo "$src_entry" | cut -d: -f2 | cut -d= -f2)
    disk_size=$(echo "$src_entry" | cut -d: -f3 | cut -d= -f2)
    memory=$(echo "$src_entry" | cut -d: -f4 | cut -d= -f2)
    update_metadata "$new_vm" "$os" "$disk_size" "$memory" "no" "$new_qcow2"
    update_vm_conf
}

# Import qcow2
import_vm() {
    new_vm="$1"
    src_qcow2="$2"
    [ -f "$src_qcow2" ] || { echo "Error: qcow2 file $src_qcow2 not found" >&2; exit 1; }
    new_dir="$VM_BASE_DIR/$new_vm"
    new_qcow2="$new_dir/$new_vm.qcow2"
    ensure_dir "$new_dir"
    cp "$src_qcow2" "$new_qcow2" && chown root:wheel "$new_qcow2" && chmod 0600 "$new_qcow2" || { echo "Error: Failed to import qcow2" >&2; exit 1; }
    echo "Enter OS (e.g., openbsd-stable, debian): " >&2; read os
    echo "Enter disk size (default 20G): " >&2; read disk_size; disk_size=${disk_size:-20G}
    echo "Enter memory (default 1G): " >&2; read memory; memory=${memory:-1G}
    update_metadata "$new_vm" "$os" "$disk_size" "$memory" "no" "$new_qcow2"
    update_vm_conf
}

# Give VM to user
give_vm() {
    vm_name="$1"
    user="$2"
    vm_entry=$(grep "^$vm_name:" "$METADATA_FILE") || { echo "Error: VM $vm_name not found" >&2; exit 1; }
    id "$user" >/dev/null 2>&1 || { echo "Error: User $user not found" >&2; exit 1; }
    os=$(echo "$vm_entry" | cut -d: -f2 | cut -d= -f2)
    disk_size=$(echo "$vm_entry" | cut -d: -f3 | cut -d= -f2)
    memory=$(echo "$vm_entry" | cut -d: -f4 | cut -d= -f2)
    archived=$(echo "$vm_entry" | cut -d: -f6 | cut -d= -f2)
    qcow2=$(echo "$vm_entry" | cut -d: -f5 | cut -d= -f2)
    update_metadata "$vm_name" "$os" "$disk_size" "$memory" "$archived" "$qcow2" "$user"
    update_vm_conf
    echo "Assigned $vm_name to $user" >&2
}

# Take VM back to root
take_vm() {
    vm_name="$1"
    vm_entry=$(grep "^$vm_name:" "$METADATA_FILE") || { echo "Error: VM $vm_name not found" >&2; exit 1; }
    os=$(echo "$vm_entry" | cut -d: -f2 | cut -d= -f2)
    disk_size=$(echo "$vm_entry" | cut -d: -f3 | cut -d= -f2)
    memory=$(echo "$vm_entry" | cut -d: -f4 | cut -d= -f2)
    archived=$(echo "$vm_entry" | cut -d: -f6 | cut -d= -f2)
    qcow2=$(echo "$vm_entry" | cut -d: -f5 | cut -d= -f2)
    update_metadata "$vm_name" "$os" "$disk_size" "$memory" "$archived" "$qcow2" "root"
    update_vm_conf
    echo "Reclaimed $vm_name to root" >&2
}

# Archive VM
archive_vm() {
    vm_entry=$(grep "^$1:" "$METADATA_FILE") || { echo "Error: VM $1 not found" >&2; exit 1; }
    vmctl stop "$1" >/dev/null 2>&1
    qcow2=$(echo "$vm_entry" | cut -d: -f5 | cut -d= -f2)
    archived_qcow2="$ARCHIVE_DIR/$(basename "$qcow2")"
    mv "$qcow2" "$archived_qcow2" && chown root:wheel "$archived_qcow2" && chmod 0600 "$archived_qcow2" || { echo "Error: Archive failed" >&2; exit 1; }
    owner=$(echo "$vm_entry" | cut -d: -f7 | cut -d= -f2)
    update_metadata "$1" "$(echo "$vm_entry" | cut -d: -f2 | cut -d= -f2)" "$(echo "$vm_entry" | cut -d: -f3 | cut -d= -f2)" "$(echo "$vm_entry" | cut -d: -f4 | cut -d= -f2)" "yes" "$archived_qcow2" "$owner"
    rm -rf "$(dirname "$qcow2")" && update_vm_conf || { echo "Error: Cleanup failed" >&2; exit 1; }
}

# Delete VM
delete_vm() {
    vm_entry=$(grep "^$1:" "$METADATA_FILE")
    [ -z "$vm_entry" ] && { echo "Error: VM $1 not found" >&2; exit 1; }
    [ "$(echo "$vm_entry" | cut -d: -f6 | cut -d= -f2)" != "yes" ] && { echo "Error: VM $1 not archived" >&2; exit 1; }
    qcow2=$(echo "$vm_entry" | cut -d: -f5 | cut -d= -f2)
    [ -f "$qcow2" ] && rm -f "$qcow2"
    remove_metadata "$1"
}

# Check network for a VM, return IP if responsive
check_network() {
    vm_name="$1"
    tmp_leases="$2"
    leases_before="$3"
    leases=$(cat "$DHCPD_LEASES" 2>/dev/null || echo "")
    echo "$leases" > "$tmp_leases"
    
    if [ -n "$leases_before" ]; then
        new_leases=$(diff "$leases_before" "$tmp_leases" 2>/dev/null | grep "^> lease 10\.0\.0\.[0-9]\{1,3\}" | sed 's/> lease \(10\.0\.0\.[0-9]\{1,3\}\).*/\1/' | tr '\n' ' ' | sed 's/ $//')
        leases_to_check="$new_leases"
    else
        leases_to_check=$(grep "lease 10\.0\.0\.[0-9]\{1,3\}" "$tmp_leases" | sed 's/lease \(10\.0\.0\.[0-9]\{1,3\}\).*/\1/')
    fi
    
    for ip in $leases_to_check; do
        ends_line=$(grep -A4 "lease $ip" "$tmp_leases" | grep "ends [0-9]" | tail -1)
        end_time=$(echo "$ends_line" | sed 's/.*ends [0-9] \([0-9/ :]*\).*/\1/')
        end_epoch=$(date -j -f "%Y/%m/%d %H:%M:%S" "$end_time" "+%s" 2>/dev/null || echo "invalid")
        now=$(date +%s)
        if [ "$end_epoch" != "invalid" ] && [ "$end_epoch" -gt "$now" ]; then
            if ping -c 2 "$ip" >/dev/null 2>&1; then
                echo "$ip $vm_name" > /tmp/hosts.tmp.vm
                update_hosts_with_vm_name
                echo "$ip"
                return 0
            fi
        fi
    done
    return 1
}

# Start VM and wait for lease
start_vm() {
    vm_name="$1"
    vm_entry=$(grep "^$vm_name:" "$METADATA_FILE") || { echo "Error: VM $vm_name not found" >&2; exit 1; }
    
    tmp_leases="/tmp/leases_$$"
    if vmctl show | grep -q "$vm_name.*running"; then
        echo "Starting $vm_name: already running, verifying network..." >&2
        i=0
        while [ "$i" -lt 5 ]; do
            sleep 2
            if ip=$(check_network "$vm_name" "$tmp_leases"); then
                echo "Started $vm_name at $ip" >&2
                rm -f "$tmp_leases"
                return
            fi
            i=$((i + 1))
        done
        echo "Warning: $vm_name running but network not confirmed after 10s" >&2
        rm -f "$tmp_leases"
        return
    fi
    
    echo "Starting $vm_name..." >&2
    tmp_before="/tmp/leases_before_$$"
    leases_before=$(cat "$DHCPD_LEASES" 2>/dev/null || echo "")
    echo "$leases_before" > "$tmp_before"
    
    vmctl start "$vm_name" >/dev/null 2>&1 || {
        echo "Warning: $vm_name start failed, resetting vmd state..." >&2
        vmctl reset vms >/dev/null 2>&1 || { echo "Error: vmd reset failed" >&2; exit 1; }
        sleep 2
        vmctl start "$vm_name" >/dev/null 2>&1 || { echo "Error: $vm_name start failed after reset" >&2; exit 1; }
    }
    
    i=0
    tmp_after="/tmp/leases_after_$$"
    while [ "$i" -lt 15 ]; do
        sleep 2
        if ip=$(check_network "$vm_name" "$tmp_after" "$tmp_before"); then
            echo "Started $vm_name at $ip" >&2
            rm -f "$tmp_before" "$tmp_after"
            return
        fi
        i=$((i + 1))
    done
    echo "Warning: $vm_name network not confirmed after 30s" >&2
    rm -f "$tmp_before" "$tmp_after"
}

# Stop VM
stop_vm() {
    vm_name="$1"
    echo "Stopping $vm_name..." >&2
    vmctl stop "$vm_name" >/dev/null 2>&1 || { echo "Error: Failed to stop $vm_name" >&2; exit 1; }
    update_vm_conf >/dev/null 2>&1 || { echo "Error: Failed to update vm.conf" >&2; exit 1; }
    
    tmp_hosts="/tmp/hosts.tmp"
    cp "$HOSTS_FILE" "$tmp_hosts" || { echo "Error: Failed to copy $HOSTS_FILE" >&2; exit 1; }
    grep -v " $vm_name$" "$tmp_hosts" > "$tmp_hosts.new" && mv "$tmp_hosts.new" "$HOSTS_FILE"
    chown root:wheel "$HOSTS_FILE" && chmod 0644 "$HOSTS_FILE"
    rm -f "$tmp_hosts"
    echo "Stopped $vm_name" >&2
}

# List VMs
list_vms() {
    echo "Virtual Machines:" >&2
    vmctl show | awk '
        NR==1 {printf "%-5s %-6s %-5s %-7s %-7s %-6s %-8s %-8s %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9}
        NR>1 {printf "%-5s %-6s %-5s %-7s %-7s %-6s %-8s %-8s %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9}'
    echo "" >&2
    
    echo "Metadata:" >&2
    cat "$METADATA_FILE" | sort | while read -r line; do
        echo "  $line" >&2
    done
    echo "" >&2
    
    echo "ISOs:" >&2
    ls -lh "$ISO_DIR" | awk 'NR>1 {print "  " $1 " " $2 " " $3 " " $4 " " $5 " " $6 " " $7 " " $8 " " $9}' >&2
    echo "" >&2
    
    echo "Archived:" >&2
    ls -lh "$ARCHIVE_DIR" | awk 'NR>1 {print "  " $1 " " $2 " " $3 " " $4 " " $5 " " $6 " " $7 " " $8 " " $9}' >&2
    echo "" >&2
    
    update_hosts_with_vm_name
    echo "Hosts:" >&2
    cat "$HOSTS_FILE" | while read -r line; do
        echo "  $line" >&2
    done
}

# Usage
usage() {
    echo "Usage: $0 {create|clone|import|give|take|list|start|stop|archive|delete} [options]
  Must be root or use doas
  Requires curl (pkg_add curl)
  Sets up vport0, veb0, dhcpd, unwind, pf, vm.conf
  create <vm_name> <os> [disk_size] [memory] - Create VM, connect console
    os: debian, ubuntu, alpine, openbsd-snapshot, openbsd-stable, rocky (unsupported)
  clone <src_vm> <new_vm> - Clone an existing VM
  import <vm_name> <qcow2_path> - Import a qcow2 file as a new VM
  give <vm_name> <user> - Assign VM ownership to user
  take <vm_name> - Reclaim VM ownership to root
  list - List VMs, metadata, ISOs, hosts
  start <vm_name> - Start VM and update hosts
  stop <vm_name> - Stop VM and clean up hosts
  archive <vm_name> - Archive VM to $ARCHIVE_DIR
  delete <vm_name> - Delete archived VM
  NOTE: Rocky unsupported by vmd" >&2
    exit 1
}

# Main
case $1 in
    "create") [ $# -lt 3 ] && usage; create_vm "$2" "$3" "$4" "$5"; ;;
    "clone") [ $# -lt 3 ] && usage; clone_vm "$2" "$3"; ;;
    "import") [ $# -lt 3 ] && usage; import_vm "$2" "$3"; ;;
    "give") [ $# -lt 3 ] && usage; give_vm "$2" "$3"; ;;
    "take") [ $# -lt 2 ] && usage; take_vm "$2"; ;;
    "list") list_vms; ;;
    "start") [ $# -lt 2 ] && usage; start_vm "$2"; ;;
    "stop") [ $# -lt 2 ] && usage; stop_vm "$2"; ;;
    "archive") [ $# -lt 2 ] && usage; archive_vm "$2"; ;;
    "delete") [ $# -lt 2 ] && usage; delete_vm "$2"; ;;
    *) usage; ;;
esac
