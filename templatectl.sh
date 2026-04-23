#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
#
# templatectl.sh - Creates Proxmox VE templates from cloud-init images.
# Repository: https://git.mukhtabar.de/proxmox/proxstack
# Maintainers: Proless

set -euo pipefail

# ==============================================================================
# GLOBAL VARIABLES & CONFIGURATION
# ==============================================================================

# Supported distro families. RHEL-compatible distros are normalized to "rhel".
declare -a SUPPORTED_DISTROS=("debian" "ubuntu" "fedora" "rhel")

# Storage configuration
declare -A DISK_STORAGE_CONFIG=()
declare -A SNIPPETS_STORAGE_CONFIG=()

# Keyboard configuration
declare -A KEYBOARD_CONFIG=(
	[layout]=""  # Keyboard layout
	[variant]="" # Keyboard variant
)

# Disk configuration
declare -A DISK_CONFIG=(
	[size]=""                     # Disk size for the VM (e.g., 32G)
	[bus]="scsi"                  # Disk bus/controller type: scsi (default), virtio, sata, ide
	[format]="qcow2"              # Disk format: qcow2 (default), raw, or vmdk
	[flags]="discard=on"          # Default disk flags
	[scsihw]="virtio-scsi-single" # SCSI controller model (default: virtio-scsi-single)
	[storage]="local-lvm"         # The Proxmox storage where the VM disk will be allocated (default: local-lvm)
)

# Network configuration
declare -A NET_CONFIG=(
	[bridge]="vmbr0" # The Proxmox network bridge for the VM (default: vmbr0)
	[vlan]=""        # Optional VLAN tag for net0 (1-4094)
)

# SSH configuration
declare -A SSH_CONFIG=(
	[keys]=""    # Path to file with public SSH keys
	[pwauth]="0" # Enable SSH password authentication
)

# DNS configuration
declare -A DNS_CONFIG=(
	[servers]="" # DNS servers
	[domains]="" # Domain search domains
)

# Snippets configuration
declare -A SNIPPETS_CONFIG=(
	[storage]="" # Storage where snippets are stored (default: same as DISK_CONFIG[storage])
)

declare -a MERGED_ARGS=() # Final merged arguments built from config defaults + CLI overrides

# Settings
ID=""               # ID for the template
URL=""              # Cloud Image URL
NAME=""             # Name for the template
DISTRO=""           # Raw distro detected from the image
IMAGE_FILE=""       # Local path to the downloaded image file
DISTRO_FAMILY=""    # Normalized distro family used for feature selection
USER=""             # Cloud-init user
PASSWORD=""         # Cloud-init password
UPGRADE="0"         # Cloud-init package upgrade behavior: 1=enable, 0=disable
MEMORY="2048"       # Memory in MB
CORES="4"           # Number of CPU cores
CPU="x86-64-v2-AES" # CPU type
DISPLAY="std"       # Display type
TIMEZONE=""         # Timezone
LOCALE=""           # Locale

# Advanced options
PACKAGES=""                   # Space-separated list of packages to install inside the VM template
PATCHES="ssh keyboard locale" # Space-separated list of patches to apply
SCRIPT=""                     # Local script file to write via cloud-init and run as final runcmd step
REBOOT="false"                # Reboot VM after cloud-init completes
ONBOOT="0"                    # Start VM automatically on Proxmox host boot

# Internal variables
VENDOR_ONLY="false"  # Write vendor-data file and exit before VM creation
VERBOSE_MODE="false" # Enable verbose mode for debugging

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
	if [[ -n "${PACKAGES}" ]]; then
		IFS=' ' read -ra pkg_array <<<"${PACKAGES}"
		for pkg in "${pkg_array[@]}"; do
			yq -i -y ".packages += [\"${pkg}\"]" "${vendor_data_file}"
		done
	fi
}

