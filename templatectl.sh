#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
#
# templatectl.sh - Creates Proxmox VE templates from cloud-init images.
# Repository: https://git.mukhtabar.de/proxmox/proxstack
# Maintainers: Proless

set -e

# ==============================================================================
# GLOBAL VARIABLES & CONFIGURATION
# ==============================================================================

# Supported distro families. RHEL-compatible distros are normalized to "rhel".
declare -a SUPPORTED_DISTROS=("debian" "ubuntu" "fedora" "rhel")

# Storage configuration
declare -A DISK_STORAGE_CONFIG=()
declare -A SNIPPETS_STORAGE_CONFIG=()

# VM hardware configuration
declare -A VM_CONFIG=(
	[memory]="2048"       # Memory in MB (default: 2048)
	[cores]="4"           # Number of CPU cores (default: 4)
	[cpu]="x86-64-v2-AES" # CPU type (default: x86-64-v2-AES)
	[display]="std"       # Display type (e.g., std, cirrus, vmware, qxl)
)

# Disk configuration
declare -A DISK_CONFIG=(
	[size]=""             # Disk size for the VM (e.g., 32G)
	[format]="qcow2"      # Disk format: qcow2 (default), raw, or vmdk
	[flags]="discard=on"  # Default disk flags
	[storage]="local-lvm" # The Proxmox storage where the VM disk will be allocated (default: local-lvm)
)

# Cloud-init configuration
declare -A CLOUD_INIT_CONFIG=(
	[user]=""       # Cloud-init user
	[password]=""   # Cloud-init password
	["ssh-keys"]="" # Path to file with public SSH keys
)

# Localization configuration
declare -A LOCALIZATION_CONFIG=(
	[timezone]=""           # Timezone
	[keyboard]=""           # Keyboard layout
	["keyboard-variant"]="" # Keyboard variant
	[locale]=""             # Locale
)

# Network configuration
declare -A NETWORK_CONFIG=(
	[bridge]="vmbr0" # The Proxmox network bridge for the VM (default: vmbr0)
	[vlan]=""        # Optional VLAN tag for net0 (1-4094)
)

# Network DNS configuration
declare -A DNS_CONFIG=(
	[servers]="" # DNS servers
	[domains]="" # Domain search domains
)

# Snippets configuration
declare -A SNIPPETS_CONFIG=(
	[storage]="" # Storage where snippets are stored (default: same as DISK_CONFIG[storage])
)

declare -a MERGED_ARGS=() # Final merged arguments built from config defaults + CLI overrides

# Template identification
ID=""            # ID for the template
URL=""           # Cloud Image URL
NAME=""          # Name for the template
DISTRO=""        # Raw distro detected from the image
IMAGE_FILE=""    # Local path to the downloaded image file
DISTRO_FAMILY="" # Normalized distro family used for feature selection

# Advanced options
PACKAGES_TO_INSTALL=""          # Space-separated list of packages to install inside the VM template
PATCHES_TO_APPLY=""             # Space-separated list of patches to apply
SCRIPT_FILE=""                  # Local script file to write via cloud-init and run as final runcmd step
REBOOT_AFTER_CLOUD_INIT="false" # Reboot VM after cloud-init completes

# Metadata
VERSION="1.0.0"

# ==============================================================================
# UTILITY
# ==============================================================================

quiet_run() {
	"$@" >/dev/null 2>&1 || {
		echo "Command failed: $*" >&2
		exit 1
	}
}

die() {
	echo "Error: $*" >&2
	exit 1
}

