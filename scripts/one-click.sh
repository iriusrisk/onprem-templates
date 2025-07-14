#!/usr/bin/env bash

set -e

REPO_URL="https://github.com/iriusrisk/onprem-templates.git"
BRANCH="${BRANCH:-main}"
REPO_DIR="onprem-templates"
SCRIPTS_SUBDIR="scripts"

function print_header() {
    echo "IriusRisk One-Click Bootstrap Deployment"
    echo "---------------------------------------"
}

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
    else
        echo "Please install Docker and Docker Compose manually."
        exit 1
    fi
}

function install_podman() {
    echo "Installing Podman..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y podman podman-compose
    elif command -v yum &>/dev/null; then
        sudo yum install -y podman podman-compose
    else
        echo "Please install podman and podman-compose manually."
        exit 1
    fi
}

function install_git() {
    echo "Installing git..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y git
    elif command -v yum &>/dev/null; then
        sudo yum install -y git
    else
        echo "Please install git manually."
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
        echo "Please install Java 17 manually."
        exit 1
    fi
}

# Helper for setup-fixable warnings
function has_setup_fixable_warnings() {
    echo "$1" | grep -q "must be set to a real value" && return 0
    echo "$1" | grep -q "not set in" && return 0
    echo "$1" | grep -q "not found (required for custom config)" && return 0
    return 1
}

print_header

# 0. Ensure we're in scripts dir, clone if needed
SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ -f "$REPO_DIR/$SCRIPTS_SUBDIR/one-click.sh" ]]; then
    cd "$REPO_DIR/$SCRIPTS_SUBDIR"
elif [[ -d "$REPO_DIR" ]]; then
    cd "$REPO_DIR"
    [[ -d "$SCRIPTS_SUBDIR" ]] && cd "$SCRIPTS_SUBDIR"
elif [[ -f "one-click.sh" && -f "preflight.sh" && -f "setup-wizard.sh" ]]; then
    :
elif [[ -d "../$SCRIPTS_SUBDIR" && -f "../$SCRIPTS_SUBDIR/one-click.sh" ]]; then
    cd "../$SCRIPTS_SUBDIR"
fi

if [[ ! -d "$REPO_DIR" ]]; then
    # Only install git if not present
    if ! command -v git &>/dev/null; then
        echo "git not found, installing..."
        install_git
    fi
    echo "IriusRisk repo not found. Cloning (branch: $BRANCH)..."
    git clone --branch "$BRANCH" --single-branch "$REPO_URL"
    cd "$REPO_DIR/$SCRIPTS_SUBDIR"
elif [[ ! -f "one-click.sh" || ! -f "preflight.sh" || ! -f "setup-wizard.sh" ]]; then
    echo "Could not locate or clone the onprem-templates repo. Please check your environment."
    exit 1
fi

echo "Current directory: $(pwd)"
echo

# 1. Run preflight and capture errors/warnings
./preflight.sh > preflight_output.txt 2>&1 || true

PRE_ERRS=$(grep 'ERROR:' preflight_output.txt | grep -v '^ERRORS:' || true)
PRE_WARNS=$(grep 'WARNING:' preflight_output.txt | grep -v '^WARNINGS:' || true)

# 2. Install missing dependencies (auto-fix if needed)
if echo "$PRE_ERRS" | grep -q "git is not installed"; then
    install_git
fi
if echo "$PRE_ERRS" | grep -q "Java not found"; then
    install_java
fi
if echo "$PRE_ERRS" | grep -q "Neither Docker nor Podman is installed"; then
    read -rp "Install Docker or Podman? (docker/podman): " WHICH_STACK
    if [[ "$WHICH_STACK" =~ ^[Dd]ocker ]]; then
        install_docker
    else
        install_podman
    fi
elif echo "$PRE_ERRS" | grep -q "docker-compose is not installed"; then
    install_docker
elif echo "$PRE_ERRS" | grep -q "podman-compose is not installed"; then
    install_podman
fi

# 3. SAML question early if needed (check warnings only, as SAML is now only a warning)
SKIP_SAML=""

# Only prompt if one or both SAML warnings are actually present
if echo "$PRE_WARNS" \
    | grep -qE "KEYSTORE_PASSWORD must be set|KEY_ALIAS_PASSWORD must be set"; then

  read -rp "Do you want to enable SAML integration for this deployment? (y/n): " ENABLE_SAML_ONCLICK
  if [[ ! "$ENABLE_SAML_ONCLICK" =~ ^[Yy] ]]; then
    # safely remove just those two warning lines, without exiting on "no match"
    PRE_WARNS=$(
      printf '%s\n' "$PRE_WARNS" \
      | grep -Ev "KEYSTORE_PASSWORD must be set|KEY_ALIAS_PASSWORD must be set" \
      || true
    )
    SKIP_SAML="yes"
  fi
fi

# 4. If override/SAML warnings remain, run setup wizard
if has_setup_fixable_warnings "$PRE_WARNS"; then
    echo "WARNING: Override and/or SAML override files are missing or incomplete."
    echo "Launching the interactive setup wizard..."

    if [[ "$SKIP_SAML" == "yes" ]]; then
    SAML_CHOICE="n"
    elif [[ "$ENABLE_SAML_ONCLICK" =~ ^[Yy] ]]; then
    SAML_CHOICE="y"
    fi

    if [[ -n "$SAML_CHOICE" ]]; then
    SAML_CHOICE="$SAML_CHOICE" ./setup-wizard.sh
    else
    ./setup-wizard.sh
    fi

    echo "Re-running preflight after setup..."
    ./preflight.sh > preflight_output.txt 2>&1 || true
    PRE_ERRS=$(grep 'ERROR:' preflight_output.txt | grep -v '^ERRORS:' || true)
    PRE_WARNS=$(grep 'WARNING:' preflight_output.txt | grep -v '^WARNINGS:' || true)
    if [[ "$SKIP_SAML" == "yes" ]]; then
        PRE_WARNS=$(echo "$PRE_WARNS" | grep -v "KEYSTORE_PASSWORD must be set" | grep -v "KEY_ALIAS_PASSWORD must be set")
    fi
fi

echo
echo "Preflight errors:"
echo "$PRE_ERRS"
echo "Preflight warnings:"
echo "$PRE_WARNS"
echo

# 5. Only block on critical errors (ignore warnings)
if [[ -n "$PRE_ERRS" ]]; then
    echo "There are still critical errors detected:"
    echo "$PRE_ERRS"
    echo "Please resolve these before proceeding with deployment."
    exit 1
fi

# 6. Confirm deploy, even if warnings remain
read -rp "All checks complete. Proceed with deployment? (y/n): " DEPLOY_OK
if [[ ! "$DEPLOY_OK" =~ ^[Yy] ]]; then
    echo "Aborted by user."
    exit 0
fi

# 7. Deploy the stack
if command -v docker &>/dev/null; then
    echo "Deploying with Docker Compose..."
    cd ../docker
    docker-compose -f docker-compose.yml -f docker-compose.override.yml up -d
elif command -v podman &>/dev/null; then
    echo "Deploying with Podman Compose..."
    cd ../podman
    podman-compose -f container-compose.yml -f container-compose.override.yml up -d
else
    echo "Could not determine if Docker or Podman is in use. Please deploy manually."
    exit 1
fi

echo
echo "IriusRisk deployment started."
