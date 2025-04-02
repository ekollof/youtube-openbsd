# VM Manager for OpenBSD

A comprehensive shell script for managing virtual machines on OpenBSD using VMD. This tool simplifies the creation, management, and networking of virtual machines.

## Overview

The VM Manager script provides an easy-to-use interface for managing virtual machines on OpenBSD. It handles:

- Automatic environment setup (networking, DHCP, firewall)
- VM creation from various OS images (OpenBSD, Debian, Ubuntu, Alpine, etc.)
- VM lifecycle management (start, stop, archive, delete)
- User permissions and ownership management
- Network configuration and hostname mapping

## Requirements

- OpenBSD (tested on recent versions)
- Root privileges or doas access
- curl package (`pkg_add curl`)

## Installation

1. Clone this repository:

    git clone https://github.com/ekollof/youtube-openbsd.git
    cd youtube-openbsd/vmmanager

2. Ensure the script is executable:

    chmod +x vm_manager.sh

## Usage

The script must be run as root or with doas.

    doas ./vm_manager.sh {create|clone|import|give|take|list|start|stop|archive|delete} [options]

### Commands

#### Create a VM

    doas ./vm_manager.sh create <vm_name> <os> [disk_size] [memory]

Supported OS options:
- debian
- ubuntu
- alpine
- openbsd-snapshot
- openbsd-stable
- rocky (unsupported by vmd)

Example:

    doas ./vm_manager.sh create myopenbsd openbsd-stable 20G 1G

#### Clone a VM

    doas ./vm_manager.sh clone <source_vm> <new_vm>

Example:

    doas ./vm_manager.sh clone myopenbsd myopenbsd-clone

#### Import an existing QCOW2 image

    doas ./vm_manager.sh import <vm_name> <qcow2_path>

Example:

    doas ./vm_manager.sh import imported-vm /path/to/image.qcow2

#### Assign VM to a user

    doas ./vm_manager.sh give <vm_name> <user>

Example:

    doas ./vm_manager.sh give myopenbsd user1

#### Reclaim VM ownership to root

    doas ./vm_manager.sh take <vm_name>

Example:

    doas ./vm_manager.sh take myopenbsd

#### List all VMs and resources

    doas ./vm_manager.sh list

#### Start a VM

    doas ./vm_manager.sh start <vm_name>

Example:

    doas ./vm_manager.sh start myopenbsd

#### Stop a VM

    doas ./vm_manager.sh stop <vm_name>

Example:

    doas ./vm_manager.sh stop myopenbsd

#### Archive a VM

    doas ./vm_manager.sh archive <vm_name>

Example:

    doas ./vm_manager.sh archive myopenbsd

#### Delete an archived VM

    doas ./vm_manager.sh delete <vm_name>

Example:

    doas ./vm_manager.sh delete myopenbsd

## Features

### Network Setup

The script automatically sets up:
- Virtual network interfaces (vport0, veb0)
- DHCP server configuration
- DNS forwarding with unwind
- NAT and firewall rules with PF

### VM Management

- Creates VM disk images in QCOW2 format
- Downloads ISO images from official sources
- Maps DHCP leases to hostnames in /etc/hosts
- Provides clear logging of VM operations
- Maintains metadata for all managed VMs

### User Management

- Allows assigning VMs to non-root users
- Configures appropriate permissions in vm.conf
- Enables instance control for user-owned VMs

## Directory Structure

The script creates and manages the following directory structure:

- `/var/vmm/` - Base directory for all VM data
- `/var/vmm/vms/` - VM disk images and configurations
- `/var/vmm/isos/` - Downloaded installation media
- `/var/vmm/archive/` - Archived VM disk images

## Technical Details

- Uses VMD (OpenBSD's VM daemon) for virtualization
- Maintains VM metadata in `/var/vmm/vm_metadata`
- Configures `/etc/vm.conf` for VM definitions
- Updates `/etc/hosts` for VM hostname resolution
- Manages DHCP leases from `/var/db/dhcpd.leases`

## Troubleshooting

If you encounter issues:

1. Check VM status with `doas ./vm_manager.sh list`
2. Review system logs with `doas dmesg | tail`
3. Ensure networking is properly set up with `ifconfig vport0` and `ifconfig veb0`
4. Verify DHCP server is running with `rcctl status dhcpd`
5. Check VM daemon status with `rcctl status vmd`

## Author

Emiel Kollof (ekollof)
Last updated: 2025-04-02