usage() {
	echo "Usage: $0 --url <url> --id <id> --name <name> [OPTIONS]"
	echo "       $0 --config <file|name> [OPTIONS]"
	echo ""
	echo "Creates a Proxmox VE template for a given Linux cloud image."
	echo ""
	echo "Required options:"
	echo "  --url <url>                    URL to the cloud image to use for the template"
	echo "  --id <id>                      ID for the template"
	echo "  --name <name>                  Name for the template"
	echo ""
	echo "Options:"
	echo "  --user <user>                  Set the cloud-init user"
	echo "  --password <password>          Set the cloud-init password"
	echo "  --bridge <bridge>              Network bridge for VM (default: vmbr0)"
	echo "  --vlan <id>                    VLAN tag for VM network interface (1-4094)"
	echo "  --memory <mb>                  Memory in MB (default: 2048)"
	echo "  --cores <num>                  Number of CPU cores (default: 4)"
	echo "  --cpu <type>                   CPU type for VM (default: x86-64-v2-AES)"
	echo "  --timezone <timezone>          Timezone (e.g., America/New_York, Europe/London)"
	echo "  --keyboard <layout>            Keyboard layout (e.g., us, uk, de)"
	echo "  --keyboard-variant <variant>   Keyboard variant (e.g., intl)"
	echo "  --locale <locale>              Locale (e.g., en_US.UTF-8, de_DE.UTF-8)"
	echo "  --ssh-keys <file>              Path to file with public SSH keys (one per line, OpenSSH format)"
	echo "  --ssh-pwauth                   Enable SSH password authentication; if --user root, also allow root password login"
	echo "  --disk-size <size>             Disk size (e.g., 32G, 50G, 6144M)"
	echo "  --disk-storage <storage>       Proxmox storage for VM disk (default: local-lvm)"
	echo "  --disk-format <format>         Disk format: ex. qcow2 (default)"
	echo "  --disk-flags <flags>           Space-separated Disk flags (default: discard=on)"
	echo "  --display <type>               Set the display/vga type (default: std)"
	echo "  --packages <packages>          Space-separated list of packages to install in the template using cloud-init"
	echo "  --dns-servers <servers>        Space-separated DNS servers (e.g., '10.10.10.10 9.9.9.9')"
	echo "  --dns-domains <domains>       Space-separated domain names (e.g., 'example.com internal.local')"
	echo "  --snippets-storage <storage>   Proxmox storage for cloud-init snippets (default: same as --disk-storage)"
	echo "  --patches <patches>            Space-separated list of patch names to apply"
	echo "  --script <file>                Local shell script to run as the last cloud-init runcmd step"
	echo "  --reboot                       Reboot the VM after cloud-init has completed"
	echo "  --config <file|name>           YAML config file path, or a template name resolved from templates/<name>.{yaml,yml}; CLI flags override config values"
	echo "  -h,  --help                    Display this help message"
	echo "  -V,  --version                 Display script version"

	echo ""
	echo "Supported distro families: ${SUPPORTED_DISTROS[*]}"
	echo "RHEL-compatible images such as Rocky, CentOS, AlmaLinux, and RHEL are normalized to rhel"
}

print_version() {
	echo "$(basename "$0") ${VERSION}"
}

