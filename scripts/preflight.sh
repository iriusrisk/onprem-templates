#!/usr/bin/env bash

echo "IriusRisk On-Prem Preflight Check"
echo "----------------------------------"

REQUIRED_DOCKER="20.10.0"
REQUIRED_DOCKER_COMPOSE="1.29.0"
REQUIRED_PODMAN="5.0.0"
REQUIRED_JAVA="17"

ERRORS=()
WARNINGS=()

OVERRIDE_FILE=""
SAML_FILE=""

# Utility to strip leading/trailing whitespace
trim() {
    local var="$*"
    # Remove leading whitespace characters
    var="${var#"${var%%[![:space:]]*}"}"
    # Remove trailing whitespace characters
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

function check_command() {
    if ! command -v "$1" &>/dev/null; then
        ERRORS+=("ERROR: '$1' is not installed.")
        return 1
    fi
    return 0
}

function check_version() {
    local cmd=$1
    local required=$2
    local actual=$($cmd --version | grep -oE "[0-9]+(\.[0-9]+)+" | head -1)
    if [[ -z "$actual" ]]; then
        ERRORS+=("ERROR: Could not detect version for $cmd")
        return 1
    fi
    if [[ "$(printf '%s\n' "$required" "$actual" | sort -V | head -n1)" != "$required" ]]; then
        ERRORS+=("ERROR: $cmd version $required+ required, found $actual")
        return 1
    fi
    echo "$cmd version $actual OK"
    return 0
}

function check_file() {
    if [[ ! -f "$1" ]]; then
        ERRORS+=("ERROR: Required file '$1' not found.")
        return 1
    fi
    echo "Found file: $1"
    return 0
}

echo "Checking OS type..."
if [[ "$(uname -s)" != "Linux" ]]; then
    ERRORS+=("ERROR: OS is not Linux. Detected: $(uname -s)")
else
    echo "Linux OS detected"
fi

# Check Docker or Podman and set override file
docker_present=0
podman_present=0

if command -v docker &>/dev/null; then
    docker_present=1
    echo "Docker found."
    check_version docker "$REQUIRED_DOCKER"
    if check_command docker-compose; then
        check_version docker-compose "$REQUIRED_DOCKER_COMPOSE"
    else
        ERRORS+=("ERROR: 'docker-compose' is not installed.")
    fi
    OVERRIDE_FILE="../docker/docker-compose.override.yml"
    SAML_FILE="../docker/docker-compose.saml.yml"
elif command -v podman &>/dev/null; then
    podman_present=1
    echo "Podman found."
    check_version podman "$REQUIRED_PODMAN"
    if ! check_command podman-compose; then
        ERRORS+=("ERROR: 'podman-compose' is not installed.")
    fi
    OVERRIDE_FILE="../podman/container-compose.override.yml"
    SAML_FILE="../podman/container-compose.saml.yml"
fi

if [[ $docker_present -eq 0 && $podman_present -eq 0 ]]; then
    ERRORS+=("ERROR: Neither Docker nor Podman is installed. At least one is required.")
fi

# Check Java
if command -v java &>/dev/null; then
    JAVA_VER=$(java -version 2>&1 | head -n 1 | grep -oE '[0-9]+')
    if [[ "$JAVA_VER" -lt "$REQUIRED_JAVA" ]]; then
        ERRORS+=("ERROR: Java 17+ required, found $JAVA_VER")
    else
        echo "Java version $JAVA_VER OK"
    fi
else
    ERRORS+=("ERROR: Java not found (required for IriusRisk app, usually in the image)")
fi

# Check required local files
echo "Checking required local certificate/key files..."
for f in cert.pem key.pem ec_private.pem; do
    check_file "$f"
done

# --- Check override files for required variables and valid values ---
POSTGRES_IP_FOUND=0
POSTGRES_PASSWORD_FOUND=0

if [[ -n "$OVERRIDE_FILE" && -f "$OVERRIDE_FILE" ]]; then
    echo "Checking $OVERRIDE_FILE for required variables and valid values..."

    # Extract NG_SERVER_NAME
    NG_SERVER_NAME=$(grep NG_SERVER_NAME "$OVERRIDE_FILE" | head -1 | sed 's/.*NG_SERVER_NAME=//;s/"//g' | xargs)
    if [[ -z "$NG_SERVER_NAME" || "$NG_SERVER_NAME" == "\${HOST_NAME}" || "$NG_SERVER_NAME" == '${HOST_NAME}' ]]; then
        ERRORS+=("ERROR: NG_SERVER_NAME must be set to a real value in $OVERRIDE_FILE (not left as \${HOST_NAME})")
    else
        echo "NG_SERVER_NAME: $NG_SERVER_NAME"
    fi

    # Extract IRIUS_EXT_URL
    IRIUS_EXT_URL=$(grep IRIUS_EXT_URL "$OVERRIDE_FILE" | head -1 | sed 's/.*IRIUS_EXT_URL=//;s/"//g' | xargs)
    if [[ -z "$IRIUS_EXT_URL" || "$IRIUS_EXT_URL" == *'${HOST_NAME}'* ]]; then
        ERRORS+=("ERROR: IRIUS_EXT_URL must be set to a real value in $OVERRIDE_FILE (not left as \${HOST_NAME})")
    else
        echo "IRIUS_EXT_URL: $IRIUS_EXT_URL"
    fi

    # Extract IRIUS_DB_URL
    IRIUS_DB_URL=$(grep IRIUS_DB_URL "$OVERRIDE_FILE" | head -1 | sed 's/.*IRIUS_DB_URL=//;s/"//g' | xargs)
    POSTGRES_VALUES_FILLED=1

    if [[ -z "$IRIUS_DB_URL" ]]; then
        ERRORS+=("ERROR: IRIUS_DB_URL must be set in $OVERRIDE_FILE")
        POSTGRES_VALUES_FILLED=0
    elif [[ "$IRIUS_DB_URL" == *'${POSTGRES_IP}'* || "$IRIUS_DB_URL" == *'${POSTGRES_PASSWORD}'* ]]; then
        ERRORS+=("ERROR: IRIUS_DB_URL must be filled in with real Postgres IP and password, not left as template variables in $OVERRIDE_FILE")
        POSTGRES_VALUES_FILLED=0
    else
        echo "IRIUS_DB_URL: $IRIUS_DB_URL"
    fi

else
    if [[ -n "$OVERRIDE_FILE" ]]; then
        ERRORS+=("ERROR: $OVERRIDE_FILE not found (required for custom config)")
    fi
fi

# --- SAML checks ---
if [[ -n "$SAML_FILE" && -f "$SAML_FILE" ]]; then
    echo "Checking $SAML_FILE for required variables and valid values..."

    # Extract and validate KEYSTORE_PASSWORD
    SAML_KEYSTORE_PASSWORD=$(grep KEYSTORE_PASSWORD "$SAML_FILE" | head -1 | sed 's/.*KEYSTORE_PASSWORD=//;s/"//g' | xargs)
    if [[ -z "$SAML_KEYSTORE_PASSWORD" || "$SAML_KEYSTORE_PASSWORD" == "\${KEYSTORE_PASSWORD}" || "$SAML_KEYSTORE_PASSWORD" == '${KEYSTORE_PASSWORD}' ]]; then
        ERRORS+=("ERROR: KEYSTORE_PASSWORD must be set to a real value in $SAML_FILE (not left as \${KEYSTORE_PASSWORD})")
    else
        echo "KEYSTORE_PASSWORD set in $SAML_FILE"
    fi

    # Extract and validate KEY_ALIAS_PASSWORD
    SAML_KEY_ALIAS_PASSWORD=$(grep KEY_ALIAS_PASSWORD "$SAML_FILE" | head -1 | sed 's/.*KEY_ALIAS_PASSWORD=//;s/"//g' | xargs)
    if [[ -z "$SAML_KEY_ALIAS_PASSWORD" || "$SAML_KEY_ALIAS_PASSWORD" == "\${KEY_ALIAS_PASSWORD}" || "$SAML_KEY_ALIAS_PASSWORD" == '${KEY_ALIAS_PASSWORD}' ]]; then
        ERRORS+=("ERROR: KEY_ALIAS_PASSWORD must be set to a real value in $SAML_FILE (not left as \${KEY_ALIAS_PASSWORD})")
    else
        echo "KEY_ALIAS_PASSWORD set in $SAML_FILE"
    fi
fi

# Only run connectivity check if values are filled (not default)
if [[ $POSTGRES_VALUES_FILLED -eq 1 ]]; then
    # Try to extract host and password for testing connectivity
    DB_IP=$(echo "$IRIUS_DB_URL" | sed -n 's/.*jdbc:postgresql:\/\/\([^:/]*\).*/\1/p')
    DB_PASS=$(echo "$IRIUS_DB_URL" | sed -n 's/.*password=\([^& ]*\).*/\1/p')
    if [[ -n "$DB_IP" && -n "$DB_PASS" ]]; then
        if command -v psql &>/dev/null; then
            if PGPASSWORD="$DB_PASS" psql -h "$DB_IP" -U iriusrisk -c '\q' 2>/dev/null; then
                echo "Postgres connection to $DB_IP OK"
            else
                ERRORS+=("ERROR: Could not connect to Postgres at $DB_IP with supplied password (check Postgres service, IP, and credentials)")
            fi
        else
            ERRORS+=("ERROR: 'psql' client is not installed (needed for preflight check of Postgres connectivity)")
        fi
    else
        ERRORS+=("ERROR: Could not parse DB_IP or DB_PASS from IRIUS_DB_URL in $OVERRIDE_FILE")
    fi
else
    echo "Postgres connectivity check skipped due to unmodified IRIUS_DB_URL."
fi

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
