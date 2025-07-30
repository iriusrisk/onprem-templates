#!/usr/bin/env bash

# —————————————————————————————————————————————————————————————
# Print header
# —————————————————————————————————————————————————————————————
function print_header() {
    echo "IriusRisk On-Prem Preflight Check"
    echo "----------------------------------"
}

# —————————————————————————————————————————————————————————————
# Input validation functions
# —————————————————————————————————————————————————————————————

function prompt_yn() {
    while true; do
        read -rp "$1 (y/n): " yn
        yn=${yn,,}
        case "$yn" in
            y|yes) echo "y"; return 0 ;;
            n|no)  echo "n"; return 0 ;;
            *)     echo "Invalid input: '$yn'. Please enter 'y' or 'n'." ;;
        esac
    done
}

function prompt_engine() {
    while true; do
        read -rp "Which container engine do you want to use? (docker/podman): " engine
        engine=${engine,,}
        case "$engine" in
            docker|podman)
                echo "$engine"
                return 0
                ;;
            *)
                echo "Invalid input: '$engine'. Please enter 'docker' or 'podman'."
                ;;
        esac
    done
}

# —————————————————————————————————————————————————————————————
# Version and file check utilities
# —————————————————————————————————————————————————————————————
function trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

function check_command() {
    if ! command -v "$1" &>/dev/null; then
        msg="ERROR: '$1' is not installed."
        echo "$msg"
        ERRORS+=("$msg")
        return 1
    fi
    return 0
}

function check_version() {
    local cmd=$1
    local required=$2
    local actual=$($cmd --version | grep -oE "[0-9]+(\.[0-9]+)+" | head -1)
    if [[ -z "$actual" ]]; then
        msg="ERROR: Could not detect version for $cmd"
        echo "$msg"
        ERRORS+=("$msg")
        return 1
    fi
    if [[ "$(printf '%s\n' "$required" "$actual" | sort -V | head -n1)" != "$required" ]]; then
        msg="ERROR: $cmd version $required+ required, found $actual"
        echo "$msg"
        ERRORS+=("$msg")
        return 1
    fi
    echo "$cmd version $actual OK"
    return 0
}

function check_file() {
    if [[ ! -f "$1" ]]; then
        msg="ERROR: Required file '$1' not found."
        echo "$msg"
        ERRORS+=("$msg")
        return 1
    fi
    echo "Found file: $1"
    return 0
}

function is_rhel_like() {
    source /etc/os-release
    [[ "$ID_LIKE" == *rhel* ]] || [[ "$ID_LIKE" == *fedora* ]] || [[ "$ID" == "fedora" ]] || [[ "$ID" == "centos" ]] || [[ "$ID" == "rhel" ]] || [[ "$ID" == "rocky" ]] || [[ "$ID" == "almalinux" ]]
}

# —————————————————————————————————————————————————————————————
# Start of main script logic
# —————————————————————————————————————————————————————————————
print_header

REQUIRED_DOCKER="20.10.0"
REQUIRED_DOCKER_COMPOSE="1.29.0"
REQUIRED_PODMAN="5.0.0"
REQUIRED_JAVA="17"

ERRORS=()
WARNINGS=()

OVERRIDE_FILE=""
SAML_FILE=""


# —————————————————————————————————————————————————————————————
# 0. SAML setup
# —————————————————————————————————————————————————————————————

if [[ -n "$SAML_CHOICE" ]]; then
    ENABLE_SAML="$SAML_CHOICE"
    echo "SAML setup: Using value from one-click ('${SAML_CHOICE}')"
else
    ENABLE_SAML=$(prompt_yn "Enable SAML integration for this deployment?")
fi

# —————————————————————————————————————————————————————————————
# 1. Decide on container engine
# —————————————————————————————————————————————————————————————
if is_rhel_like; then
    # Only prompt if Red Hat-like
    if [[ -z "$CONTAINER_ENGINE" ]]; then
        while true; do
            read -rp "Which container engine do you want to use for deployment? (docker/podman): " engine
            engine=${engine,,}
            case "$engine" in
                docker|podman) CONTAINER_ENGINE="$engine"; break ;;
                *) echo "Invalid input: '$engine'. Please enter 'docker' or 'podman'." ;;
            esac
        done
    fi
