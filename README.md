# ProxStack

ProxStack is a an collection of scripts and workflows for managing Proxmox VE.

## Repository Layout

```text
.
├── templatectl.sh
├── patches/
│   ├── ssh.sh
│   ├── keyboard.sh
│   └── locale.sh
├── templates/        ← YAML config files for --config name lookup
├── images/           ← downloaded cloud images (auto-created)
└── stacks/
```

---

## templatectl.sh

Creates a Proxmox VE template for a given Linux cloud image.

### What It Does

- Downloads a cloud image into `images/` (skipped if already present).
- Detects distro family (`debian`, `ubuntu`, `fedora`, `rhel`).
- Creates and configures a VM in Proxmox.
- Builds cloud-init vendor-data (`packages`, `runcmd`, `write_files`, etc.).
- Applies built-in and optional patches.
- Converts the VM into a reusable template.

### Usage

```bash
./templatectl.sh --url <url> --id <id> --name <name> [OPTIONS]
./templatectl.sh --config <file|name> [OPTIONS]
```

### Required Options

Provide these on CLI, or via the config file keys `url`, `id`, and `name`.

| Option          | Description                                    |
| --------------- | ---------------------------------------------- |
| `--url <url>`   | URL to the cloud image to use for the template |
| `--id <id>`     | ID for the template                            |
| `--name <name>` | Name for the template                          |

### Options

| Option                         | Description                                                                                                             | Default                  |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| `--url <url>`                  | URL to the cloud image to use for the template                                                                          | (none)                   |
| `--id <id>`                    | ID for the template                                                                                                     | (none)                   |
| `--name <name>`                | Name for the template                                                                                                   | (none)                   |
| `--user <user>`                | Set the cloud-init user                                                                                                 | (none)                   |
| `--password <password>`        | Set the cloud-init password                                                                                             | (none)                   |
| `--upgrade`                    | Enable cloud-init package upgrade behavior                                                                              | disabled (`0`)           |
| `--net-bridge <bridge>`        | Network bridge for VM                                                                                                   | `vmbr0`                  |
| `--net-vlan <id>`              | VLAN tag for VM network interface (1-4094)                                                                              | (none)                   |
| `--memory <mb>`                | Memory in MB                                                                                                            | `2048`                   |
| `--cores <num>`                | Number of CPU cores                                                                                                     | `4`                      |
| `--cpu <type>`                 | CPU type for VM                                                                                                         | `x86-64-v2-AES`          |
| `--disk-scsihw <type>`         | SCSI controller model (e.g., `virtio-scsi-single`, `virtio-scsi-pci`, `lsi`)                                            | `virtio-scsi-single`     |
| `--timezone <timezone>`        | Timezone (e.g., America/New_York, Europe/London)                                                                        | (none)                   |
| `--keyboard-layout <layout>`   | Keyboard layout (e.g., us, uk, de)                                                                                      | (none)                   |
| `--keyboard-variant <variant>` | Keyboard variant (e.g., intl)                                                                                           | (none)                   |
| `--locale <locale>`            | Locale (e.g., en_US.UTF-8, de_DE.UTF-8)                                                                                 | (none)                   |
| `--ssh-keys <file>`            | Path to file with public SSH keys (one per line, OpenSSH format)                                                        | (none)                   |
| `--ssh-pwauth`                 | Enable SSH password authentication; if `--user root`, also allow root password login                                    | disabled                 |
| `--disk-size <size>`           | Disk size (e.g., 32G, 50G, 6144M)                                                                                       | image default            |
| `--disk-bus <type>`            | Disk bus/controller type: `scsi`, `virtio`, `sata`, `ide`                                                               | `scsi`                   |
| `--disk-storage <storage>`     | Proxmox storage for VM disk                                                                                             | `local-lvm`              |
| `--disk-format <format>`       | Disk format: ex. qcow2 (default)                                                                                        | `qcow2`                  |
| `--disk-flags <flags>`         | Space-separated Disk flags                                                                                              | `discard=on`             |
| `--display <type>`             | Set the display/vga type                                                                                                | `std`                    |
| `--packages <packages>`        | Space-separated list of packages to install in the template using cloud-init                                            | (none)                   |
| `--dns-servers <servers>`      | Space-separated DNS servers (e.g., '10.10.10.10 9.9.9.9')                                                               | (none)                   |
| `--dns-domains <domains>`      | Space-separated domain names (e.g., 'example.com internal.local')                                                       | (none)                   |
| `--snippets-storage <storage>` | Proxmox storage for cloud-init snippets                                                                                 | same as `--disk-storage` |
| `--patches <patches>`          | Space-separated list of patch names to apply                                                                            | (none)                   |
| `--script <file>`              | Local shell script to run as the last cloud-init runcmd step                                                            | (none)                   |
| `--onboot`                     | Start the VM automatically when the Proxmox host boots                                                                  | disabled                 |
| `--vendor-only`                | Write the final vendor-data file, print its absolute path, and exit before VM creation                                 | disabled                 |
| `--reboot`                     | Reboot the VM after cloud-init has completed                                                                            | disabled                 |
| `--config <file\|name>`        | YAML config file path, or a template name resolved from `templates/<name>.{yaml,yml}`; CLI flags override config values | (none)                   |
| `-h`, `--help`                 | Display this help message                                                                                               | n/a                      |
| `-V`, `--version`              | Display script version                                                                                                  | n/a                      |