ci_add_localization() {
	local vendor_data_file="${1}"

	# Add locale configuration
	[[ -n "${LOCALE}" ]] && yq -i -y ".locale = \"${LOCALE}\"" "${vendor_data_file}"

	# Add timezone configuration
	[[ -n "${TIMEZONE}" ]] && yq -i -y ".timezone = \"${TIMEZONE}\"" "${vendor_data_file}"

	# Add keyboard configuration
	if [[ -n "${KEYBOARD_CONFIG[layout]}" ]]; then
		yq -i -y ".keyboard.layout = \"${KEYBOARD_CONFIG[layout]}\"" "${vendor_data_file}"
		[[ -n "${KEYBOARD_CONFIG[variant]}" ]] && yq -i -y ".keyboard.variant = \"${KEYBOARD_CONFIG[variant]}\"" "${vendor_data_file}"
	fi
}

ci_add_script() {
	local vendor_data_file="${1}"

	[[ -z "${SCRIPT}" ]] && return 0

	local script_path="/usr/local/sbin/ci_script.sh"
	local script_b64

	script_b64=$(base64 -w 0 "${SCRIPT}")

	SCRIPT_B64="${script_b64}" yq -i -y '.write_files += [{"path":"/usr/local/sbin/ci_script.sh","owner":"root:root","permissions":"0755","encoding":"b64","content": env.SCRIPT_B64}]' "${vendor_data_file}"
	yq -i -y ".runcmd += [\"${script_path}\"]" "${vendor_data_file}"
}

ci_add_reboot() {
	local vendor_data_file="${1}"

	[[ "${REBOOT}" != "true" ]] && return 0

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
	local net0_config="virtio,macaddr=00:00:00:00:00:00,bridge=${NET_CONFIG[bridge]}"

	[[ -n "${NET_CONFIG[vlan]}" ]] && net0_config+=",tag=${NET_CONFIG[vlan]}"

	echo "Creating VM ${ID}..."
	quiet_run qm create "${ID}" --name "${NAME}" \
		--memory "${MEMORY}" \
		--cpu "${CPU}" \
		--cores "${CORES}" \
		--net0 "${net0_config}" \
		--agent enabled=1 \
		--ostype l26 \
		--vga "${DISPLAY}" \
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
	local disk_device
	local cloudinit_device="ide0"

	case "${DISK_CONFIG[bus]}" in
	scsi)
		disk_device="scsi0"
		;;
	virtio)
		disk_device="virtio0"
		;;
	sata)
		disk_device="sata0"
		;;
	ide)
		disk_device="ide0"
		cloudinit_device="ide2"
		;;
	*)
		die "Unsupported disk bus '${DISK_CONFIG[bus]}'. Supported values: scsi, virtio, sata, ide"
		;;
	esac

	local qm_cmd=(qm set "${ID}"
		--ciupgrade "${UPGRADE}"
		--cicustom "vendor=${SNIPPETS_STORAGE_CONFIG[name]}:snippets/ci-vendor-data-${ID}.yml"
		--ipconfig0 "ip=dhcp"
		--onboot "${ONBOOT}"
	)

	# scsihw only applies to scsi bus.
	[[ "${DISK_CONFIG[bus]}" == "scsi" ]] && qm_cmd+=(--scsihw "${DISK_CONFIG[scsihw]}")

	qm_cmd+=("--${disk_device}" "${disk_path},${DISK_CONFIG[flags]// /,}")
	qm_cmd+=("--${cloudinit_device}" "${DISK_STORAGE_CONFIG[name]}:cloudinit")
	qm_cmd+=(--boot "order=${disk_device}")

	# Add DNS servers if specified
	[[ -n "${DNS_CONFIG[servers]}" ]] && qm_cmd+=(--nameserver "${DNS_CONFIG[servers]}")

	# Add search domain if specified
	[[ -n "${DNS_CONFIG[domains]}" ]] && qm_cmd+=(--searchdomain "${DNS_CONFIG[domains]}")

	# Add cloud-init user settings if user is specified
	if [[ -n "${USER}" ]]; then
		qm_cmd+=(--ciuser "${USER}")
		[[ -n "${PASSWORD}" ]] && qm_cmd+=(--cipassword "${PASSWORD}")
		[[ -n "${SSH_CONFIG[keys]}" ]] && qm_cmd+=(--sshkeys "${SSH_CONFIG[keys]}")
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

	if [[ "${VENDOR_ONLY}" == "true" ]]; then
		rm -f "${tmp_yaml}" "${image_copy}"
		realpath "${vendor_data_file}"
		return 0
	fi

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