else
    # Always use Docker on non-RedHat-like systems
    CONTAINER_ENGINE="docker"
    echo "Defaulting to Docker on this system (CONTAINER_ENGINE=docker)"
fi

export CONTAINER_ENGINE

# —————————————————————————————————————————————————————————————
# 2. Check OS type
# —————————————————————————————————————————————————————————————
echo "Checking OS type..."
if [[ "$(uname -s)" != "Linux" ]]; then
    msg="ERROR: OS is not Linux. Detected: $(uname -s)"
    echo "$msg"
    ERRORS+=("$msg")
else
    echo "Linux OS detected"
fi

# —————————————————————————————————————————————————————————————
# 3. Check for git and global git config
# —————————————————————————————————————————————————————————————
if command -v git &>/dev/null; then
    echo "git found."
    GIT_NAME=$(git config --global user.name)
    if [[ -z "$GIT_NAME" ]]; then
        msg="WARNING: git user.name is not set globally. Use: git config --global user.name 'Your Name'"
        echo "$msg"
        WARNINGS+=("$msg")
    else
        echo "git user.name: $GIT_NAME"
    fi
    GIT_EMAIL=$(git config --global user.email)
    if [[ -z "$GIT_EMAIL" ]]; then
        msg="WARNING: git user.email is not set globally. Use: git config --global user.email 'your@email.com'"
        echo "$msg"
        WARNINGS+=("$msg")
    else
        echo "git user.email: $GIT_EMAIL"
    fi
else
    msg="ERROR: git is not installed. Please install git to clone or update the repository."
    echo "$msg"
    ERRORS+=("$msg")
fi

# —————————————————————————————————————————————————————————————
# 4. Check chosen engine, versions, and override paths
# —————————————————————————————————————————————————————————————
case "$CONTAINER_ENGINE" in
    docker)
        if command -v docker &>/dev/null; then
            echo "Docker found."
            check_version docker "$REQUIRED_DOCKER"
            if check_command docker-compose; then
                check_version docker-compose "$REQUIRED_DOCKER_COMPOSE"
            else
                msg="ERROR: 'docker-compose' is not installed."
                echo "$msg"
                ERRORS+=("$msg")
            fi
            OVERRIDE_FILE="../docker/docker-compose.override.yml"
            SAML_FILE="../docker/docker-compose.saml.yml"
        else
            msg="ERROR: Docker not installed but selected as engine."
            echo "$msg"
            ERRORS+=("$msg")
        fi
        ;;
    podman)
        if command -v podman &>/dev/null; then
            echo "Podman found."
            check_version podman "$REQUIRED_PODMAN"
            if ! check_command podman-compose; then
                msg="ERROR: 'podman-compose' is not installed."
                echo "$msg"
                ERRORS+=("$msg")
            fi
            OVERRIDE_FILE="../podman/container-compose.override.yml"
            SAML_FILE="../podman/container-compose.saml.yml"
        else
            msg="ERROR: Podman not installed but selected as engine."
            echo "$msg"
            ERRORS+=("$msg")
        fi
        ;;
    *)
        msg="ERROR: Unknown container engine '$CONTAINER_ENGINE'"
        echo "$msg"
        ERRORS+=("$msg")
        ;;
esac

# —————————————————————————————————————————————————————————————
# 5. Check Java
# —————————————————————————————————————————————————————————————
if command -v java &>/dev/null; then
    JAVA_FULL_VER=$(java -version 2>&1 | head -n 1)
    JAVA_VER=$(echo "$JAVA_FULL_VER" | grep -oE '[0-9]+' | head -n1)
    if [[ -z "$JAVA_VER" ]]; then
        msg="ERROR: Could not parse Java version from \"$JAVA_FULL_VER\""
        echo "$msg"
        ERRORS+=("$msg")
    elif (( JAVA_VER < REQUIRED_JAVA )); then
        msg="ERROR: Java $REQUIRED_JAVA+ required, found $JAVA_VER"
        echo "$msg"
        ERRORS+=("$msg")
    else
        echo "Java version $JAVA_VER OK"
    fi
