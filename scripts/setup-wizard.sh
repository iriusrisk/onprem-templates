#!/usr/bin/env bash
source functions.sh
set -e

init_logging "$0"

echo "IriusRisk On-Premise Interactive Setup Wizard"
echo "--------------------------------------------"

# —————————————————————————————————————————————————————————————
# Decide which container engine to use (passed-in or standalone)
# —————————————————————————————————————————————————————————————
prompt_engine

# —————————————————————————————————————————————————————————————
# Set override paths once, for downstream logic
# —————————————————————————————————————————————————————————————
OVERRIDE_FILE="../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.override.yml"
JEFF_FILE="../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.jeff.yml"
COMPOSE_FILE="../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.yml"

# —————————————————————————————————————————————————————————————
# Prompt for key values (with validation)
# —————————————————————————————————————————————————————————————
HOST_NAME=$(prompt_nonempty "Enter the public hostname for your IriusRisk instance (HOST_NAME, e.g. iriusrisk.example.com)")

# Properly escape protocol colon in IRIUS_EXT_URL
IRIUS_EXT_URL="https\\\\://$HOST_NAME"

prompt_jeff_config

# —————————————————————————————————————————————————————————————
# Build JDBC_URL
# —————————————————————————————————————————————————————————————

if [[ $CONTAINER_ENGINE == "docker" ]]; then
	JDBC_URL="jdbc\\:postgresql\\://$DB_IP\\:5432/iriusprod?user\\=iriusprod&password\\=$DB_PASS"
elif [[ $CONTAINER_ENGINE == "podman" ]]; then
	JDBC_URL="jdbc\\:postgresql\\://$DB_IP\\:5432/iriusprod?user\\=iriusprod"
fi

# —————————————————————————————————————————————————————————————
# Safely update override file & generate certificates
# —————————————————————————————————————————————————————————————

update_base_override_env "$OVERRIDE_FILE" "$HOST_NAME" "$IRIUS_EXT_URL" "$JDBC_URL"

if [[ $JEFF_ENABLED == "y" ]]; then
	enable_jeff_override_env "$OVERRIDE_FILE"
fi

configure_jeff_file "$JEFF_FILE"

create_certificates "$HOST_NAME"

# —————————————————————————————————————————————————————————————
# Summary
# —————————————————————————————————————————————————————————————
echo
echo "--------------------------------------------"
echo "Setup complete. Summary of your values:"
echo "Container engine:      $CONTAINER_ENGINE"
echo "Host name:             $HOST_NAME"
echo "Postgres host/IP:      $DB_IP"
echo "Postgres password:     [set]"
echo "Override file:         $OVERRIDE_FILE"
if [[ $JEFF_ENABLED == "y" ]]; then
	echo "Jeff file:             $JEFF_FILE"
fi
echo
echo "You can rerun this wizard to update your settings anytime."
