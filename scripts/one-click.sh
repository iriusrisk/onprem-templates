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

function prompt_postgres_option() {
    echo "How do you want to configure PostgreSQL?"
    echo "  1) Internal container Postgres"
    echo "  2) Existing Postgres (provide connection details)"
    echo "  3) Install and configure Postgres on this machine"
    while true; do
        read -rp "Enter 1, 2, or 3: " pg_option
        case "$pg_option" in
            1|2|3) break ;;
            *) echo "Invalid input: '$pg_option'. Please enter 1, 2, or 3." ;;
        esac
    done
    POSTGRES_SETUP_OPTION="$pg_option"
}

function prompt_registry_password() {
    read -srp "Enter the container registry password for user 'iriusrisk': " REGISTRY_PASS
    echo
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

function install_and_configure_postgres() {
    PG_USER="iriusprod"
    PG_DB="iriusprod"
    PG_SUPERUSER="postgres"

    # Terminate connections to the DB, if any
    echo "Terminating any existing connections to $PG_DB..."
    sudo -u $PG_SUPERUSER psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PG_DB';" || true

    # Drop the database if it exists
    echo "Dropping database $PG_DB if it exists..."
    sudo -u $PG_SUPERUSER psql -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$PG_DB';" | grep -q 1 \
    && sudo -u $PG_SUPERUSER psql -d postgres -c "DROP DATABASE \"$PG_DB\";" \
    || echo "Database $PG_DB does not exist, skipping drop."

    # Drop the user if it exists
    echo "Dropping user $PG_USER if it exists..."
    sudo -u $PG_SUPERUSER psql -d postgres -tc "SELECT 1 FROM pg_roles WHERE rolname = '$PG_USER';" | grep -q 1 \
    && sudo -u $PG_SUPERUSER psql -d postgres -c "DROP ROLE \"$PG_USER\";" \
    || echo "Role $PG_USER does not exist, skipping drop."

    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y wget ca-certificates
        # Add PGDG repo if not present
        if ! grep -q "apt.postgresql.org" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
            wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo tee /etc/apt/trusted.gpg.d/postgresql.asc >/dev/null
            echo "deb http://apt.postgresql.org/pub/repos/apt/ jammy-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
            sudo apt-get update
        fi
        sudo apt-get install -y postgresql-15 postgresql-client-15 postgresql-contrib
        PG_VERSION=15
        PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
        PG_HBA="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
        if [[ ! -f "$PG_CONF" ]]; then
            echo "ERROR: Postgres 15 config not found at $PG_CONF! Install may have failed." >&2
            exit 1
        fi
        sudo systemctl enable postgresql
        sudo systemctl start postgresql
    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
        # (your existing RHEL logic here)
        sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm || \
        sudo yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
        sudo dnf -qy module disable postgresql || sudo yum -qy module disable postgresql
        sudo dnf install -y postgresql15-server || sudo yum install -y postgresql15-server
        PG_CONF="/var/lib/pgsql/15/data/postgresql.conf"
        PG_HBA="/var/lib/pgsql/15/data/pg_hba.conf"
        sudo /usr/pgsql-15/bin/postgresql-15-setup initdb
        sudo systemctl enable postgresql-15
        sudo systemctl start postgresql-15
    else
        echo "ERROR: Unsupported OS for PostgreSQL install." >&2
        exit 1
    fi

    sudo cp "$PG_CONF" "$PG_CONF.bak"
    sudo sed -i "s/^#listen_addresses = .*/listen_addresses = '*'/" "$PG_CONF"

    sudo cp "$PG_HBA" "$PG_HBA.bak"
    sudo grep -q "host all all 0.0.0.0/0 scram-sha-256" "$PG_HBA" || \
        echo "host all all 0.0.0.0/0 scram-sha-256" | sudo tee -a "$PG_HBA"

    if command -v apt-get &>/dev/null; then
        sudo systemctl restart postgresql
    else
        sudo systemctl restart postgresql-15
    fi

    DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)
    (cd /tmp && sudo -u postgres psql -c "CREATE USER iriusprod WITH CREATEDB PASSWORD '${DB_PASS}';")
    (cd /tmp && sudo -u postgres psql -c "CREATE DATABASE iriusprod WITH OWNER iriusprod;")

    DB_IP=$(hostname -I | awk '{print $1}')
    export DB_IP DB_PASS
    echo "Local PostgreSQL is ready:"
    echo "  IP: $DB_IP"
    echo "  User: iriusprod"
    echo "  Password: $DB_PASS"
    echo "  Database: iriusprod"
}

