#!/usr/bin/env bash
source functions.sh
set -e

# Fallback for environments where $USER isn't set
if [[ -z ${USER:-} ]]; then
	USER="$(id -un)"
	export USER
fi

init_logging "$0"

# Offline mode setup

OFFLINE=0
OFFLINE_BUNDLE_DIR="${OFFLINE_BUNDLE_DIR:-./offline_bundle}"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--offline)
			OFFLINE=1
			shift
			;;
		--bundle)
			OFFLINE_BUNDLE_DIR="$2"
			shift 2
			;;
		*)
			ARGS+=("$1")
			shift
			;;
	esac
done
set -- "${ARGS[@]:-}"

export OFFLINE OFFLINE_BUNDLE_DIR

# —————————————————————————————————————————————————————————————
# Script Start
# —————————————————————————————————————————————————————————————
echo "IriusRisk One-Click Bootstrap Deployment"
echo "---------------------------------------"

# —————————————————————————————————————————————————————————————
# 0. Ensure we're in the scripts dir
# —————————————————————————————————————————————————————————————
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_PATH/.." && pwd)"
cd "$SCRIPT_PATH"

echo "Current directory: $(pwd)"
echo

# —————————————————————————————————————————————————————————————
# 1. Pick your container engine
# —————————————————————————————————————————————————————————————
prompt_engine

# —————————————————————————————————————————————————————————————
# 2. Run preflight and capture output
# —————————————————————————————————————————————————————————————
bash "$SCRIPT_PATH/preflight.sh" >preflight_output.txt 2>&1 || true
PRE_ERRS=$(grep 'ERROR:' preflight_output.txt | grep -v '^ERRORS:' || true)
PRE_WARNS=$(grep 'WARNING:' preflight_output.txt | grep -v '^WARNINGS:' || true)

# —————————————————————————————————————————————————————————————
# 3. Install missing dependencies
# —————————————————————————————————————————————————————————————
if [ "$OFFLINE" -eq 0 ]; then
	if echo "$PRE_ERRS" | grep -q "git is not installed"; then
		install_git
	fi
	if echo "$PRE_ERRS" | grep -q "Java not found"; then
		install_java
	fi
	if echo "$PRE_ERRS" | grep -q "psql is not installed"; then
		install_psql
	fi
	if echo "$PRE_ERRS" | grep -q "jq is not installed"; then
		install_jq
	fi
fi

# Offline mode setup
if [ "$OFFLINE" -eq 1 ]; then
	echo "[offline] Enabling offline mode using bundle at: $OFFLINE_BUNDLE_DIR"
	require_rhel
	offline_setup_local_repos         # install deps from bundled RPMs
	offline_install_dependencies      # podman/podman-compose/java.psql/jq
	offline_load_images               # load all *.oci.tar
	offline_block_external_registries # avoid accidental pulls
fi

if [[ $CONTAINER_ENGINE == "docker" ]]; then
	# Ensure Docker is installed
	if ! command -v docker &>/dev/null || ! command -v docker-compose &>/dev/null; then
		install_docker
	fi

	# Check if current user is in docker group
	if id -nG "$USER" | grep -qw docker; then
		DOCKER_USER="$USER"
	else
		# Not in group: prompt for username to add
		DOCKER_USER=$(prompt_for_docker_user)
		if ! id "$DOCKER_USER" &>/dev/null; then
			echo "User '$DOCKER_USER' does not exist."
			exit 1
		fi
		if ! id -nG "$DOCKER_USER" | grep -qw docker; then
			echo "Adding $DOCKER_USER to docker group..."
			sudo usermod -aG docker "$DOCKER_USER"
			echo "Added $DOCKER_USER to docker group."
			echo "You may need to log out and back in for the group change to take effect, "
			echo "or deployment steps will attempt to use the group automatically via 'sg docker'."
		fi
	fi
elif [[ $CONTAINER_ENGINE == "podman" ]]; then
	if [ "$OFFLINE" -eq 0 ]; then
		# Install podman if missing
		if ! command -v podman &>/dev/null; then
			install_podman
		fi
		if ! command -v podman-compose &>/dev/null; then
			install_podman
		fi
	fi

	# Ensure we will run podman rootless as the invoking user (no sudo anywhere)
	ROOTLESS_USER="$(resolve_rootless_user)"

	# Rootless pre-reqs (linger, config dirs, networking)
	setup_podman_rootless "${ROOTLESS_USER}"
	if [ "$OFFLINE" -eq 1 ]; then
		ensure_subids_for_user "${ROOTLESS_USER}"
	fi
else
	echo "Unknown container engine: $CONTAINER_ENGINE"
	exit 1
fi

prompt_postgres_option setup

if [[ $POSTGRES_SETUP_OPTION == "1" ]]; then
	export USE_INTERNAL_PG="y"
	install_and_configure_postgres
elif [[ $POSTGRES_SETUP_OPTION == "2" ]]; then
	export USE_INTERNAL_PG="n"
	configure_ip_pass
fi

# —————————————————————————————————————————————————————————————
# 4. Run setup-wizard
# —————————————————————————————————————————————————————————————
echo
echo "Launching the setup wizard..."
set +e
CONTAINER_ENGINE="$CONTAINER_ENGINE" \
	USE_INTERNAL_PG="$USE_INTERNAL_PG" \
	./setup-wizard.sh
set -e

echo
echo "Re-running preflight after setup..."
cd "$SCRIPT_PATH"
bash "$SCRIPT_PATH/preflight.sh"
PRE_ERR=$?

# —————————————————————————————————————————————————————————————
# 5. Block on critical errors
# —————————————————————————————————————————————————————————————
if [[ $PRE_ERR -ne 0 ]]; then
	echo
	echo "Preflight detected critical errors above."
	echo "Please resolve these before proceeding with deployment."
	exit 1
fi

# —————————————————————————————————————————————————————————————
# 6. Confirm deploy (validate Y/N)
# —————————————————————————————————————————————————————————————
DEPLOY_OK=$(prompt_yn "All checks complete. Proceed with deployment?")
if [[ $DEPLOY_OK == "n" ]]; then
	echo "Aborted by user."
	exit 0
fi

# —————————————————————————————————————————————————————————————
# 7. Deploy based on selected engine
# —————————————————————————————————————————————————————————————
CONTAINER_DIR="$REPO_ROOT/$CONTAINER_ENGINE"
deploy_stack

echo
echo "IriusRisk deployment started."

echo
echo "Waiting for IriusRisk to become healthy (up to 60 minutes)..."
if wait_for_health 60 60; then
	POST_JSON="$(cat /tmp/irius_health.json 2>/dev/null || true)"
	POST_VERSION="$(printf '%s' "$POST_JSON" | extract_version_from_json)"
	echo "Installation successful: IriusRisk is healthy. Detected version: ${POST_VERSION:-unknown}"
else
	die "IriusRisk did not become healthy within 60 minutes."
fi

echo "Deployment completed."