require_arg_disk_bus() {
	case "${1}" in
	scsi | virtio | sata | ide)
		return 0
		;;
	*)
		die "Argument '${2}' must be one of: scsi, virtio, sata, ide (got '${1}')"
		;;
	esac
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
			USER="${2}"
			shift 2
			;;
		--password)
			PASSWORD="${2}"
			shift 2
			;;
		--upgrade)
			UPGRADE="1"
			shift
			;;
		--memory)
			MEMORY="${2}"
			shift 2
			;;
		--cores)
			CORES="${2}"
			shift 2
			;;
		--cpu)
			CPU="${2}"
			shift 2
			;;
		--disk-scsihw)
			DISK_CONFIG[scsihw]="${2}"
			shift 2
			;;
		--net-bridge)
			NET_CONFIG[bridge]="${2}"
			shift 2
			;;
		--net-vlan)
			NET_CONFIG[vlan]="${2}"
			shift 2
			;;
		--disk-size)
			DISK_CONFIG[size]="${2}"
			shift 2
			;;
		--disk-bus)
			DISK_CONFIG[bus]="${2}"
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
			DISPLAY="${2}"
			shift 2
			;;
		--timezone)
			TIMEZONE="${2}"
			shift 2
			;;
		--keyboard-layout)
			KEYBOARD_CONFIG[layout]="${2}"
			shift 2
			;;
		--keyboard-variant)
			KEYBOARD_CONFIG[variant]="${2}"
			shift 2
			;;
		--locale)
			LOCALE="${2}"
			shift 2
			;;
		--ssh-keys)
			SSH_CONFIG[keys]="${2}"
			shift 2
			;;
		--ssh-pwauth)
			SSH_CONFIG[pwauth]="1"
			PATCHES+=" ssh_pwauth"
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
			PACKAGES="${2}"
			shift 2
			;;
		--patches)
			PATCHES+=" ${2}"
			shift 2
			;;
		--script)
			SCRIPT="${2}"
			shift 2
			;;
		--reboot)
			REBOOT="true"
			shift
			;;
		--onboot)
			ONBOOT="1"
			shift
			;;
		--vendor-only)
			VENDOR_ONLY="true"
			shift
			;;
		-v | --verbose)
			VERBOSE_MODE="true"
			shift
			;;
		-h | --help)
			usage
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
	if [[ "${VENDOR_ONLY}" != "true" ]] && qm status "${ID}" &>/dev/null; then
		die "ID ${ID} already exists. Please choose a different ID."
	fi

	require_arg_string "${URL}" "url (--url)"
	require_arg_string "${NAME}" "name (--name)"

	require_arg_string "${DISK_CONFIG[storage]}" "disk storage (--disk-storage)"
	require_arg_string "${DISK_CONFIG[format]}" "disk format (--disk-format)"
	require_arg_string "${NET_CONFIG[bridge]}" "network bridge (--net-bridge)"

	require_arg_number "${MEMORY}" "memory (--memory)"
	require_arg_number "${CORES}" "cores (--cores)"

	# Validate optional parameters
	if [[ -n "${USER}" ]]; then
		if [[ -z "${PASSWORD}" && -z "${SSH_CONFIG[keys]}" ]]; then
			die "You must provide at least one of --password or --ssh-keys when --user is specified"
		fi

		# If SSH keys provided, check file existence
		[[ -n "${SSH_CONFIG[keys]}" ]] && require_arg_file "${SSH_CONFIG[keys]}" "ssh keys (--ssh-keys)"
	else
		echo "Warning: No cloud-init user provided"
	fi

	[[ -n "${SCRIPT}" ]] && require_arg_file "${SCRIPT}" "script (--script)"

	[[ -n "${NET_CONFIG[vlan]}" ]] && require_arg_vlan "${NET_CONFIG[vlan]}" "vlan (--net-vlan)"

	[[ -n "${DISK_CONFIG[bus]}" ]] && require_arg_disk_bus "${DISK_CONFIG[bus]}" "disk bus (--disk-bus)"
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
# UTILITY
# ==============================================================================