function install_jq() {
    echo "Installing jq (for JSON parsing)..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y jq
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y jq
    elif command -v yum &>/dev/null; then
        sudo yum install -y jq
    else
        echo "Please install jq manually." >&2
        exit 1
    fi
}

# —————————————————————————————————————————————————————————————
# Helper functions
# —————————————————————————————————————————————————————————————

function is_rhel_like() {
    source /etc/os-release
    [[ "$ID_LIKE" == *rhel* ]] || [[ "$ID_LIKE" == *fedora* ]] || [[ "$ID" == "fedora" ]] || [[ "$ID" == "centos" ]] || [[ "$ID" == "rhel" ]] || [[ "$ID" == "rocky" ]] || [[ "$ID" == "almalinux" ]]
}


function ensure_certificates() {
    CERT_DIR="${CERT_DIR:-../$CONTAINER_ENGINE}"
    CERT_FILE="$CERT_DIR/cert.pem"
    KEY_FILE="$CERT_DIR/key.pem"
    EC_KEY_FILE="$CERT_DIR/ec_private.pem"

    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        echo "🔑 Generating RSA SSL certificate..."
        openssl req -newkey rsa:2048 -nodes -keyout "$KEY_FILE" -x509 -days 365 -out "$CERT_FILE" -subj "/CN=$(hostname -f)"
        chmod 644 "$CERT_FILE" "$KEY_FILE"
    else
        echo "🔑 SSL certificates already exist."
    fi

    if [[ ! -f "$EC_KEY_FILE" ]]; then
        echo "🔑 Generating EC private key..."
        openssl ecparam -genkey -name prime256v1 -noout -out "$EC_KEY_FILE"
        chmod 644 "$EC_KEY_FILE"
    else
        echo "🔑 EC private key already exists."
    fi
}

function is_logged_in_as_iriusrisk() {
    local config="$HOME/.docker/config.json"
    if [[ ! -f "$config" ]]; then
        return 1
    fi
    local auth_user
    auth_user=$(jq -r '.auths["https://index.docker.io/v1/"].auth // empty' "$config" 2>/dev/null | base64 -d 2>/dev/null | cut -d: -f1)
    [[ "$auth_user" == "iriusrisk" ]]
}

function container_registry_login() {
    local engine="$1"
    local registry_url="${2:-}"

    if is_logged_in_as_iriusrisk; then
        echo "Already logged in to Docker Hub as 'iriusrisk', skipping login prompt."
        return 0
    fi

    prompt_registry_password

    if [[ "$engine" == "docker" ]]; then
        echo "$REGISTRY_PASS" | docker login -u iriusrisk --password-stdin
    elif [[ "$engine" == "podman" ]]; then
        echo "$REGISTRY_PASS" | podman login -u iriusrisk --password-stdin
    else
        echo "Unknown container engine: $engine" >&2
        return 1
    fi
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
    SCRIPT_PATH="$(pwd)"
elif [[ ! -f "$REPO_DIR/$SCRIPTS_SUBDIR/one-click.sh" ]]; then
    echo "Could not locate or clone the onprem-templates repo. Please check your environment." >&2
    exit 1
else
    cd "$REPO_DIR/$SCRIPTS_SUBDIR"
    SCRIPT_PATH="$(pwd)"
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

# ---- Ensure certificates exist ----
ensure_certificates

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

if ! command -v jq &>/dev/null; then
    install_jq
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

prompt_postgres_option

if [[ "$POSTGRES_SETUP_OPTION" == "1" ]]; then
    export USE_INTERNAL_PG="y"
elif [[ "$POSTGRES_SETUP_OPTION" == "2" ]]; then
    export USE_INTERNAL_PG="n"
elif [[ "$POSTGRES_SETUP_OPTION" == "3" ]]; then
    install_and_configure_postgres
    export USE_INTERNAL_PG="n"
    export DB_IP DB_PASS
fi

# —————————————————————————————————————————————————————————————
# 5. Run setup-wizard
# —————————————————————————————————————————————————————————————
echo
echo "Launching the setup wizard..."
set +e
if [[ "$POSTGRES_SETUP_OPTION" == "3" ]]; then
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
if [[ "$DEPLOY_OK" == "n" ]]; then
    echo "Aborted by user."
    exit 0
fi

# ---- LOGIN TO CONTAINER REGISTRY ----
container_registry_login "$CONTAINER_ENGINE"

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
