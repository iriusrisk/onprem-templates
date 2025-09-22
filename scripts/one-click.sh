#!/usr/bin/env bash
source functions.sh
set -e

# Fallback for environments where $USER isn't set
if [[ -z ${USER:-} ]]; then
	USER="$(id -un)"
	export USER
fi

init_logging "$0"

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
# 2. SAML question early if needed (validate Y/N)
# —————————————————————————————————————————————————————————————
ENABLE_SAML_ONCLICK=$(prompt_yn "Enable SAML integration for this deployment?")
if [[ $ENABLE_SAML_ONCLICK == "n" ]]; then
	PRE_WARNS=$(
		printf '%s\n' "$PRE_WARNS" |
			grep -Ev "KEYSTORE_PASSWORD must be set|KEY_ALIAS_PASSWORD must be set" ||
			true
	)
fi

# —————————————————————————————————————————————————————————————
# 3. Run preflight and capture output
# —————————————————————————————————————————————————————————————
SAML_CHOICE="$ENABLE_SAML_ONCLICK" bash "$SCRIPT_PATH/preflight.sh" >preflight_output.txt 2>&1 || true
PRE_ERRS=$(grep 'ERROR:' preflight_output.txt | grep -v '^ERRORS:' || true)
PRE_WARNS=$(grep 'WARNING:' preflight_output.txt | grep -v '^WARNINGS:' || true)

# —————————————————————————————————————————————————————————————
# 4. Install missing dependencies
# —————————————————————————————————————————————————————————————
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
	# Install podman if missing
	if ! command -v podman &>/dev/null; then
		install_podman
	fi
	if ! command -v podman-compose &>/dev/null; then
		install_podman
	fi

	# Ensure we will run podman rootless as the invoking user (no sudo anywhere)
	ROOTLESS_USER="$(resolve_rootless_user)"

	# Rootless pre-reqs (linger, config dirs, networking)
	setup_podman_rootless "${ROOTLESS_USER}"
else
	echo "Unknown container engine: $CONTAINER_ENGINE"
	exit 1
fi

prompt_postgres_option setup

if [[ $POSTGRES_SETUP_OPTION == "1" ]]; then
	install_and_configure_postgres
	export USE_INTERNAL_PG="y"
	export DB_PASS
elif [[ $POSTGRES_SETUP_OPTION == "2" ]]; then
	export USE_INTERNAL_PG="n"
fi

# —————————————————————————————————————————————————————————————
# 5. Run setup-wizard
# —————————————————————————————————————————————————————————————
echo
echo "Launching the setup wizard..."
set +e
if [[ $POSTGRES_SETUP_OPTION == "3" ]]; then
	# We want to prefill the external DB choice and details
	CONTAINER_ENGINE="$CONTAINER_ENGINE" \
		SAML_CHOICE="$ENABLE_SAML_ONCLICK" \
		USE_INTERNAL_PG="$USE_INTERNAL_PG" \
		DB_IP="$DB_IP" \
		DB_PASS="$DB_PASS" \
		./setup-wizard.sh
else
	# Let setup-wizard prompt for everything as usual (internal/external/etc)
	CONTAINER_ENGINE="$CONTAINER_ENGINE" \
		SAML_CHOICE="$ENABLE_SAML_ONCLICK" \
		USE_INTERNAL_PG="$USE_INTERNAL_PG" \
		./setup-wizard.sh
fi
set -e

echo
echo "Re-running preflight after setup..."
cd "$SCRIPT_PATH"
SAML_CHOICE="$ENABLE_SAML_ONCLICK" bash "$SCRIPT_PATH/preflight.sh"
PRE_ERR=$?

# —————————————————————————————————————————————————————————————
# 6. Block on critical errors
# —————————————————————————————————————————————————————————————
if [[ $PRE_ERR -ne 0 ]]; then
	echo
	echo "Preflight detected critical errors above."
	echo "Please resolve these before proceeding with deployment."
	exit 1
fi

# —————————————————————————————————————————————————————————————
# 7. Confirm deploy (validate Y/N)
# —————————————————————————————————————————————————————————————
DEPLOY_OK=$(prompt_yn "All checks complete. Proceed with deployment?")
if [[ $DEPLOY_OK == "n" ]]; then
	echo "Aborted by user."
	exit 0
fi

# —————————————————————————————————————————————————————————————
# 8. Deploy based on selected engine
# —————————————————————————————————————————————————————————————
CONTAINER_DIR="$REPO_ROOT/$CONTAINER_ENGINE"
deploy_stack

echo
echo "IriusRisk deployment started."
