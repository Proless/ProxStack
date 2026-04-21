#!/usr/bin/env bash

locale() {
	local vendor_data_file="${1}"
	#local image_file="${2}"
	#local distro="${3}"
	local distro_family="${4}"

	[[ -z "${LOCALIZATION_CONFIG[locale]}" ]] && return 0

	case "${distro_family}" in
	debian)
		# Replace cloud-init locale key with explicit locale-gen workflow.
		yq -i -y "del(.locale)" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"sed -i \\\"s/^# *\\\\(${LOCALIZATION_CONFIG[locale]}\\\\)/\\\\1/\\\" /etc/locale.gen\"]" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"grep -q \\\"^${LOCALIZATION_CONFIG[locale]}\\\" /etc/locale.gen || echo \\\"${LOCALIZATION_CONFIG[locale]}\\\" >> /etc/locale.gen\"]" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"locale-gen\"]" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"update-locale LANG=\\\"${LOCALIZATION_CONFIG[locale]}\\\"\"]" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"export LANG=\\\"${LOCALIZATION_CONFIG[locale]}\\\"\"]" "${vendor_data_file}"
		;;
	fedora | rhel)
		# Replace cloud-init locale key with localectl for RPM-based systems.
		yq -i -y "del(.locale)" "${vendor_data_file}"
		yq -i -y ".runcmd += [\"localectl set-locale LANG=${LOCALIZATION_CONFIG[locale]}\"]" "${vendor_data_file}"
		;;
	esac
}
