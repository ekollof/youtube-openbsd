# Andrath's OpenBSD tools for youtube.

## What is this?

These are little projects I mentioned or have built for youtube videos and/or
streams.

These scripts/programs are primarily for OpenBSD only, and probably might not
work on your loonix. Your mileage may vary.


## Screen recorder

A script that records your screen and your audio, and which is xrandr aware.

```
Usage: screen-record.ksh [-s screen] [-l] [-h] [-c config] [-b bitrate] [-n] [-d] [-m]
  -s screen   Select screen number (0, 1, 2, etc.)
  -l         List available screens
  -h         Show this help message
  -c config  Source configuration file for streaming (sets RTMP_URI and STREAM_KEY)
  -b bitrate Video bitrate in kbps (default: 8000, YouTube 1080p60 recommendation)
  -n         Enable noise gate on mic input
  -d         Enable noise suppression on mic input
  -m         Measure ambient noise to tune noise gate (requires -n)
Press 'q' or Ctrl+C to stop streaming cleanly.
```

## VM manare for OpenBSD VMM

```
Usage: vm_manager.sh {create|clone|import|give|take|list|start|stop|archive|delete} [options]
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
  archive <vm_name> - Archive VM to /var/vmm/archive
  delete <vm_name> - Delete archived VM
  NOTE: Rocky unsupported by vmd
```

TODO:
- Add ability to install from custom ISOs
- Rename VMs
- Add IPv6 support