load_patches() {
	local script_dir
	local patch_dir
	local patch_file

	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	patch_dir="${script_dir}/patches"

	if [[ ! -d "${patch_dir}" ]]; then
		die "Patch directory not found: ${patch_dir}"
	fi

	shopt -s nullglob
	for patch_file in "${patch_dir}"/*.sh; do
		# shellcheck disable=SC1090
		source "${patch_file}"
	done
	shopt -u nullglob
}

build_args_from_config() {
	local config_file="${1}"
	local -n _out_args="${2}"
	local val

	# Helper: read a yq path and append a CLI flag+value if the key is present.
	_cfg_flag() {
		local yq_path="${1}" flag="${2}"
		val="$(yq -r "${yq_path} // empty" "${config_file}")"
		[[ -n "${val}" ]] && _out_args+=("${flag}" "${val}")
	}

	# Helper: read a yq path and append a boolean CLI flag if the key is true.
	_cfg_bool() {
		local yq_path="${1}" flag="${2}"
		val="$(yq -r "${yq_path} // empty" "${config_file}")"
		[[ "${val}" == "true" ]] && _out_args+=("${flag}")
	}

	# Helper: read a yq path as a YAML list and append a space-joined CLI flag+value.
	_cfg_list_flag() {
		local yq_path="${1}" flag="${2}" key_name="${3}" node_type
		node_type="$(yq -r "${yq_path} | type" "${config_file}")"

		if [[ "${node_type}" == "!!seq" ]]; then
			val="$(yq -r "${yq_path} | join(\" \")" "${config_file}")"
			[[ -n "${val}" ]] && _out_args+=("${flag}" "${val}")
		elif [[ "${node_type}" != "!!null" ]]; then
			die "Invalid config key '${key_name}': expected a YAML list"
		fi
	}

	# Required options:
	_cfg_flag '.url' "--url"
	_cfg_flag '.id' "--id"
	_cfg_flag '.name' "--name"

	# vm:
	_cfg_flag '.vm.memory' "--memory"
	_cfg_flag '.vm.cores' "--cores"
	_cfg_flag '.vm.cpu' "--cpu"
	_cfg_flag '.vm.display' "--display"

	# disk:
	_cfg_flag '.disk.storage' "--disk-storage"
	_cfg_flag '.disk.size' "--disk-size"
	_cfg_flag '.disk.format' "--disk-format"
	_cfg_list_flag '.disk.flags' "--disk-flags" "disk.flags"

	# snippets:
	_cfg_flag '.snippets.storage' "--snippets-storage"

	# cloud-init:
	_cfg_flag '.["cloud-init"].user' "--user"
	_cfg_flag '.["cloud-init"].password' "--password"
	_cfg_flag '.["cloud-init"]["ssh-keys"]' "--ssh-keys"
	_cfg_flag '.["cloud-init"].script' "--script"
	_cfg_bool '.["cloud-init"].reboot' "--reboot"

	# packages:
	_cfg_list_flag '.packages' "--packages" "packages"

	# localization:
	_cfg_flag '.localization.timezone' "--timezone"
	_cfg_flag '.localization.keyboard' "--keyboard"
	_cfg_flag '.localization["keyboard-variant"]' "--keyboard-variant"
	_cfg_flag '.localization.locale' "--locale"

	# network:
	_cfg_flag '.network.bridge' "--bridge"
	_cfg_flag '.network.vlan' "--vlan"
	_cfg_list_flag '.network.dns.servers' "--dns-servers" "network.dns.servers"
	_cfg_list_flag '.network.dns.domains' "--dns-domains" "network.dns.domains"

	# ssh:
	_cfg_bool '.ssh.pwauth' "--ssh-pwauth"

	# Top-level misc:
	_cfg_list_flag '.patches' "--patches" "patches"
}

normalize_distro() {
	case "${1}" in
	debian | ubuntu | fedora)
		echo "${1}"
		;;
	rocky | centos | almalinux | rhel | redhat | redhat-based)
		echo "rhel"
		;;
	*)
		return 1
		;;
	esac
}

apply_patches() {
	local vendor_data_file="${1}"
	local image_file="${2}"
	local patches="${PATCHES_TO_APPLY}"

	# Built-in patches decide distro-specific behavior internally.
	patches+=" ssh keyboard locale"

	IFS=' ' read -ra patches_array <<<"${patches}"
	for patch in "${patches_array[@]}"; do
		if declare -f "${patch}" >/dev/null; then
			echo "Applying patch ${patch}..."
			"${patch}" "${vendor_data_file}" "${image_file}" "${DISTRO}" "${DISTRO_FAMILY}"
		else
			echo "Warning: Unknown patch '${patch}' specified. Skipping."
		fi
	done
}

# ==============================================================================
# CLOUD-INIT VENDOR DATA
# ==============================================================================

ci_create_base_config() {
	local vendor_data_file="${1}"

	# Create base vendor-data file with update settings
	yq -y -n \
		" .package_update = true
        | .package_reboot_if_required = true
        | .packages = []
        | .write_files = []
        | .runcmd = []
		" >"${vendor_data_file}"
}

ci_add_qemu_guest_agent() {
	local vendor_data_file="${1}"

	# Add qemu-guest-agent package
	yq -i -y ".packages += [\"qemu-guest-agent\"]" "${vendor_data_file}"

	# Add distro-specific commands to enable and start qemu-guest-agent
	case "${DISTRO_FAMILY}" in
	debian | ubuntu | fedora | rhel)
		yq -i -y ".runcmd += [\"systemctl enable qemu-guest-agent\"]" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"systemctl start qemu-guest-agent\"]" "${vendor_data_file}"
		;;
	esac
}

ci_add_extra_packages() {
	local vendor_data_file="${1}"

	# Append extra packages if specified
	if [[ -n "${PACKAGES_TO_INSTALL}" ]]; then
		IFS=' ' read -ra pkg_array <<<"${PACKAGES_TO_INSTALL}"
		for pkg in "${pkg_array[@]}"; do
			yq -i -y ".packages += [\"${pkg}\"]" "${vendor_data_file}"
		done
	fi
}

ci_add_localization() {
	local vendor_data_file="${1}"

	# Add locale configuration
	[[ -n "${LOCALIZATION_CONFIG[locale]}" ]] && yq -i -y ".locale = \"${LOCALIZATION_CONFIG[locale]}\"" "${vendor_data_file}"

	# Add timezone configuration
	[[ -n "${LOCALIZATION_CONFIG[timezone]}" ]] && yq -i -y ".timezone = \"${LOCALIZATION_CONFIG[timezone]}\"" "${vendor_data_file}"

	# Add keyboard configuration
	if [[ -n "${LOCALIZATION_CONFIG[keyboard]}" ]]; then
		yq -i -y ".keyboard.layout = \"${LOCALIZATION_CONFIG[keyboard]}\"" "${vendor_data_file}"
		[[ -n "${LOCALIZATION_CONFIG["keyboard-variant"]}" ]] && yq -i -y ".keyboard.variant = \"${LOCALIZATION_CONFIG["keyboard-variant"]}\"" "${vendor_data_file}"
	fi
}

ci_add_script() {
	local vendor_data_file="${1}"

	[[ -z "${SCRIPT_FILE}" ]] && return 0

	local script_path="/usr/local/sbin/ci_script.sh"
	local script_b64

	script_b64=$(base64 -w 0 "${SCRIPT_FILE}")

	SCRIPT_B64="${script_b64}" yq -i -y '.write_files += [{"path":"/usr/local/sbin/ci_script.sh","owner":"root:root","permissions":"0755","encoding":"b64","content": env.SCRIPT_B64}]' "${vendor_data_file}"
	yq -i -y ".runcmd += [\"${script_path}\"]" "${vendor_data_file}"
}

ci_add_reboot() {
	local vendor_data_file="${1}"

	[[ "${REBOOT_AFTER_CLOUD_INIT}" != "true" ]] && return 0

	yq -i -y '.power_state = {"mode":"reboot","message":"Rebooting after cloud-init completion","timeout":30,"condition":true}' "${vendor_data_file}"
}

ci_build_vendor_data() {
	local vendor_data_file="${1}"

	echo "Building cloud-init vendor-data..."
	ci_create_base_config "${vendor_data_file}"
	ci_add_qemu_guest_agent "${vendor_data_file}"
	ci_add_extra_packages "${vendor_data_file}"
	ci_add_localization "${vendor_data_file}"
	ci_add_reboot "${vendor_data_file}"
	ci_add_script "${vendor_data_file}"
}

# ==============================================================================
# TEMPLATE
# ==============================================================================

prepare_disk() {
	local image_file="${1}"

	# Resize disk if size specified
	if [[ -n "${DISK_CONFIG[size]}" ]]; then
		echo "Resizing disk to ${DISK_CONFIG[size]}..."
		quiet_run qemu-img resize "${image_file}" "${DISK_CONFIG[size]}"
	fi
}

create_vm() {
	local image_file="${1}"
	local net0_config="virtio,macaddr=00:00:00:00:00:00,bridge=${NETWORK_CONFIG[bridge]}"

	[[ -n "${NETWORK_CONFIG[vlan]}" ]] && net0_config+=",tag=${NETWORK_CONFIG[vlan]}"

	echo "Creating VM ${ID}..."
	quiet_run qm create "${ID}" --name "${NAME}" \
		--memory "${VM_CONFIG[memory]}" \
		--cpu "${VM_CONFIG[cpu]}" \
		--cores "${VM_CONFIG[cores]}" \
		--net0 "${net0_config}" \
		--agent enabled=1 \
		--ostype l26 \
		--vga "${VM_CONFIG[display]}" \
		--serial0 socket

	echo "Importing disk..."
	quiet_run qm importdisk "${ID}" "${image_file}" "${DISK_STORAGE_CONFIG[name]}" --format "${DISK_CONFIG[format]}"
}

configure_vm() {
	echo "Configuring VM storage and cloud-init..."

	# Build disk path based on storage type
	local disk_path
	if [[ "${DISK_STORAGE_CONFIG[type]}" =~ ^(lvmthin|zfspool|rbd)$ ]]; then
		# Block storage types use simple format: storage:vm-ID-disk-N
		disk_path="${DISK_STORAGE_CONFIG[name]}:vm-${ID}-disk-0"
	else
		# Directory-based storage types use: storage:ID/vm-ID-disk-N.format
		disk_path="${DISK_STORAGE_CONFIG[name]}:${ID}/vm-${ID}-disk-0.${DISK_CONFIG[format]}"
	fi

	# Build qm set command with conditional cloud-init parameters
	local qm_cmd=(qm set "${ID}"
		--scsihw "virtio-scsi-single"
		--scsi0 "${disk_path},${DISK_CONFIG[flags]// /,}"
		--ide0 "${DISK_STORAGE_CONFIG[name]}:cloudinit"
		--boot "order=scsi0"
		--ciupgrade 1
		--cicustom "vendor=${SNIPPETS_STORAGE_CONFIG[name]}:snippets/ci-vendor-data-${ID}.yml"
		--ipconfig0 "ip=dhcp"
	)

	# Add DNS servers if specified
	[[ -n "${DNS_CONFIG[servers]}" ]] && qm_cmd+=(--nameserver "${DNS_CONFIG[servers]}")

	# Add search domain if specified
	[[ -n "${DNS_CONFIG[domains]}" ]] && qm_cmd+=(--searchdomain "${DNS_CONFIG[domains]}")

	# Add cloud-init user settings if user is specified
	if [[ -n "${CLOUD_INIT_CONFIG[user]}" ]]; then
		qm_cmd+=(--ciuser "${CLOUD_INIT_CONFIG[user]}")
		[[ -n "${CLOUD_INIT_CONFIG[password]}" ]] && qm_cmd+=(--cipassword "${CLOUD_INIT_CONFIG[password]}")
		[[ -n "${CLOUD_INIT_CONFIG["ssh-keys"]}" ]] && qm_cmd+=(--sshkeys "${CLOUD_INIT_CONFIG["ssh-keys"]}")
	fi

	quiet_run "${qm_cmd[@]}"
}

create_template() {
	echo "Creating template ${NAME} (ID: ${ID})..."

	local tmp_yaml
	local image_copy
	local vendor_data_file

	tmp_yaml=$(mktemp)
	image_copy="${NAME}.${IMAGE_FILE##*.}"
	vendor_data_file="${SNIPPETS_STORAGE_CONFIG[snippets_dir]}/ci-vendor-data-${ID}.yml"

	# Create a copy of the image
	cp "${IMAGE_FILE}" "${image_copy}"

	# Build the complete vendor-data
	ci_build_vendor_data "${tmp_yaml}"

	# Apply patches
	apply_patches "${tmp_yaml}" "${image_copy}"

	# Prepend header and create the final ci config file
	{
		echo "#cloud-config"
		cat "${tmp_yaml}"
	} >"${vendor_data_file}"

	# Prepare the disk
	prepare_disk "${image_copy}"

	# Create VM
	create_vm "${image_copy}"

	# Configure VM
	configure_vm

	# Convert to template
	echo "Converting VM ${ID} to a template..."
	quiet_run qm template "${ID}"

	# Clean up temporary files
	rm -f "${tmp_yaml}"
	rm -f "${image_copy}"

	echo "Template ${NAME} created successfully"
}

# ==============================================================================
# ARGUMENT
# ==============================================================================

require_arg_file() {
	if [[ ! -f "${1}" || ! -s "${1}" ]]; then
		die "File not found or empty: ${2} (${1})"
	fi
}

require_arg_string() {
	if [[ -z "${1}" ]]; then
		die "Missing required argument: ${2}"
	fi
}

require_arg_number() {
	if ! [[ "${1}" =~ ^[0-9]+$ && "${1}" -gt 0 ]]; then
		die "Argument '${2}' must be a positive number (got '${1}')"
	fi
}

require_arg_vlan() {
	if ! [[ "${1}" =~ ^[0-9]+$ ]] || [[ "${1}" -lt 1 ]] || [[ "${1}" -gt 4094 ]]; then
		die "Argument '${2}' must be a VLAN ID between 1 and 4094 (got '${1}')"
	fi
}

parse_storage_config() {
	local storage="${1}"
	local -n storage_config="${2}"

	local cfg="/etc/pve/storage.cfg"

	if [[ ! -f "${cfg}" ]]; then
		echo "Error: Storage configuration file not found at ${cfg}" >&2
		return 1
	fi

	# Initialize variables
	local in_section=0
	local storage_type=""
	local path=""
	local content=""
	local content_dirs=""

	# Parse storage.cfg to find the storage section and extract information
	while IFS= read -r line; do
		# Check if this is our storage header
		if [[ "${line}" =~ ^(dir|nfs|cifs|cephfs|lvmthin|zfspool|rbd):[[:space:]]+${storage}$ ]]; then
			in_section=1
			storage_type="${BASH_REMATCH[1]}"
			continue
		fi

		# Check if we're entering a new storage section
		if [[ "${line}" =~ ^[a-z]+: ]]; then
			if [[ "${in_section}" -eq 1 ]]; then
				break
			fi
		fi

		# Extract properties if in our section
		if [[ "${in_section}" -eq 1 ]]; then
			if [[ "${line}" =~ ^[[:space:]]+path[[:space:]]+(.+)$ ]]; then
				path="${BASH_REMATCH[1]}"
			elif [[ "${line}" =~ ^[[:space:]]+content[[:space:]]+(.+)$ ]]; then
				content="${BASH_REMATCH[1]}"
			elif [[ "${line}" =~ ^[[:space:]]+content-dirs[[:space:]]+(.+)$ ]]; then
				content_dirs="${BASH_REMATCH[1]}"
			fi
		fi
	done <"${cfg}"

	# Validate results
	if [[ "${in_section}" -eq 0 ]]; then
		echo "Error: Storage '${storage}' not found or is not supported." >&2
		return 1
	fi

	# For network storage types, default to /mnt/pve/<storage> if path is empty
	if [[ "${storage_type}" =~ ^(nfs|cifs|cephfs)$ ]] && [[ -z "${path}" ]]; then
		path="/mnt/pve/${storage}"
	fi

	# Check if storage supports images
	local supports_images="false"
	local image_formats=""
	if [[ "${content}" == *"images"* ]]; then
		supports_images="true"

		# Set supported image formats based on storage type
		case "${storage_type}" in
		dir)
			image_formats="raw,qcow2,vmdk,subvol"
			;;
		nfs | cifs)
			image_formats="raw,qcow2,vmdk"
			;;
		lvmthin)
			image_formats="raw"
			;;
		zfspool)
			image_formats="raw,subvol"
			;;
		rbd)
			image_formats="raw"
			;;
		esac
	fi

	# Check if storage supports snippets
	local supports_snippets="false"
	local snippets_dir=""
	if [[ "${content}" == *"snippets"* && -n "${path}" ]]; then
		supports_snippets="true"

		# Determine snippets directory
		local relative_dir="snippets"

		# Check if content-dirs has a custom snippets path
		if [[ -n "${content_dirs}" ]] && [[ "${content_dirs}" =~ snippets=([^,]+) ]]; then
			relative_dir="${BASH_REMATCH[1]}"
		fi

		# Construct full path
		snippets_dir="${path}/${relative_dir}"

		mkdir -p "${snippets_dir}"
	fi

	# Store configuration in associative array
	storage_config["name"]="${storage}"
	storage_config["type"]="${storage_type}"
	storage_config["path"]="${path}"
	storage_config["content"]="${content}"
	storage_config["content_dirs"]="${content_dirs}"
	storage_config["supports_images"]="${supports_images}"
	storage_config["image_formats"]="${image_formats}"
	storage_config["supports_snippets"]="${supports_snippets}"
	# shellcheck disable=SC2034
	storage_config["snippets_dir"]="${snippets_dir}"
}

parse_arguments() {
	while [[ "$#" -gt 0 ]]; do
		case "${1}" in
		--url)
			URL="${2}"
			shift 2
			;;
		--id)
			ID="${2}"
			shift 2
			;;
		--name)
			NAME="${2}"
			shift 2
			;;
		--user)
			CLOUD_INIT_CONFIG[user]="${2}"
			shift 2
			;;
		--password)
			CLOUD_INIT_CONFIG[password]="${2}"
			shift 2
			;;
		--memory)
			VM_CONFIG[memory]="${2}"
			shift 2
			;;
		--cores)
			VM_CONFIG[cores]="${2}"
			shift 2
			;;
		--cpu)
			VM_CONFIG[cpu]="${2}"
			shift 2
			;;
		--bridge)
			NETWORK_CONFIG[bridge]="${2}"
			shift 2
			;;
		--vlan)
			NETWORK_CONFIG[vlan]="${2}"
			shift 2
			;;
		--disk-size)
			DISK_CONFIG[size]="${2}"
			shift 2
			;;
		--disk-storage)
			DISK_CONFIG[storage]="${2}"
			SNIPPETS_CONFIG[storage]="${SNIPPETS_CONFIG[storage]:-${2}}"
			shift 2
			;;
		--disk-format)
			DISK_CONFIG[format]="${2}"
			shift 2
			;;
		--disk-flags)
			DISK_CONFIG[flags]="${2}"
			shift 2
			;;
		--display)
			VM_CONFIG[display]="${2}"
			shift 2
			;;
		--timezone)
			LOCALIZATION_CONFIG[timezone]="${2}"
			shift 2
			;;
		--keyboard)
			LOCALIZATION_CONFIG[keyboard]="${2}"
			shift 2
			;;
		--keyboard-variant)
			LOCALIZATION_CONFIG["keyboard-variant"]="${2}"
			shift 2
			;;
		--locale)
			LOCALIZATION_CONFIG[locale]="${2}"
			shift 2
			;;
		--ssh-keys)
			CLOUD_INIT_CONFIG["ssh-keys"]="${2}"
			shift 2
			;;
		--ssh-pwauth)
			PATCHES_TO_APPLY+=" ssh_pwauth"
			shift
			;;
		--dns-servers)
			DNS_CONFIG[servers]="${2}"
			shift 2
			;;
		--dns-domains)
			DNS_CONFIG[domains]="${2}"
			shift 2
			;;
		--snippets-storage)
			SNIPPETS_CONFIG[storage]="${2}"
			shift 2
			;;
		--packages)
			PACKAGES_TO_INSTALL="${2}"
			shift 2
			;;
		--patches)
			PATCHES_TO_APPLY="${2}"
			shift 2
			;;
		--script)
			SCRIPT_FILE="${2}"
			shift 2
			;;
		--reboot)
			REBOOT_AFTER_CLOUD_INIT="true"
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		-V | --version)
			print_version
			exit 0
			;;
		*)
			die "Unknown option: ${1}"
			;;
		esac
	done

	# Parse storage configuration
	parse_storage_config "${DISK_CONFIG[storage]}" DISK_STORAGE_CONFIG
	if [[ "${SNIPPETS_CONFIG[storage]}" == "${DISK_CONFIG[storage]}" ]]; then
		# Copy storage config
		for key in "${!DISK_STORAGE_CONFIG[@]}"; do
			SNIPPETS_STORAGE_CONFIG["${key}"]="${DISK_STORAGE_CONFIG[${key}]}"
		done
	else
		parse_storage_config "${SNIPPETS_CONFIG[storage]}" SNIPPETS_STORAGE_CONFIG
	fi
}

validate_args() {
	# Validate required parameters
	require_arg_number "${ID}" "id (--id)"
	if qm status "${ID}" &>/dev/null; then
		die "ID ${ID} already exists. Please choose a different ID."
	fi

	require_arg_string "${URL}" "url (--url)"
	require_arg_string "${NAME}" "name (--name)"

	require_arg_string "${DISK_CONFIG[storage]}" "disk storage (--disk-storage)"
	require_arg_string "${DISK_CONFIG[format]}" "disk format (--disk-format)"
	require_arg_string "${NETWORK_CONFIG[bridge]}" "network bridge (--bridge)"

	require_arg_number "${VM_CONFIG[memory]}" "memory (--memory)"
	require_arg_number "${VM_CONFIG[cores]}" "cores (--cores)"

	# Validate optional parameters
	if [[ -n "${CLOUD_INIT_CONFIG[user]}" ]]; then
		if [[ -z "${CLOUD_INIT_CONFIG[password]}" && -z "${CLOUD_INIT_CONFIG["ssh-keys"]}" ]]; then
			die "You must provide at least one of --password or --ssh-keys when --user is specified"
		fi

		# If SSH keys provided, check file existence
		[[ -n "${CLOUD_INIT_CONFIG["ssh-keys"]}" ]] && require_arg_file "${CLOUD_INIT_CONFIG["ssh-keys"]}" "ssh keys (--ssh-keys)"
	else
		echo "Warning: No cloud-init user provided"
	fi

	[[ -n "${SCRIPT_FILE}" ]] && require_arg_file "${SCRIPT_FILE}" "script (--script)"

	[[ -n "${NETWORK_CONFIG[vlan]}" ]] && require_arg_vlan "${NETWORK_CONFIG[vlan]}" "vlan (--vlan)"
}

validate_storage() {
	# Validate disk storage supports images
	if [[ "${DISK_STORAGE_CONFIG[supports_images]}" != "true" ]]; then
		die "Storage '${DISK_STORAGE_CONFIG[name]}' does not support VM disk images. Supported content: ${DISK_STORAGE_CONFIG[content]}"
	fi

	# Validate disk format is supported by the storage type
	local supported_formats="${DISK_STORAGE_CONFIG[image_formats]}"
	if [[ ! ",${supported_formats}," == *",${DISK_CONFIG[format]},"* ]]; then
		die "Disk format '${DISK_CONFIG[format]}' is not supported by storage '${DISK_STORAGE_CONFIG[name]}' (type: ${DISK_STORAGE_CONFIG[type]}). Supported formats: ${supported_formats}"
	fi

	# Validate snippets storage supports snippets
	if [[ "${SNIPPETS_STORAGE_CONFIG[supports_snippets]}" != "true" ]]; then
		die "Storage '${SNIPPETS_STORAGE_CONFIG[name]}' does not support snippets. Supported content: ${SNIPPETS_STORAGE_CONFIG[content]}"
	fi

	# Verify actual directories are writable (Proxmox-specific)
	local snippets_dir="${SNIPPETS_STORAGE_CONFIG[snippets_dir]}"
	if [[ -n "${snippets_dir}" ]] && [[ ! -w "${snippets_dir}" ]]; then
		die "Snippets directory not writable: ${snippets_dir}"
	fi
}

validate_distro() {
	echo "Detecting distro from image..."

	# Detect the distro using virt-inspector
	DISTRO=$(virt-inspector --no-applications -a "${IMAGE_FILE}" 2>/dev/null | grep '<distro>' | head -1 | sed -E 's/.*<distro>([^<]+)<\/distro>.*/\1/')

	if [[ -z "${DISTRO}" ]]; then
		die "Failed to detect distro from image"
	fi

	DISTRO_FAMILY=$(normalize_distro "${DISTRO}") || die "Unsupported distro '${DISTRO}'. Supported distro families: ${SUPPORTED_DISTROS[*]}"

	echo "Detected distro: ${DISTRO} (family: ${DISTRO_FAMILY})"
}