---

### Config File (`--config`)

Instead of passing every option on the command line you can store them in a YAML file.

#### Resolution order

1. If the value is a path to an existing file, it is used directly.
2. Otherwise the script looks for `templates/<name>.yaml`, then `templates/<name>.yml`, relative to the script directory.
3. If neither exists, the script exits with an error showing the templates directory path.

#### Merge / override behaviour

Config values act as **defaults**. Any flag passed on the CLI **overrides** the corresponding config value.  
This means you can share a base config and override individual values per invocation.

> **Note:** Config values act as defaults. Any CLI flag overrides the corresponding config value, including `--url`, `--id`, and `--name`.

#### Full config schema

```yaml
# --- Required ---
url: https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
id: 9000
name: ubuntu24-template

# --- VM hardware ---
memory: 4096 # MB
cores: 4
cpu: x86-64-v2-AES
display: std

# --- Disk ---
disk:
  storage: local-lvm
  size: 32G # omit to keep image default
  bus: scsi # scsi (default), virtio, sata, ide
  format: qcow2
  scsihw: virtio-scsi-single
  flags:
    - discard=on
    - ssd=1

# --- Snippets ---
snippets:
  storage: local # omit to use same storage as disk.storage

# --- Cloud-init-related top-level keys ---
user: root
password: secret # at least one of password or keys required when user is set
upgrade: true # boolean; equivalent to --upgrade (default is false/disabled)
script: /root/proxstack/ci-script.sh
onboot: true # boolean; equivalent to --onboot (default is false/disabled)
reboot: true # boolean

# --- Packages ---
packages:
  - git
  - nginx

# --- Localization ---
timezone: Europe/Berlin
locale: de_DE.UTF-8

keyboard:
  layout: de
  variant: nodeadkeys

# --- Network ---
net:
  bridge: vmbr0
  vlan: 100 # omit to disable VLAN tagging

# --- DNS ---
dns:
  servers:
    - 1.1.1.1
    - 8.8.8.8
  domains:
    - home.arpa

# --- SSH ---
ssh:
  keys: /root/.ssh/authorized_keys
  pwauth: true # boolean; equivalent to --ssh-pwauth

# --- Custom patches ---
patches:
  - patch1
  - patch2
```

> All keys are optional. Omitted keys remain at their built-in defaults.

---

### Patch System

Patch functions are sourced automatically from `patches/*.sh`.

**Built-in patches (always applied):**

| Patch      | Behaviour                                                             |
| ---------- | --------------------------------------------------------------------- |
| `ssh`      | Enables and starts the SSH service (distro-aware: `ssh` vs `sshd`)    |
| `keyboard` | Applies keyboard layout using the correct mechanism per distro family |
| `locale`   | Applies locale using the correct mechanism per distro family          |

**Optional patches:**

