#!/usr/bin/env bash

set -euo pipefail

STARTED_SSH_AGENT=0
FORCE_FRESH_INSTALL=0
DELETE_WITH_DESTROY=0
VERBOSE=0

TF_PLAN="tfplan"
INVENTORY_DIR="inventory"
PLAYBOOK="site.yml"

usage() {
	echo "Usage: $0 <stack-name> <command> [-f] [-d] [-v]"
	echo
	echo "Commands:"
	echo "  create   			Create stacks/<stack-name> scaffold"
	echo "  deploy   			Provision and configure stack"
	echo "  destroy  			Destroy stack infrastructure"
	echo "  delete   			Delete stack directory"
	echo
	echo "Options:"
	echo "  -f   			Force clean reinstall of Terraform/Ansible dependencies"
	echo "  -d   			(delete only) Destroy stack before delete"
	echo "  -v   			Show full Terraform/Ansible output"
	echo "       			(for delete, -f only applies when -d is also set)"
}

die() {
	echo "$1" >&2
	exit 1
}

setup_ssh_agent() {
	if [[ -z "${ssh_master_key_private:-}" ]]; then
		return
	fi

	if [[ -z "${SSH_AUTH_SOCK:-}" ]] || ! ssh-add -l >/dev/null 2>&1; then
		eval "$(ssh-agent -s)" >/dev/null
		STARTED_SSH_AGENT=1
		trap 'if [[ "${STARTED_SSH_AGENT}" == "1" ]] && [[ -n "${SSH_AGENT_PID:-}" ]]; then ssh-agent -k >/dev/null; fi' EXIT
	fi

	if ! ssh-add -l >/dev/null 2>&1; then
		printf '%s\n' "${ssh_master_key_private}" | ssh-add - >/dev/null
	fi
}

install_terraform() {
	if ! command -v terraform &>/dev/null; then
		echo "Terraform not found. Installing Terraform..."
		if [[ "$OSTYPE" == "linux-gnu"* ]]; then
			# Linux installation
			sudo apt-get update && sudo apt-get install -y gnupg software-properties-common gpg
			wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
			gpg --no-default-keyring --keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg --fingerprint
			echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
			sudo apt update && sudo apt install terraform
		else
			die "Unsupported OS type: $OSTYPE. Please install Terraform manually."
		fi
	fi
}

install_ansible() {
	local repo_root="$1"
	local force_fresh="$2"
	local ve

	ve=${VIRTUAL_ENV:-}

	if [[ -z "${ve}" ]]; then
		if [[ -d "${repo_root}/venv" ]]; then
			echo "Activating existing python virtual environment..."
			# shellcheck disable=SC1091
			source "${repo_root}/venv/bin/activate"
		else
			echo "No python virtual environment detected. Creating a new virtual environment..."
			python3 -m venv "${repo_root}/venv"
			# shellcheck disable=SC1091
			source "${repo_root}/venv/bin/activate"
		fi
	fi

	echo "==> [PIP] Installing python dependencies from requirements.txt..."
	if [[ "${force_fresh}" == "1" ]]; then
		run_cmd pip3 install --upgrade --force-reinstall -r "${repo_root}/requirements.txt"
	else
		run_cmd pip3 install -r "${repo_root}/requirements.txt"
	fi
}

load_env() {
	local env_file="$1"
	local -a env_keys=()
	local var

	while IFS= read -r var; do
		env_keys+=("${var}")
	done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${env_file}" | sed -E 's/=.*$//')

	set -a
	# shellcheck disable=SC1090
	source "${env_file}"
	set +a

	for var in "${env_keys[@]}"; do
		if [[ "${var}" == TF_VAR_* ]]; then
			continue
		fi

		export "TF_VAR_${var}=${!var-}"
	done
}

load_stack_envs() {
	local repo_root="$1"
	local stack_dir="$2"
	local global_env stack_env

	global_env="${repo_root}/.env"
	stack_env="${stack_dir}/.env"

	# Load global defaults first, then allow component-level overrides.
	if [[ -f "${global_env}" ]]; then
		load_env "${global_env}"
	fi

	if [[ -f "${stack_env}" ]]; then
		load_env "${stack_env}"
	fi
}

run_cmd() {
	local tmp_out rc

	if [[ "${VERBOSE}" == "1" ]]; then
		"$@"
		return
	fi

	tmp_out="$(mktemp)"

	if "$@" >"${tmp_out}" 2>&1; then
		rm -f "${tmp_out}"
	else
		rc=$?
		cat "${tmp_out}" >&2
		rm -f "${tmp_out}"
		return "${rc}"
	fi
}

