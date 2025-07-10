#!/usr/bin/env bash

echo "Welcome to the IriusRisk On-Premise Interactive Setup Wizard"
echo "-----------------------------------------------------------"

# Ask for Docker or Podman
read -rp "Are you deploying with Docker or Podman? (docker/podman): " STACK_TYPE

if [[ "$STACK_TYPE" =~ ^[Dd]ocker ]]; then
    OVERRIDE_FILE="../docker/docker-compose.override.yml"
    SAML_FILE="../docker/docker-compose.saml.yml"
elif [[ "$STACK_TYPE" =~ ^[Pp]odman ]]; then
    OVERRIDE_FILE="../podman/container-compose.override.yml"
    SAML_FILE="../podman/container-compose.saml.yml"
else
    echo "Invalid option. Please run the script again and enter either 'docker' or 'podman'."
    exit 1
fi

# Prompt for host name only
read -rp "Enter the public hostname for your IriusRisk instance (HOST_NAME, e.g. iriusrisk.example.com): " HOST_NAME

# Internal or external Postgres
read -rp "Do you want to use an internal Postgres container? (y/n): " USE_INTERNAL_PG
if [[ "$USE_INTERNAL_PG" =~ ^[Yy] ]]; then
    DB_IP="postgres"
else
    read -rp "Enter the Postgres IP address (DB host): " DB_IP
fi

read -rp "Enter the Postgres password: " DB_PASS

# Properly escape JDBC URL for YAML
JDBC_URL="jdbc\\:postgresql\\://$DB_IP\\:5432/iriusprod?user\\=iriusprod&password\\=$DB_PASS"

# Properly escape protocol colon in IRIUS_EXT_URL
IRIUS_EXT_URL="https\\\\://$HOST_NAME"

# SAML setup
read -rp "Do you want to enable SAML support? (y/n): " ENABLE_SAML
if [[ "$ENABLE_SAML" =~ ^[Yy] ]]; then
    read -rp "Enter SAML keystore password (KEYSTORE_PASSWORD): " SAML_KEYSTORE_PASSWORD
    read -rp "Enter SAML key alias password (KEY_ALIAS_PASSWORD): " SAML_KEY_ALIAS_PASSWORD
fi

# --- Safely update docker/podman override file ---
if [[ ! -f "$OVERRIDE_FILE" ]]; then
    echo "ERROR: $OVERRIDE_FILE not found. Please ensure you have cloned the repo and have the override template."
    exit 1
fi

# Update NG_SERVER_NAME (replace any occurrence)
sed -i "s|NG_SERVER_NAME=.*|NG_SERVER_NAME=$HOST_NAME|g" "$OVERRIDE_FILE"

# Update IRIUS_EXT_URL (replace ${HOST_NAME} or any existing value)
sed -i "s|IRIUS_EXT_URL=.*|IRIUS_EXT_URL=$IRIUS_EXT_URL|g" "$OVERRIDE_FILE"

# Remove existing IRIUS_DB_URL line (escaped or not)
sed -i '/IRIUS_DB_URL=/d' "$OVERRIDE_FILE"
# Insert a correct line after 'environment:' under tomcat:
awk -v db_url="      - IRIUS_DB_URL=$JDBC_URL" '
    BEGIN {tomcat=0}
    /tomcat:/ {print; tomcat=1; next}
    tomcat && /environment:/ {
        print
        print db_url
        tomcat=0
        next
    }
    {print}
' "$OVERRIDE_FILE" > "${OVERRIDE_FILE}.tmp" && mv "${OVERRIDE_FILE}.tmp" "$OVERRIDE_FILE"

echo "Updated $OVERRIDE_FILE"

# --- Safely update SAML override if enabled ---
if [[ "$ENABLE_SAML" =~ ^[Yy] ]]; then
    if [[ ! -f "$SAML_FILE" ]]; then
        echo "ERROR: $SAML_FILE not found. Please ensure you have the SAML override template."
        exit 1
    fi
    # Replace or insert KEYSTORE_PASSWORD and KEY_ALIAS_PASSWORD under the tomcat environment:
    if grep -q 'KEYSTORE_PASSWORD=' "$SAML_FILE"; then
        sed -i "s|KEYSTORE_PASSWORD=.*|KEYSTORE_PASSWORD=$SAML_KEYSTORE_PASSWORD|g" "$SAML_FILE"
    else
        # Insert under 'environment:' for tomcat
        awk -v newvar="      - KEYSTORE_PASSWORD=$SAML_KEYSTORE_PASSWORD" '
            BEGIN {in_env=0; in_tomcat=0}
            /tomcat:/ {print; in_tomcat=1; next}
            in_tomcat && /environment:/ {print; print newvar; in_env=1; in_tomcat=0; next}
            {print}
        ' "$SAML_FILE" > "${SAML_FILE}.tmp" && mv "${SAML_FILE}.tmp" "$SAML_FILE"
    fi
    if grep -q 'KEY_ALIAS_PASSWORD=' "$SAML_FILE"; then
        sed -i "s|KEY_ALIAS_PASSWORD=.*|KEY_ALIAS_PASSWORD=$SAML_KEY_ALIAS_PASSWORD|g" "$SAML_FILE"
    else
        awk -v newvar="      - KEY_ALIAS_PASSWORD=$SAML_KEY_ALIAS_PASSWORD" '
            BEGIN {in_env=0; in_tomcat=0}
            /tomcat:/ {print; in_tomcat=1; next}
            in_tomcat && /environment:/ {print; print newvar; in_env=1; in_tomcat=0; next}
            {print}
        ' "$SAML_FILE" > "${SAML_FILE}.tmp" && mv "${SAML_FILE}.tmp" "$SAML_FILE"
    fi
    echo "Updated $SAML_FILE"
else
    echo "Skipping SAML override file as SAML is not enabled."
fi

# --- Summary ---
echo
echo "--------------------------------------"
echo "Setup complete. Summary of your values:"
echo "Deployment stack:     $STACK_TYPE"
echo "HOST_NAME:            $HOST_NAME"
echo "Postgres host/IP:     $DB_IP"
echo "Postgres password:    [set]"
echo "Override file:        $OVERRIDE_FILE"
if [[ "$ENABLE_SAML" =~ ^[Yy] ]]; then
    echo "SAML enabled:         yes"
    echo "KEYSTORE_PASSWORD:    [set]"
    echo "KEY_ALIAS_PASSWORD:   [set]"
    echo "SAML override file:   $SAML_FILE"
else
    echo "SAML enabled:         no"
fi
echo
echo "You can rerun this wizard to update your settings anytime."