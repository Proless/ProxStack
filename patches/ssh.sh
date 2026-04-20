#!/usr/bin/env bash

get_ssh_service_name() {
	local distro_family="${1}"

	case "${distro_family}" in
	debian | ubuntu)
		echo "ssh"
		;;
	fedora | rhel)
		echo "sshd"
		;;
	*)
		echo "ssh"
		;;
	esac
}

ssh() {
	local vendor_data_file="${1}"
	local image_file="${2}"
	local distro="${3}"
	local distro_family="${4}"

	# Enable SSH service on the target image.
	enable_ssh "${vendor_data_file}" "${image_file}" "${distro}" "${distro_family}"
}

ssh_pwauth() {
	local vendor_data_file="${1}"
	local image_file="${2}"
	local distro="${3}"
	local distro_family="${4}"
	local ssh_service
	local ssh_dropin_file="/etc/ssh/sshd_config.d/00-proxstack-pwauth.conf"

	ssh_service="$(get_ssh_service_name "${distro_family}")"

	# Signal cloud-init that password authentication should be enabled.
	yq -i -y ".ssh_pwauth = true" "${vendor_data_file}"

	# Configure SSH daemon auth in a high-priority drop-in to avoid cloud-init override conflicts.
	yq -i -y ".runcmd += [\"install -d -m 0755 /etc/ssh/sshd_config.d\"]" "${vendor_data_file}"
	yq -i -y ".runcmd += [\"find /etc/ssh/sshd_config.d -maxdepth 1 -type f -name '*.conf' ! -name '00-proxstack-pwauth.conf' -exec sed -ri '/^\\s*#?\\s*(PasswordAuthentication|PermitRootLogin)\\s+/d' {} +\"]" "${vendor_data_file}"
	yq -i -y ".runcmd += [\"printf 'PasswordAuthentication yes\\n' > ${ssh_dropin_file}\"]" "${vendor_data_file}"

	# Only allow root password login when the cloud-init user is root.
	if [[ "${CI_CONFIG[user]}" == "root" ]]; then
		yq -i -y ".runcmd += [\"printf 'PermitRootLogin yes\\n' >> ${ssh_dropin_file}\"]" "${vendor_data_file}"
	fi

	# Apply changed SSH daemon settings.
	yq -i -y ".runcmd += [\"systemctl restart ${ssh_service}\"]" "${vendor_data_file}"
}

enable_ssh() {
	local vendor_data_file="${1}"
	#local image_file="${2}"
	#local distro="${3}"
	local distro_family="${4}"

	local ssh_service
	ssh_service="$(get_ssh_service_name "${distro_family}")"

	# Ensure SSH service is enabled and started.
	yq -i -y ".runcmd += [\"systemctl enable ${ssh_service}\"]" "${vendor_data_file}"
	yq -i -y ".runcmd += [\"systemctl start ${ssh_service}\"]" "${vendor_data_file}"
}
