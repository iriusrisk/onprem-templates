#!/usr/bin/env bash
set -e

# —————————————————————————————————————————————————————————————
# Print header
# —————————————————————————————————————————————————————————————
function print_header() {
    echo "IriusRisk One-Click Bootstrap Deployment"
    echo "---------------------------------------"
}

# —————————————————————————————————————————————————————————————
# Input validation functions
# —————————————————————————————————————————————————————————————
function prompt_yn() {
    # $1 = prompt
    while true; do
        read -rp "$1 (y/n): " yn
        yn=${yn,,}
        case "$yn" in
            y|yes) echo "y"; return 0 ;;
            n|no)  echo "n"; return 0 ;;
            *)
                echo "Invalid input: '$yn'. Please enter 'y' or 'n'." >&2
                ;;
        esac
    done
}

function prompt_engine() {
    # $1 = prompt
    while true; do
        read -rp "$1 (docker/podman): " engine
        engine=${engine,,}
        case "$engine" in
            docker|podman)
                echo "$engine"
                return 0
                ;;
            *)
                echo "Invalid input: '$engine'. Please enter 'docker' or 'podman'." >&2
                ;;
        esac
    done
}

# —————————————————————————————————————————————————————————————
# Dependency install functions
# —————————————————————————————————————————————————————————————
function install_docker() {
    echo "Installing Docker..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y docker.io docker-compose
        sudo systemctl start docker
        sudo systemctl enable docker
    elif command -v yum &>/dev/null; then
        sudo yum install -y docker docker-compose
        sudo systemctl start docker
        sudo systemctl enable docker
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y docker docker-compose
        sudo systemctl start docker
        sudo systemctl enable docker
    else
        echo "Please install Docker and Docker Compose manually." >&2
        exit 1
    fi
}

function install_podman() {
    echo "Installing Podman and podman-compose..."
    sudo dnf install -y container-tools podman-compose || sudo yum install -y container-tools podman-compose
}

function install_git() {
    echo "Installing git..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y git
    elif command -v yum &>/dev/null; then
        sudo yum install -y git
    else
        echo "Please install git manually." >&2
        exit 1
    fi
}

function install_java() {
    echo "Installing Java 17..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y openjdk-17-jre-headless
    elif command -v yum &>/dev/null; then
        sudo yum install -y java-17-openjdk
    else
        echo "Please install Java 17 manually." >&2
        exit 1
    fi
}


function has_setup_fixable_warnings() {
    echo "$1" | grep -q "must be set to a real value" && return 0
    echo "$1" | grep -q "not set in" && return 0
    echo "$1" | grep -q "not found (required for custom config)" && return 0
    return 1
}

function is_rhel_like() {
    source /etc/os-release
    [[ "$ID_LIKE" == *rhel* ]] || [[ "$ID_LIKE" == *fedora* ]] || [[ "$ID" == "fedora" ]] || [[ "$ID" == "centos" ]] || [[ "$ID" == "rhel" ]] || [[ "$ID" == "rocky" ]] || [[ "$ID" == "almalinux" ]]
}


# —————————————————————————————————————————————————————————————
# Script Start
# —————————————————————————————————————————————————————————————
print_header

REPO_URL="https://github.com/iriusrisk/onprem-templates.git"
BRANCH="${BRANCH:-main}"
REPO_DIR="onprem-templates"
SCRIPTS_SUBDIR="scripts"

# —————————————————————————————————————————————————————————————
# 0. Ensure we're in the scripts dir (or clone it)
# —————————————————————————————————————————————————————————————
SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ -f "$SCRIPT_PATH/preflight.sh" && -f "$SCRIPT_PATH/setup-wizard.sh" ]]; then
    cd "$SCRIPT_PATH"
elif [[ ! -d "$REPO_DIR" ]]; then
    if ! command -v git &>/dev/null; then
        echo "git not found, installing..."
        install_git
    fi
    echo "IriusRisk repo not found. Cloning (branch: $BRANCH)..."
    git clone --branch "$BRANCH" --single-branch "$REPO_URL"
    cd "$REPO_DIR/$SCRIPTS_SUBDIR"