| Patch        | How to activate                                | Behaviour                                                                                                                                                                                       |
| ------------ | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ssh_pwauth` | `--ssh-pwauth` or `ssh.pwauth: true` in config | Enables SSH password authentication; writes a high-priority drop-in under `/etc/ssh/sshd_config.d/` to avoid being overridden by cloud-init; if user is `root`, also sets `PermitRootLogin yes` |
| _custom_     | `--patches "name"` or `patches:` in config     | Any function defined in `patches/*.sh`                                                                                                                                                          |

All patch functions receive the same four arguments in this order:

```bash
patch_fn <vendor_data_file> <image_file> <distro> <distro_family>
```

---

### Notes and Gotchas

- **`--user` requires credentials.** At least one of `--password` or `--ssh-keys` must also be provided when `--user` is set.
- **Config path values should be absolute paths.** For `ssh.keys` and `script` in YAML config, use absolute filesystem paths. Relative paths and unexpanded forms like `~` will fail validation as "file not found".
- **Avoid reserved usernames.** Do not use usernames that clash with existing system groups (e.g. `admin`). Cloud-init fails silently when it tries to create a group that already exists. `root` is a safe exception.
- **Disk format support varies by storage type.** Check the Proxmox docs.
- **Image caching.** Downloaded images are stored in `images/` and reused on subsequent runs. Delete the file manually to force a fresh download.
- **Snippets storage must support `snippets` content type.** The storage must list `snippets` in its `content` field in `/etc/pve/storage.cfg`, otherwise the script exits with a validation error.
- **VM ID must not already exist.** The script exits early if the given ID is already in use in Proxmox.
- **`qemu-guest-agent` is always installed** and enabled on every template, regardless of other options.

---

### Examples

#### Minimal — CLI only

```bash
./templatectl.sh \
  --url https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  --id 9000 \
  --name ubuntu24-template \
  --user root \
  --ssh-keys ~/.ssh/authorized_keys \
  --disk-storage local-lvm
```

#### Full — CLI only

```bash
./templatectl.sh \
  --url https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  --id 9000 \
  --name ubuntu24-template \
  --user root \
  --password secret \
  --ssh-keys ~/.ssh/authorized_keys \
  --upgrade \
  --memory 4096 \
  --cores 4 \
  --cpu host \
  --display std \
  --net-bridge vmbr0 \
  --net-vlan 100 \
  --disk-storage local \
  --snippets-storage local \
  --disk-size 32G \
  --disk-bus scsi \
  --disk-scsihw virtio-scsi-single \
  --disk-format qcow2 \
  --disk-flags "discard=on" \
  --timezone Europe/Berlin \
  --keyboard-layout de \
  --keyboard-variant nodeadkeys \
  --locale de_DE.UTF-8 \
  --dns-servers "1.1.1.1 8.8.8.8" \
  --dns-domains "home.arpa" \
  --packages "git nginx" \
  --ssh-pwauth \
  --patches "patch1 patch2" \
  --script ./ci-script.sh \
  --onboot \
  --reboot
```

#### Config file — all values from file

```bash
# templates/ubuntu24.yaml contains required keys (url, id, name) and all options
./templatectl.sh --config ubuntu24
```

#### Config file — explicit path

```bash
./templatectl.sh --config /etc/proxstack/ubuntu24.yaml
```

#### Config file — override a single value at runtime

```bash
# Use the ubuntu24 template but allocate more memory for this run
./templatectl.sh --config ubuntu24 --memory 8192
```

#### Config file — override required options (deploy a variant)

```bash
# Reuse all settings from ubuntu24 but use a different URL, VM ID, and name
./templatectl.sh \
  --config ubuntu24 \
  --url https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  --id 9001 \
  --name staging-template
```

---

## Supported Distro Families

| Family   | Detected distros                                    |
| -------- | --------------------------------------------------- |
| `debian` | Debian                                              |
| `ubuntu` | Ubuntu                                              |
| `fedora` | Fedora                                              |
| `rhel`   | Rocky Linux, AlmaLinux, CentOS Stream, RHEL, RedHat |

## Tested Images

| Distro          | Image URL                                                                                                                           |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Ubuntu 24.04    | <https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img>                                                     |
| Debian 12       | <https://cdimage.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2>                                        |
| Debian 13       | <https://cdimage.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2>                                          |
| Fedora 43       | <https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2> |
| Rocky Linux 9   | <https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2>                                      |
| AlmaLinux 9     | <https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2>                           |
| CentOS Stream 9 | <https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2>                           |