# ==============================================================================
# MAIN
# ==============================================================================

download_image() {
	local image_dir image_file

	# Store images in a dedicated directory next to this script
	image_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/images"
	mkdir -p "${image_dir}"

	image_file="${image_dir}/$(basename "${URL}")"

	# Download if not already present
	if [[ ! -f "${image_file}" ]]; then
		echo "Downloading image from ${URL}..."
		wget -q --show-progress -O "${image_file}" "${URL}"
	fi

	# Set the full path to the image file
	IMAGE_FILE=$(realpath "${image_file}")
}

install_dependencies() {
	echo "Checking required dependencies..."
	local packages=()
	if ! command -v yq &>/dev/null; then
		packages+=("yq")
	fi
	if ! command -v wget &>/dev/null; then
		packages+=("wget")
	fi
	if ! command -v qemu-img &>/dev/null; then
		packages+=("qemu-utils")
	fi
	if ! command -v virt-inspector &>/dev/null; then
		packages+=("libguestfs-tools")
	fi

	if [[ "${#packages[@]}" -gt 0 ]]; then
		echo "Installing missing dependencies: ${packages[*]}..."
		quiet_run apt update
		quiet_run apt install -y "${packages[@]}" || die "Failed to install dependencies: ${packages[*]}"
	fi
}