quiet_run() {
	if [[ "$VERBOSE_MODE" == "true" ]]; then
		"$@"
	else
		"$@" >/dev/null 2>&1 || die "Command failed: $*"
	fi
}

quiet_run_ext() {
	local cmd="$*"
	local fname="__tmp_wrap_${$}_${RANDOM}"

	# Create a dynamic wrapper function that contains the entire command
	eval "
	$fname() {
		set -e
		$cmd
	}
	"

	# Run through quiet_run so quiet/verbose works
	quiet_run "$fname"

	# Clean up
	unset -f "$fname"
}

die() {
	echo "$*" >&2
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
	echo "  --upgrade                      Enable cloud-init package upgrade (default: disabled)"
	echo "  --net-bridge <bridge>          Network bridge for VM (default: vmbr0)"
	echo "  --net-vlan <id>                VLAN tag for VM network interface (1-4094)"
	echo "  --memory <mb>                  Memory in MB (default: 2048)"
	echo "  --cores <num>                  Number of CPU cores (default: 4)"
	echo "  --cpu <type>                   CPU type for VM (default: x86-64-v2-AES)"
	echo "  --disk-scsihw <type>           SCSI controller model for scsi bus (default: virtio-scsi-single)"
	echo "  --timezone <timezone>          Timezone (e.g., America/New_York, Europe/London)"
	echo "  --keyboard-layout <layout>     Keyboard layout (e.g., us, uk, de)"
	echo "  --keyboard-variant <variant>   Keyboard variant (e.g., intl)"
	echo "  --locale <locale>              Locale (e.g., en_US.UTF-8, de_DE.UTF-8)"
	echo "  --ssh-keys <file>              Path to file with public SSH keys (one per line, OpenSSH format)"
	echo "  --ssh-pwauth                   Enable SSH password authentication; if --user root, also allow root password login"
	echo "  --disk-size <size>             Disk size (e.g., 32G, 50G, 6144M)"
	echo "  --disk-bus <type>              Disk bus/controller type: scsi (default), virtio, sata, ide"
	echo "  --disk-storage <storage>       Proxmox storage for VM disk (default: local-lvm)"
	echo "  --disk-format <format>         Disk format: ex. qcow2 (default)"
	echo "  --disk-flags <flags>           Space-separated Disk flags (default: discard=on)"
	echo "  --display <type>               Set the display/vga type (default: std)"
	echo "  --packages <packages>          Space-separated list of packages to install in the template using cloud-init"
	echo "  --dns-servers <servers>        Space-separated DNS servers (e.g., '10.10.10.10 9.9.9.9')"
	echo "  --dns-domains <domains>        Space-separated domain names (e.g., 'example.com internal.local')"
	echo "  --snippets-storage <storage>   Proxmox storage for cloud-init snippets (default: same as --disk-storage)"
	echo "  --patches <patches>            Space-separated list of patch names to apply"
	echo "  --script <file>                Local shell script to run as the last cloud-init runcmd step"
	echo "  --reboot                       Reboot the VM after cloud-init has completed"
	echo "  --onboot                       Start VM automatically when Proxmox host boots (default: disabled)"
	echo "  --vendor-only                  Write the final vendor-data file, print its absolute path, and exit before VM creation"
	echo "  --config <file|name>           YAML config file path, or a template name resolved from templates/<name>.{yaml,yml}; CLI flags override config values"
	echo "  -v,  --verbose                 Enable verbose mode"
	echo "  -h,  --help                    Display this help message"

	echo ""
	echo "Supported distro families: ${SUPPORTED_DISTROS[*]}"
	echo "RHEL-compatible images such as Rocky, CentOS, AlmaLinux, and RHEL are normalized to rhel"
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

	_resolve_config_path() {
		local raw_path="${1}"
		local expanded_path

		case "${raw_path}" in
		"~")
			expanded_path="${HOME}"
			;;
		\~/*)
			expanded_path="${HOME}/${raw_path:2}"
			;;
		/*)
			expanded_path="${raw_path}"
			;;
		*)
			expanded_path="${PWD}/${raw_path}"
			;;
		esac

		realpath -m "${expanded_path}"
	}

	# Helper: read a yq path and append CLI argument based on type (string, bool, or list)
	_cfg_read() {
		local yq_path="${1}" flag="${2}" type="${3}" output exit_code read_type read_value resolved_value
		echo "Reading config key '${yq_path}' for flag '${flag}'..."

		# Helper to safely execute yq and capture exit code
		_safe_yq() {
			local yq_expr="${1}"
			set +e
			output=$(yq -r "${yq_expr}" "${config_file}" 2>&1)
			exit_code=$?
			set -e
		}

		# Read key once: emit either __MISSING__ or "<type>\t<value>".
		# For arrays, value is space-joined to match CLI list argument format.
		_safe_yq "if (${yq_path} | type) == \"null\" then \"__MISSING__\" else ((${yq_path} | type) + \"\\t\" + (if (${yq_path} | type) == \"array\" then (${yq_path} | join(\" \") ) elif (${yq_path} | type) == \"boolean\" then (if ${yq_path} then \"true\" else \"false\" end) else (${yq_path} | tostring) end)) end"
		if [[ ${exit_code} -ne 0 ]]; then
			die "Failed to parse config at '${yq_path}': $output"
		fi

		if [[ "${output}" == "__MISSING__" ]]; then
			echo "  Key '${yq_path}' not found, skipping"
			return 0
		fi

		# Split "type<TAB>value".
		read_type="${output%%$'\t'*}"
		if [[ "${output}" == *$'\t'* ]]; then
			read_value="${output#*$'\t'}"
		else
			read_value=""
		fi

		# Skip if value is empty.
		if [[ -z "${read_value}" ]]; then
			echo "  Key '${yq_path}' has empty value, skipping"
			return 0
		fi

		case "${type}" in
		string)
			if [[ "${read_type}" != "string" ]]; then
				die "Invalid config key '${yq_path}': expected string but got '${read_type}'"
			fi
			echo "  Setting ${flag}=${read_value}"
			_out_args+=("${flag}" "${read_value}")
			;;
		path)
			if [[ "${read_type}" != "string" ]]; then
				die "Invalid config key '${yq_path}': expected string path but got '${read_type}'"
			fi
			resolved_value="$(_resolve_config_path "${read_value}")"
			echo "  Setting ${flag}=${resolved_value}"
			_out_args+=("${flag}" "${resolved_value}")
			;;
		number)
			if [[ "${read_type}" != "number" ]]; then
				die "Invalid config key '${yq_path}': expected number but got '${read_type}'"
			fi
			echo "  Setting ${flag}=${read_value}"
			_out_args+=("${flag}" "${read_value}")
			;;
		bool)
			if [[ "${read_type}" != "boolean" ]]; then
				die "Invalid config key '${yq_path}': expected boolean (true/false) but got '${read_type}'"
			fi
			if [[ "${read_value}" == "true" ]]; then
				echo "  Setting ${flag}"
				_out_args+=("${flag}")
			elif [[ "${read_value}" == "false" ]]; then
				echo "  Key '${yq_path}' is false, skipping"
			else
				die "Invalid config key '${yq_path}': expected boolean value true/false but got '${read_value}'"
			fi
			;;
		list)
			if [[ "${read_type}" != "array" ]]; then
				die "Invalid config key '${yq_path}': expected YAML list (array) but got '${read_type}'"
			fi
			echo "  Setting ${flag}=${read_value}"
			_out_args+=("${flag}" "${read_value}")
			;;
		esac
	}

	# Required options:
	_cfg_read '.url' "--url" string
	_cfg_read '.id' "--id" number
	_cfg_read '.name' "--name" string

	# top-level VM hardware:
	_cfg_read '.memory' "--memory" number
	_cfg_read '.cores' "--cores" number
	_cfg_read '.cpu' "--cpu" string
	_cfg_read '.display' "--display" string

	# disk:
	_cfg_read '.disk.storage' "--disk-storage" string
	_cfg_read '.disk.size' "--disk-size" string
	_cfg_read '.disk.bus' "--disk-bus" string
	_cfg_read '.disk.format' "--disk-format" string
	_cfg_read '.disk.scsihw' "--disk-scsihw" string
	_cfg_read '.disk.flags' "--disk-flags" list

	# snippets:
	_cfg_read '.snippets.storage' "--snippets-storage" string

	# cloud-init:
	_cfg_read '.user' "--user" string
	_cfg_read '.password' "--password" string
	_cfg_read '.upgrade' "--upgrade" bool
	_cfg_read '.script' "--script" path
	_cfg_read '.reboot' "--reboot" bool
	_cfg_read '.onboot' "--onboot" bool

	# packages:
	_cfg_read '.packages' "--packages" list

	# localization-related keys:
	_cfg_read '.timezone' "--timezone" string
	_cfg_read '.keyboard.layout' "--keyboard-layout" string
	_cfg_read '.keyboard.variant' "--keyboard-variant" string
	_cfg_read '.locale' "--locale" string

	# network:
	_cfg_read '.net.bridge' "--net-bridge" string
	_cfg_read '.net.vlan' "--net-vlan" number

	# dns:
	_cfg_read '.dns.servers' "--dns-servers" list
	_cfg_read '.dns.domains' "--dns-domains" list

	# ssh:
	_cfg_read '.ssh.pwauth' "--ssh-pwauth" bool
	_cfg_read '.ssh.keys' "--ssh-keys" path

	# Top-level misc:
	_cfg_read '.patches' "--patches" list
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

	IFS=' ' read -ra patches_array <<<"${PATCHES}"
	for patch in "${patches_array[@]}"; do
		if declare -f "${patch}" >/dev/null; then
			echo "Applying patch ${patch}..."
			quiet_run "${patch}" "${vendor_data_file}" "${image_file}" "${DISTRO}" "${DISTRO_FAMILY}"
		else
			echo "Warning: Unknown patch '${patch}' specified. Skipping."
		fi
	done
}

download_image() {
	local image_dir image_file

	# Store images in a dedicated directory next to this script
	image_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/images"
	mkdir -p "${image_dir}"

	image_file="${image_dir}/$(basename "${URL}")"

	# Download if not already present
	if [[ ! -f "${image_file}" ]]; then
		echo "Downloading image from ${URL}..."
		quiet_run wget -q --show-progress -O "${image_file}" "${URL}"
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
		quiet_run build_args_from_config "${config_file}" config_args

		# Merge config defaults first, then CLI overrides.
		MERGED_ARGS=("${config_args[@]+"${config_args[@]}"}" "${cli_flags[@]+"${cli_flags[@]}"}")
	else
		MERGED_ARGS=("${cli_flags[@]+"${cli_flags[@]}"}")
	fi
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
	# Bootstrap flags that must take effect before config merging.
	local arg
	for arg in "$@"; do
		case "${arg}" in
		-h | --help)
			usage
			exit 0
			;;
		-v | --verbose)
			VERBOSE_MODE="true"
			;;
		esac
	done

	echo ""
	echo "--- Proxmox VE Template Creation Script ---"

	resolve_merged_args "$@"

	# Parse and populate variables from command-line arguments
	parse_arguments "${MERGED_ARGS[@]}"

	# Install dependencies
	install_dependencies

	# Load externally defined patch functions
	load_patches

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
	echo ""
}

# Run the main function with all script arguments
main "$@"