else
    msg="ERROR: Java not found"
    echo "$msg"
    ERRORS+=("$msg")
fi

# —————————————————————————————————————————————————————————————
# 6. Check required local certificate/key files
# —————————————————————————————————————————————————————————————
echo "Checking required local certificate/key files..."
for f in cert.pem key.pem ec_private.pem; do
    check_file "../$CONTAINER_ENGINE/$f"
done

# —————————————————————————————————————————————————————————————
# 7. Check override files for required variables and valid values
# —————————————————————————————————————————————————————————————
POSTGRES_VALUES_FILLED=1

if [[ -n "$OVERRIDE_FILE" && -f "$OVERRIDE_FILE" ]]; then
    echo "Checking $OVERRIDE_FILE for required variables and valid values..."

    NG_SERVER_NAME=$(grep NG_SERVER_NAME "$OVERRIDE_FILE" | head -1 | sed 's/.*NG_SERVER_NAME=//;s/"//g' | xargs)
    if [[ -z "$NG_SERVER_NAME" || "$NG_SERVER_NAME" == "\${HOST_NAME}" || "$NG_SERVER_NAME" == '${HOST_NAME}' ]]; then
        msg="WARNING: NG_SERVER_NAME must be set to a real value in $OVERRIDE_FILE (not left as \${HOST_NAME})"
        echo "$msg"
        WARNINGS+=("$msg")
    else
        echo "NG_SERVER_NAME: $NG_SERVER_NAME"
    fi

    IRIUS_EXT_URL=$(grep IRIUS_EXT_URL "$OVERRIDE_FILE" | head -1 | sed 's/.*IRIUS_EXT_URL=//;s/"//g' | xargs)
    if [[ -z "$IRIUS_EXT_URL" || "$IRIUS_EXT_URL" == *'${HOST_NAME}'* ]]; then
        msg="WARNING: IRIUS_EXT_URL must be set to a real value in $OVERRIDE_FILE (not left as \${HOST_NAME})"
        echo "$msg"
        WARNINGS+=("$msg")
    else
        echo "IRIUS_EXT_URL: $IRIUS_EXT_URL"
    fi

    IRIUS_DB_URL=$(grep IRIUS_DB_URL "$OVERRIDE_FILE" | head -1 | sed 's/.*IRIUS_DB_URL=//;s/"//g' | xargs)
    if [[ -z "$IRIUS_DB_URL" ]]; then
        msg="WARNING: IRIUS_DB_URL must be set in $OVERRIDE_FILE"
        echo "$msg"
        WARNINGS+=("$msg")
        POSTGRES_VALUES_FILLED=0
    elif [[ "$IRIUS_DB_URL" == *'${POSTGRES_IP}'* || "$IRIUS_DB_URL" == *'${POSTGRES_PASSWORD}'* ]]; then
        msg="WARNING: IRIUS_DB_URL must be filled in with real Postgres IP and password, not left as template variables in $OVERRIDE_FILE"
        echo "$msg"
        WARNINGS+=("$msg")
        POSTGRES_VALUES_FILLED=0
    else
        echo "IRIUS_DB_URL: $IRIUS_DB_URL"
    fi
else
    if [[ -n "$OVERRIDE_FILE" ]]; then
        msg="WARNING: $OVERRIDE_FILE not found (required for custom config)"
        echo "$msg"
        WARNINGS+=("$msg")
    fi
fi