resolve_merged_args() {

	# Extract --config from the argument list and build a merged argument set.
	# Config values act as defaults; any CLI flag supplied after --config overrides them.
	local config_file=""
	local -a cli_flags=()
	local skip_next=0
	local arg

	for arg in "$@"; do
		if [[ "${skip_next}" == "1" ]]; then
			config_file="${arg}"
			skip_next=0
			continue
		fi
		if [[ "${arg}" == "--config" ]]; then
			skip_next=1
			continue
		fi
		cli_flags+=("${arg}")
	done

	[[ "${skip_next}" == "1" ]] && die "Option --config requires a value"

	if [[ -n "${config_file}" ]]; then
		# If the value is not an existing file, treat it as a template name and
		# look for <script-dir>/templates/<name>.yaml or .yml
		if [[ ! -f "${config_file}" ]]; then
			local script_dir templates_dir resolved=""
			script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
			templates_dir="${script_dir}/templates"
			if [[ -f "${templates_dir}/${config_file}.yaml" ]]; then
				resolved="${templates_dir}/${config_file}.yaml"
			elif [[ -f "${templates_dir}/${config_file}.yml" ]]; then
				resolved="${templates_dir}/${config_file}.yml"
			else
				die "Config '${config_file}' not found as a file or as a template in ${templates_dir}"
			fi
			config_file="${resolved}"
		fi

		local -a config_args=()
		build_args_from_config "${config_file}" config_args

		# Merge config defaults first, then CLI overrides.
		MERGED_ARGS=("${config_args[@]+"${config_args[@]}"}" "${cli_flags[@]+"${cli_flags[@]}"}")
	else
		MERGED_ARGS=("${cli_flags[@]+"${cli_flags[@]}"}")
	fi
}

main() {
	case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	-V | --version)
		print_version
		exit 0
		;;
	esac

	echo "--- Proxmox VE Template Creation Script ---"

	# Install dependencies
	install_dependencies

	# Load externally defined patch functions
	load_patches

	resolve_merged_args "$@"

	# Parse and populate variables from command-line arguments
	parse_arguments "${MERGED_ARGS[@]}"

	# Validate arguments
	validate_args

	# Validate storage
	validate_storage

	# Download the image
	download_image

	# Detect distro from image
	validate_distro

	# Create the template
	create_template

	echo "--- Proxmox VE Template Creation Script ---"
}

# Run the main function with all script arguments
main "$@"
