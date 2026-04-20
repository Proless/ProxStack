# ProxStack

ProxStack contains automation scripts for Proxmox VE:

- `templatectl.sh`: build cloud-image based VM templates.
- `stackctl.sh`: scaffold and manage stack directories for Terraform + Ansible workflows.

## Repository Layout

```text
.
├── templatectl.sh
├── stackctl.sh
├── patches/
│   ├── ssh.sh
│   ├── keyboard.sh
│   └── locale.sh
└── stacks/
```

## templatectl.sh

Creates a Proxmox VE VM template from a Linux cloud image and prepares cloud-init vendor-data.

### What It Does

- Downloads a cloud image.
- Detects distro family (`debian`, `ubuntu`, `fedora`, `rhel`).
- Creates and configures a VM in Proxmox.
- Builds cloud-init vendor-data (`packages`, `runcmd`, `write_files`, etc.).
- Applies built-in and optional patches.
- Converts the VM into a reusable template.

### Usage

```bash
./templatectl.sh <url> <id> <name> [OPTIONS]
```

### Required Arguments

- `url`: cloud image URL.
- `id`: Proxmox VM ID.
- `name`: template name.

### Options

| Option                         | Description                                                                                             | Default              |
| ------------------------------ | ------------------------------------------------------------------------------------------------------- | -------------------- |
| `--user <user>`                | Cloud-init user                                                                                         | (none)               |
| `--password <password>`        | Cloud-init password                                                                                     | (none)               |
| `--ssh-keys <file>`            | Path to public key file                                                                                 | (none)               |
| `--ssh-pwauth`                 | Adds `ssh_pwauth` patch (enables SSH password auth; allows root password login only when `--user root`) | disabled             |
| `--memory <mb>`                | VM memory                                                                                               | `2048`               |
| `--cores <num>`                | VM cores                                                                                                | `4`                  |
| `--bridge <bridge>`            | Proxmox bridge                                                                                          | `vmbr0`              |
| `--vlan <id>`                  | VLAN tag for `net0` (1-4094)                                                                            | (none)               |
| `--display <type>`             | VGA/display type                                                                                        | `std`                |
| `--disk-size <size>`           | Disk size (for example `32G`)                                                                           | image default        |
| `--disk-storage <storage>`     | Disk storage                                                                                            | `local-lvm`          |
| `--disk-format <format>`       | Disk format (`qcow2`, `raw`, `vmdk`, storage-dependent)                                                 | `qcow2`              |
| `--disk-flags <flags>`         | Space-separated disk flags                                                                              | `discard=on`         |
| `--snippets-storage <storage>` | Storage for cloud-init snippets                                                                         | same as disk storage |
| `--timezone <timezone>`        | Timezone                                                                                                | (none)               |
| `--keyboard <layout>`          | Keyboard layout                                                                                         | (none)               |
| `--keyboard-variant <variant>` | Keyboard variant                                                                                        | (none)               |
| `--locale <locale>`            | Locale                                                                                                  | (none)               |
| `--install <packages>`         | Space-separated extra packages                                                                          | (none)               |
| `--dns-servers <servers>`      | Space-separated DNS servers                                                                             | (none)               |
| `--domain-names <domains>`     | Space-separated search domains                                                                          | (none)               |
| `--patches <patches>`          | Space-separated additional patch names                                                                  | (none)               |
| `--script <file>`              | Local script injected into guest and executed via cloud-init                                            | (none)               |
| `--reboot`                     | Add cloud-init reboot power-state                                                                       | disabled             |
| `-h`, `--help`                 | Show help                                                                                               | n/a                  |
| `-V`, `--version`              | Show version                                                                                            | n/a                  |

### Patch Model

Patch functions are auto-loaded from `patches/*.sh`.

Built-in patches always applied:

- `ssh`
- `keyboard`
- `locale`

Optional patches:

- Any patch passed in `--patches`.
- `--ssh-pwauth` injects the `ssh_pwauth` patch.

Current patch files:

- `patches/ssh.sh`
- `patches/keyboard.sh`
- `patches/locale.sh`

All patch functions are invoked with the same arguments and order:

```bash
patch_fn <vendor_data_file> <image_file> <distro> <distro_family>
```

### Notes

- If `--user` is set, at least one of `--password` or `--ssh-keys` is required.
- Distro detection uses `virt-inspector`, then normalizes compatible distros into supported families.
- `qemu-guest-agent` is installed and enabled by default.

### Example

```bash
ID=9000
NAME="ubuntu24"
IMAGE="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

./templatectl.sh "$IMAGE" "$ID" "$NAME-template" \
  --user admin \
  --ssh-keys ~/.ssh/authorized_keys \
  --disk-storage local-lvm \
  --vlan 100 \
  --ssh-pwauth \
  --script ./ci-script.sh
```

## stackctl.sh

Manages stack directories under `stacks/` and orchestrates Terraform/Ansible flows.

### Usage

```bash
./stackctl.sh <stack-name> <command> [options]
```

### Commands

- `create`: create `stacks/<stack-name>` scaffold and symlink shared assets.
- `deploy`: run Terraform deploy and Ansible configure.
- `destroy`: destroy Terraform-managed infrastructure.
- `delete`: delete stack directory (optionally destroy first).

### Options

| Option | Description                                                      |
| ------ | ---------------------------------------------------------------- |
| `-f`   | Force clean reinstall/refresh of dependencies and temp artifacts |
| `-v`   | Verbose mode (show full Terraform/Ansible output)                |
| `-d`   | With `delete`, destroy before deleting stack directory           |

### stackctl.sh Expectations

`create` expects shared assets to exist:

- `shared/ansible/`
- `shared/terraform/`

`deploy` expects repository-level dependency files:

- `requirements.txt`
- `requirements.yml`

## Supported Distro Families (templatectl.sh)

- `debian`
- `ubuntu`
- `fedora`
- `rhel` (includes normalized compatibles like Rocky, AlmaLinux, CentOS Stream, and RHEL)
