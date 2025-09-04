#!/usr/bin/env bash
source functions.sh
set -e

init_logging "$0"

echo "IriusRisk On-Premise Interactive Setup Wizard"
echo "--------------------------------------------"

# —————————————————————————————————————————————————————————————
# 0. Decide which container engine to use (passed-in or standalone)
# —————————————————————————————————————————————————————————————
prompt_engine

# —————————————————————————————————————————————————————————————
# 1. Set override & SAML-file paths once, for downstream logic
# —————————————————————————————————————————————————————————————
OVERRIDE_FILE="../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.override.yml"
COMPOSE_FILE="../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.yml"
SAML_FILE="../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.saml.yml"

# —————————————————————————————————————————————————————————————
# 2. Prompt for key values (with validation)
# —————————————————————————————————————————————————————————————
HOST_NAME=$(prompt_nonempty "Enter the public hostname for your IriusRisk instance (HOST_NAME, e.g. iriusrisk.example.com)")

# Internal or external Postgres
if [[ -n "$USE_INTERNAL_PG" ]]; then
    echo "Using internal Postgres setting: $USE_INTERNAL_PG"
else
    USE_INTERNAL_PG=$(prompt_yn "Do you want to use an internal Postgres container")
fi

if [[ "$USE_INTERNAL_PG" == "y" ]]; then
    DB_IP="postgres"
else
    # Use DB_IP from env if set (for local install), otherwise prompt
    if [[ -n "$DB_IP" ]]; then
        echo "Using Postgres IP address from environment: $DB_IP"
    else
        DB_IP=$(prompt_nonempty "Enter the Postgres IP address (DB host)")
    fi
fi

# Use DB_PASS from env if set (for local install), otherwise prompt
if [[ -n "$DB_PASS" ]]; then
    echo "Using Postgres password from environment."
else
    DB_PASS=$(prompt_nonempty "Enter the Postgres password")
    encrypt_and_store_secret "$DB_PASS" "db_pwd" "db_privkey"
fi

# Properly escape JDBC URL for YAML
JDBC_URL="jdbc\\:postgresql\\://$DB_IP\\:5432/iriusprod?user\\=iriusprod&password\\=$DB_PASS"

# Properly escape protocol colon in IRIUS_EXT_URL
IRIUS_EXT_URL="https\\\\://$HOST_NAME"

# —————————————————————————————————————————————————————————————
# 3. Build JDBC_URL
# —————————————————————————————————————————————————————————————

if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
    # Properly escape JDBC URL for YAML
    JDBC_URL="jdbc\\:postgresql\\://$DB_IP\\:5432/iriusprod?user\\=iriusprod&password\\=$DB_PASS"
elif [[ "$CONTAINER_ENGINE" == "podman" ]]; then
    JDBC_URL="jdbc\\:postgresql\\://$DB_IP\\:5432/iriusprod?user\\=iriusprod"
fi

# —————————————————————————————————————————————————————————————
# 4. SAML setup
# —————————————————————————————————————————————————————————————
if [[ -n "$SAML_CHOICE" ]]; then
    ENABLE_SAML="$SAML_CHOICE"
    echo "SAML setup: Using value from one-click ('${SAML_CHOICE}')"
else
    ENABLE_SAML=$(prompt_yn "Do you want to enable SAML support")
fi

if [[ "$ENABLE_SAML" == "y" ]]; then
    SAML_KEYSTORE_PASSWORD=$(prompt_nonempty "Enter SAML keystore password (KEYSTORE_PASSWORD)")
    SAML_KEY_ALIAS_PASSWORD=$(prompt_nonempty "Enter SAML key alias password (KEY_ALIAS_PASSWORD)")
  if [[ "$CONTAINER_ENGINE" == "podman" ]]; then
    # Create encrypted secrets + privkeys
    podman secret rm keystore_pwd keystore_privkey key_alias_pwd key_alias_privkey 2>/dev/null || true
    encrypt_and_store_secret "$SAML_KEYSTORE_PASSWORD"  "keystore_pwd"   "keystore_privkey"
    encrypt_and_store_secret "$SAML_KEY_ALIAS_PASSWORD" "key_alias_pwd"  "key_alias_privkey"
  fi
fi
# —————————————————————————————————————————————————————————————
# 5. Safely update override file & generate certificates
# —————————————————————————————————————————————————————————————

if [[ ! -f "$OVERRIDE_FILE" ]]; then
    echo "ERROR: $OVERRIDE_FILE not found. Please ensure you have cloned the repo and have the override template."
    exit 1
fi

# Update NG_SERVER_NAME (replace any occurrence)
sed -i "s|NG_SERVER_NAME=.*|NG_SERVER_NAME=$HOST_NAME|g" "$OVERRIDE_FILE"
# Update IRIUS_EXT_URL (replace \${HOST_NAME} or any existing value)
sed -i "s|IRIUS_EXT_URL=.*|IRIUS_EXT_URL=$IRIUS_EXT_URL|g" "$OVERRIDE_FILE"
# Remove existing IRIUS_DB_URL line (escaped or not)
sed -i '/^[[:space:]]*-[[:space:]]*IRIUS_DB_URL=/d' "$OVERRIDE_FILE"
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

create_certificates $HOST_NAME

# —————————————————————————————————————————————————————————————
# 6. Safely update SAML override if enabled
# —————————————————————————————————————————————————————————————
if [[ "$ENABLE_SAML" == "y" ]]; then
  if [[ ! -f "$SAML_FILE" ]]; then
      echo "ERROR: $SAML_FILE not found. Please ensure you have the SAML override template."
      exit 1
  fi

  if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
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
    echo "Podman in use — skipping plaintext injection into $SAML_FILE"
  fi
else
    echo "Skipping SAML override file as SAML is not enabled."
fi

# —————————————————————————————————————————————————————————————
# 7. Summary
# —————————————————————————————————————————————————————————————
echo
echo "--------------------------------------------"
echo "Setup complete. Summary of your values:"
echo "Container engine:      $CONTAINER_ENGINE"
echo "Host name:             $HOST_NAME"
echo "Postgres host/IP:      $DB_IP"
echo "Postgres password:     [set]"
echo "Override file:         $OVERRIDE_FILE"
if [[ "$ENABLE_SAML" == "y" ]]; then
    echo "SAML enabled:          yes"
    echo "KEYSTORE_PASSWORD:     [set]"
    echo "KEY_ALIAS_PASSWORD:    [set]"
    echo "SAML override file:    $SAML_FILE"
else
    echo "SAML enabled:          no"
fi
echo
echo "You can rerun this wizard to update your settings anytime."