# —————————————————————————————————————————————————————————————
# 8. SAML checks
# —————————————————————————————————————————————————————————————
if [[ "$ENABLE_SAML" == "y" && -n "$SAML_FILE" && -f "$SAML_FILE" ]]; then
    echo "Checking $SAML_FILE for required variables and valid values..."

    SAML_KEYSTORE_PASSWORD=$(grep KEYSTORE_PASSWORD "$SAML_FILE" | head -1 | sed 's/.*KEYSTORE_PASSWORD=//;s/"//g' | xargs)
    if [[ -z "$SAML_KEYSTORE_PASSWORD" || "$SAML_KEYSTORE_PASSWORD" == "\${KEYSTORE_PASSWORD}" || "$SAML_KEYSTORE_PASSWORD" == '${KEYSTORE_PASSWORD}' ]]; then
        msg="WARNING: KEYSTORE_PASSWORD must be set to a real value in $SAML_FILE (not left as \${KEYSTORE_PASSWORD})"
        echo "$msg"
        WARNINGS+=("$msg")
    else
        echo "KEYSTORE_PASSWORD set in $SAML_FILE"
    fi

    SAML_KEY_ALIAS_PASSWORD=$(grep KEY_ALIAS_PASSWORD "$SAML_FILE" | head -1 | sed 's/.*KEY_ALIAS_PASSWORD=//;s/"//g' | xargs)
    if [[ -z "$SAML_KEY_ALIAS_PASSWORD" || "$SAML_KEY_ALIAS_PASSWORD" == "\${KEY_ALIAS_PASSWORD}" || "$SAML_KEY_ALIAS_PASSWORD" == '${KEY_ALIAS_PASSWORD}' ]]; then
        msg="WARNING: KEY_ALIAS_PASSWORD must be set to a real value in $SAML_FILE (not left as \${KEY_ALIAS_PASSWORD})"
        echo "$msg"
        WARNINGS+=("$msg")
    else
        echo "KEY_ALIAS_PASSWORD set in $SAML_FILE"
    fi
fi

# —————————————————————————————————————————————————————————————
# 9. Postgres connectivity check (if applicable)
# —————————————————————————————————————————————————————————————
if [[ $POSTGRES_VALUES_FILLED -eq 1 ]]; then
    DB_IP=$(echo "$IRIUS_DB_URL" | sed -n 's/.*jdbc:postgresql:\/\/\([^:/]*\).*/\1/p')
    DB_PASS=$(echo "$IRIUS_DB_URL" | sed -n 's/.*password=\([^& ]*\).*/\1/p')
    if [[ -n "$DB_IP" && -n "$DB_PASS" ]]; then
        if command -v psql &>/dev/null; then
            if PGPASSWORD="$DB_PASS" psql -h "$DB_IP" -U iriusprod -c '\q' 2>/dev/null; then
                echo "Postgres connection to $DB_IP OK"
            else
                msg="ERROR: Could not connect to Postgres at $DB_IP with supplied password (check Postgres service, IP, and credentials)"
                echo "$msg"
                ERRORS+=("$msg")
            fi
        else
            msg="ERROR: 'psql' client is not installed (needed for preflight check of Postgres connectivity)"
            echo "$msg"
            ERRORS+=("$msg")
        fi
    else
        msg="ERROR: Could not parse DB_IP or DB_PASS from IRIUS_DB_URL in $OVERRIDE_FILE"
        echo "$msg"
        ERRORS+=("$msg")
    fi
else
    echo "Postgres connectivity check skipped due to unmodified IRIUS_DB_URL."
fi

# —————————————————————————————————————————————————————————————
# 10. Print summary report
# —————————————————————————————————————————————————————————————
echo
echo "================ Preflight Report ================"

if [[ ${#ERRORS[@]} -eq 0 && ${#WARNINGS[@]} -eq 0 ]]; then
    echo "All checks passed. Your system is ready for IriusRisk deployment."
else
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo "ERRORS:"
        for err in "${ERRORS[@]}"; do
            echo "  $err"
        done
    fi
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo "WARNINGS:"
        for warn in "${WARNINGS[@]}"; do
            echo "  $warn"
        done
    fi
    echo
    echo "Suggestions:"
    [[ ${#ERRORS[@]} -gt 0 ]] && echo "- Please fix all ERRORS above before proceeding (deployment will likely fail otherwise)."
    [[ ${#WARNINGS[@]} -gt 0 ]] && echo "- Review WARNINGS and ensure your configuration matches your needs."
    echo "- Refer to the official documentation for guidance: https://enterprise-support.iriusrisk.com/"
    echo "- Rerun this script after making changes to verify your setup."
fi

echo "=================================================="

if [[ ${#ERRORS[@]} -ne 0 ]]; then
    exit 1
fi
exit 0