elif [[ ! -f "$REPO_DIR/$SCRIPTS_SUBDIR/one-click.sh" ]]; then
    echo "Could not locate or clone the onprem-templates repo. Please check your environment." >&2
    exit 1
else
    cd "$REPO_DIR/$SCRIPTS_SUBDIR"
fi

echo "Current directory: $(pwd)"
echo

# —————————————————————————————————————————————————————————————
# 1. Pick your container engine once (validate)
# —————————————————————————————————————————————————————————————
if is_rhel_like; then
    ENGINE=$(prompt_engine "Which container engine do you want to use for deployment? (docker/podman)")
else
    echo "Only Docker is supported on your system. Using Docker."
    ENGINE="docker"
fi
export CONTAINER_ENGINE="$ENGINE"

# —————————————————————————————————————————————————————————————
# 2. SAML question early if needed (validate Y/N)
# —————————————————————————————————————————————————————————————
    ENABLE_SAML_ONCLICK=$(prompt_yn "Enable SAML integration for this deployment?")
    if [[ "$ENABLE_SAML_ONCLICK" == "n" ]]; then
        PRE_WARNS=$(
            printf '%s\n' "$PRE_WARNS" \
            | grep -Ev "KEYSTORE_PASSWORD must be set|KEY_ALIAS_PASSWORD must be set" \
            || true
        )
        SKIP_SAML="yes"
    fi

# —————————————————————————————————————————————————————————————
# 3. Run preflight and capture output
# —————————————————————————————————————————————————————————————
SAML_CHOICE="$ENABLE_SAML_ONCLICK" bash "$SCRIPT_PATH/preflight.sh" > preflight_output.txt 2>&1 || true
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

if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
    if ! command -v docker &>/dev/null; then
        install_docker
    fi
elif [[ "$CONTAINER_ENGINE" == "podman" ]]; then
    if ! command -v podman &>/dev/null; then
        install_podman
    fi
    if ! command -v podman-compose &>/dev/null; then
        install_podman
    fi
else
    echo "Unknown container engine: $CONTAINER_ENGINE"
    exit 1
fi

# —————————————————————————————————————————————————————————————
# 5. If setup-wizard is needed, run it
# —————————————————————————————————————————————————————————————
if has_setup_fixable_warnings "$PRE_WARNS"; then
    echo
    echo "WARNING: Override and/or SAML override files are missing or incomplete."
    echo "Launching the interactive setup wizard..."
    set +e
    if [[ -n "$ENABLE_SAML_ONCLICK" ]]; then
        CONTAINER_ENGINE="$CONTAINER_ENGINE" \
          SAML_CHOICE="$ENABLE_SAML_ONCLICK" \
          ./setup-wizard.sh
    else
        CONTAINER_ENGINE="$CONTAINER_ENGINE" ./setup-wizard.sh
    fi
    set -e

    echo
    echo "Re-running preflight after setup..."
    cd "$SCRIPT_PATH"
    SAML_CHOICE="$ENABLE_SAML_ONCLICK" bash "$SCRIPT_PATH/preflight.sh"
    PRE_ERR=$?
fi

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
if [[ "$DEPLOY_OK" == "n" ]]; then
    echo "Aborted by user."
    exit 0
fi

# —————————————————————————————————————————————————————————————
# 8. Deploy based on selected engine
# —————————————————————————————————————————————————————————————
case "$CONTAINER_ENGINE" in
    docker)
        echo
        echo "Deploying with Docker Compose..."
        cd ../docker
        docker-compose -f docker-compose.yml -f docker-compose.override.yml up -d
        ;;
    podman)
        echo
        echo "Deploying with Podman Compose..."
        cd ../podman
        podman-compose -f container-compose.yml -f container-compose.override.yml up -d
        ;;
    *)
        echo "Unknown engine '$CONTAINER_ENGINE'. Cannot deploy." >&2
        exit 1
        ;;
esac

echo
echo "IriusRisk deployment started."