run_terraform_deploy() {
	local force_fresh="$1"
	local -a init_args=("-input=false")

	if [[ "${force_fresh}" == "1" ]]; then
		init_args+=("-upgrade")
	fi

	echo "==> [Terraform] Initializing providers and module dependencies..."
	run_cmd terraform init "${init_args[@]}"

	echo "==> [Terraform] Validating stack configuration..."
	run_cmd terraform validate

	echo "==> [Terraform] Building execution plan..."
	run_cmd terraform plan -input=false -out="${TF_PLAN}"

	echo "==> [Terraform] Applying planned infrastructure changes..."
	run_cmd terraform apply "${TF_PLAN}"
}

run_ansible_configure() {
	local repo_root="$1"
	local force_fresh="$2"
	local -a collection_args=("-r" "${repo_root}/requirements.yml")

	if [[ "${force_fresh}" == "1" ]]; then
		collection_args+=("--force")
	fi

	echo "==> [Ansible] Installing required collections..."
	run_cmd ansible-galaxy collection install "${collection_args[@]}"

	echo "==> [Ansible] Running playbook lint checks..."
	run_cmd ansible-lint "${PLAYBOOK}"

	echo "==> [Ansible] Executing stack playbook..."
	run_cmd ansible-playbook -i "${INVENTORY_DIR}" "${PLAYBOOK}"
}

run_terraform_destroy() {
	local force_fresh="$1"
	local -a init_args=("-input=false")

	if [[ "${force_fresh}" == "1" ]]; then
		init_args+=("-upgrade")
	fi

	echo "==> [Terraform] Initializing providers and module dependencies..."
	run_cmd terraform init "${init_args[@]}"

	echo "==> [Terraform] Destroying stack infrastructure..."
	run_cmd terraform destroy -input=false -auto-approve
}

resolve_stack_dir() {
	local name="$1"
	local repo_root

	repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	echo "${repo_root}/stacks/${name}"
}

cleanup_stack_temp_files() {
	local stack_dir="$1"

	echo "==> Fresh cleanup"
	rm -rf \
		"${stack_dir}/.terraform" \
		"${stack_dir}/.ansible"

	rm -f \
		"${stack_dir}/${TF_PLAN}" \
		"${stack_dir}/.terraform.lock.hcl"
}

create_file() {
	local target="$1"
	local content="${2:-}"

	if [[ -e "${target}" ]]; then
		return
	fi

	if [[ -n "${content}" ]]; then
		printf '%s\n' "${content}" >"${target}"
	else
		: >"${target}"
	fi
}

validate_stack_name() {
	local name="$1"

	if [[ -z "${name}" ]]; then
		die "Stack name cannot be empty."
	fi

	if [[ ! "${name}" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ "${name}" == .* ]] || [[ "${name}" == *..* ]]; then
		die "Invalid stack name '${name}'. Use letters, numbers, '.', '_' or '-' only."
	fi
}

create_stack() {
	local name="$1"
	local repo_root ansible_root terraform_root stack_dir shared_playbook

	validate_stack_name "${name}"

	repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	ansible_root="${repo_root}/shared/ansible"
	terraform_root="${repo_root}/shared/terraform"
	stack_dir="${repo_root}/stacks/${name}"
	shared_playbook="${ansible_root}/site.yml"

	[[ -d "${ansible_root}" ]] || die "Missing directory: ${ansible_root}"
	[[ -d "${terraform_root}" ]] || die "Missing directory: ${terraform_root}"
	[[ -f "${ansible_root}/ansible.cfg" ]] || die "Missing file: ${ansible_root}/ansible.cfg"
	[[ -f "${shared_playbook}" ]] || die "Missing file: ${shared_playbook}"

	mkdir -p "${stack_dir}"

	# Link shared directories and Terraform files from repo root.
	ln -sfn "../../shared/ansible/inventory" "${stack_dir}/inventory"
	ln -sfn "../../shared/ansible/roles" "${stack_dir}/roles"
	ln -sfn "../../shared/ansible/ansible.cfg" "${stack_dir}/ansible.cfg"
	ln -sfn "../../shared/terraform/modules" "${stack_dir}/modules"
	ln -sfn "../../shared/terraform/versions.tf" "${stack_dir}/common.versions.tf"
	ln -sfn "../../shared/terraform/providers.tf" "${stack_dir}/common.providers.tf"
	ln -sfn "../../shared/terraform/locals.tf" "${stack_dir}/common.locals.tf"
	ln -sfn "../../shared/terraform/variables.tf" "${stack_dir}/common.variables.tf"

	create_file "${stack_dir}/main.tf"
	#create_file "${stack_dir}/outputs.tf"
	#create_file "${stack_dir}/variables.tf"
	#create_file "${stack_dir}/locals.tf"
	#create_file "${stack_dir}/versions.tf"
	#create_file "${stack_dir}/providers.tf"

	create_file "${stack_dir}/site.yml" "$(<"${shared_playbook}")"
	create_file "${stack_dir}/.env"

	echo "Created stack ${name} at ${stack_dir}"
}

