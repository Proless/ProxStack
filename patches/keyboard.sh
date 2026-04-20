#!/usr/bin/env bash

keyboard() {
	local vendor_data_file="${1}"
	#local image_file="${2}"
	#local distro="${3}"
	local distro_family="${4}"

	[[ -z "${LOCALE_CONFIG[keyboard]}" ]] && return 0

	case "${distro_family}" in
	debian | ubuntu)
		# Replace cloud-init keyboard block with distro-specific setup steps.
		yq -i -y "del(.keyboard)" "${vendor_data_file}"
		yq -i -y ".packages += [\"keyboard-configuration\"]" "${vendor_data_file}"
		yq -i -y ".packages += [\"console-setup\"]" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"sed -i -E \\\"s/^XKBMODEL.*/XKBMODEL=\\\"pc105\\\"/\\\" /etc/default/keyboard\"]" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"sed -i -E \\\"s/^XKBLAYOUT.*/XKBLAYOUT=\\\"${LOCALE_CONFIG[keyboard]}\\\"/\\\" /etc/default/keyboard\"]" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"sed -i -E \\\"s/^XKBVARIANT.*/XKBVARIANT=\\\"${LOCALE_CONFIG[keyboard_variant]}\\\"/\\\" /etc/default/keyboard\"]" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"dpkg-reconfigure -f noninteractive keyboard-configuration\"]" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"setupcon\"]" "${vendor_data_file}"
		;;
	fedora | rhel)
		# Replace cloud-init keyboard block with localectl for RPM-based systems.
		yq -i -y "del(.keyboard)" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"localectl set-keymap ${LOCALE_CONFIG[keyboard]}\"]" "${vendor_data_file}"
		;;
	esac
}