deploy_stack() {
	local name="$1"
	local repo_root stack_dir

	validate_stack_name "${name}"
	repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	stack_dir="$(resolve_stack_dir "${name}")"

	[[ -d "${stack_dir}" ]] || die "Missing stack directory: ${stack_dir}"
	[[ -f "${repo_root}/requirements.txt" ]] || die "Missing file: ${repo_root}/requirements.txt"
	[[ -f "${repo_root}/requirements.yml" ]] || die "Missing file: ${repo_root}/requirements.yml"

	if [[ "${FORCE_FRESH_INSTALL}" == "1" ]]; then
		cleanup_stack_temp_files "${stack_dir}"
	fi

	load_stack_envs "${repo_root}" "${stack_dir}"
	setup_ssh_agent
	install_terraform
	install_ansible "${repo_root}" "${FORCE_FRESH_INSTALL}"

	pushd "${stack_dir}" >/dev/null
	run_terraform_deploy "${FORCE_FRESH_INSTALL}"
	run_ansible_configure "${repo_root}" "${FORCE_FRESH_INSTALL}"
	popd >/dev/null
}

destroy_stack() {
	local name="$1"
	local repo_root stack_dir

	validate_stack_name "${name}"
	repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	stack_dir="$(resolve_stack_dir "${name}")"

	[[ -d "${stack_dir}" ]] || die "Missing stack directory: ${stack_dir}"

	if [[ "${FORCE_FRESH_INSTALL}" == "1" ]]; then
		cleanup_stack_temp_files "${stack_dir}"
	fi

	load_stack_envs "${repo_root}" "${stack_dir}"
	setup_ssh_agent
	install_terraform

	pushd "${stack_dir}" >/dev/null
	run_terraform_destroy "${FORCE_FRESH_INSTALL}"
	popd >/dev/null
}

delete_stack() {
	local name="$1"
	local stack_dir

	validate_stack_name "${name}"
	stack_dir="$(resolve_stack_dir "${name}")"

	[[ -d "${stack_dir}" ]] || die "Missing stack directory: ${stack_dir}"

	if [[ "${DELETE_WITH_DESTROY}" == "1" ]]; then
		echo "Destroying stack '${name}' before delete..."
		# For delete flow, -f takes effect only when -d is also set.
		destroy_stack "${name}"
	fi

	rm -rf "${stack_dir}"
	echo "Deleted stack ${name} at ${stack_dir}"
}

parse_command_options() {
	local arg

	for arg in "$@"; do
		case "${arg}" in
		-f)
			FORCE_FRESH_INSTALL=1
			;;
		-v)
			VERBOSE=1
			;;
		-d)
			DELETE_WITH_DESTROY=1
			;;
		*)
			# Ignore unsupported options.
			;;
		esac
	done
}

main() {
	local name="${1:-}"
	local command="${2:-}"
	local action

	if [[ -z "${name}" ]]; then
		usage
		exit 1
	fi

	case "${name}" in
	-h | --help | help)
		usage
		exit 0
		;;
	esac

	[[ -n "${command}" ]] || die "Missing command for stack '${name}'."

	case "${command}" in
	-h | --help | help)
		usage
		return 0
		;;
	create)
		action="create_stack"
		;;
	deploy)
		action="deploy_stack"
		;;
	destroy)
		action="destroy_stack"
		;;
	delete)
		action="delete_stack"
		;;
	*)
		die "Unknown command '${command}'."
		;;
	esac

	parse_command_options "${@:3}"
	"${action}" "${name}"
}

main "$@"
