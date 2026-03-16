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

if [[ $JEFF_ENABLED == "y" ]]; then
	AZURE_ENDPOINT=$(prompt_nonempty "Enter the Azure endpoint for Jeff AI assistant")
	AZURE_API_KEY=$(prompt_nonempty "Enter the Azure API key for Jeff AI assistant")
	GEMINI_ENDPOINT=$(prompt_nonempty "Enter the Gemini endpoint for Jeff AI assistant")
	GEMINI_API_KEY=$(prompt_nonempty "Enter the Gemini API key for Jeff AI assistant")
fi

# —————————————————————————————————————————————————————————————
# Build JDBC_URL
# —————————————————————————————————————————————————————————————

if [[ $CONTAINER_ENGINE == "docker" ]]; then
	# Properly escape JDBC URL for YAML
	JDBC_URL="jdbc\\:postgresql\\://$DB_IP\\:5432/iriusprod?user\\=iriusprod&password\\=$DB_PASS"
elif [[ $CONTAINER_ENGINE == "podman" ]]; then
	JDBC_URL="jdbc\\:postgresql\\://$DB_IP\\:5432/iriusprod?user\\=iriusprod"
fi

# —————————————————————————————————————————————————————————————
# Safely update override file & generate certificates
# —————————————————————————————————————————————————————————————

if [[ ! -f $OVERRIDE_FILE ]]; then
	echo "ERROR: $OVERRIDE_FILE not found. Please ensure you have cloned the repo and have the override template."
	exit 1
fi

if [[ $JEFF_ENABLED == "y" && ! -f $JEFF_FILE ]]; then
	echo "ERROR: $JEFF_FILE not found. Please ensure you have cloned the repo and have the Jeff template."
	exit 1
fi

# Update NG_SERVER_NAME (replace any occurrence)
sed -i "s|NG_SERVER_NAME=.*|NG_SERVER_NAME=$HOST_NAME|g" "$OVERRIDE_FILE"
# Update IRIUS_EXT_URL (replace \${HOST_NAME} or any existing value)
sed -i "s|IRIUS_EXT_URL=.*|IRIUS_EXT_URL=$IRIUS_EXT_URL|g" "$OVERRIDE_FILE"
# Remove existing IRIUS_DB_URL line (escaped or not)
sed -i '/^[[:space:]]*-[[:space:]]*IRIUS_DB_URL=/d' "$OVERRIDE_FILE"

# Remove existing DB/Jeff-related lines
sed -i '/^[[:space:]]*-[[:space:]]*IRIUS_DB_URL=/d' "$OVERRIDE_FILE"
sed -i '/^[[:space:]]*-[[:space:]]*IRIUS_AI_URL=/d' "$OVERRIDE_FILE"
sed -i '/^[[:space:]]*-[[:space:]]*IRIUS_AI_ASH_URL=/d' "$OVERRIDE_FILE"
sed -i '/^[[:space:]]*-[[:space:]]*IRIUS_AI_HAVEN_URL=/d' "$OVERRIDE_FILE"

awk -v db_url="      - IRIUS_DB_URL=$JDBC_URL" -v jeff_enabled="$JEFF_ENABLED" '
  BEGIN {tomcat=0}
  /tomcat:/ {print; tomcat=1; next}
  tomcat && /environment:/ {
      print
      print db_url
      if (jeff_enabled == "y") {
          print "      - IRIUS_AI_URL=http://jeff:8008"
          print "      - IRIUS_AI_ASH_URL=http://ash:8009"
          print "      - IRIUS_AI_HAVEN_URL=http://haven:8012"
      }
      tomcat=0
      next
  }
  {print}
' "$OVERRIDE_FILE" >"${OVERRIDE_FILE}.tmp" && mv "${OVERRIDE_FILE}.tmp" "$OVERRIDE_FILE"

echo "Updated $OVERRIDE_FILE"

if [[ $JEFF_ENABLED == "y" ]]; then
	echo "Generating random Redis password for Jeff setup."
	REDIS_PASSWORD="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"
	echo "Updating $JEFF_FILE"

	# Endpoints remain in the compose file for both engines.
	sed -i "s|AZURE_ENDPOINT=.*|AZURE_ENDPOINT=$AZURE_ENDPOINT|g" "$JEFF_FILE"
	sed -i "s|AZURE_OPENAI_ENDPOINT=.*|AZURE_OPENAI_ENDPOINT=$AZURE_ENDPOINT|g" "$JEFF_FILE"
	sed -i "s|GEMINI_API_BASE=.*|GEMINI_API_BASE=$GEMINI_ENDPOINT|g" "$JEFF_FILE"

	if [[ $CONTAINER_ENGINE == "docker" ]]; then
		# Docker keeps credentials in the compose file as before.
		sed -i "s|AZURE_API_KEY=.*|AZURE_API_KEY=$AZURE_API_KEY|g" "$JEFF_FILE"
		sed -i "s|AZURE_OPENAI_API_KEY=.*|AZURE_OPENAI_API_KEY=$AZURE_API_KEY|g" "$JEFF_FILE"
		sed -i "s|GEMINI_API_KEY=.*|GEMINI_API_KEY=$GEMINI_API_KEY|g" "$JEFF_FILE"

		escaped_redis_password=$(printf '%s\n' "$REDIS_PASSWORD" | sed 's/[&/\]/\\&/g')
		sed -i "s|\"\${REDIS_PASSWORD}\"|\"$escaped_redis_password\"|g" "$JEFF_FILE"
		sed -i "s|\${REDIS_PASSWORD}|$escaped_redis_password|g" "$JEFF_FILE"
	else
		# Podman stores sensitive values as Podman secrets, not in compose.
		sed -i '/AZURE_API_KEY=/d' "$JEFF_FILE"
		sed -i '/AZURE_OPENAI_API_KEY=/d' "$JEFF_FILE"
		sed -i '/GEMINI_API_KEY=/d' "$JEFF_FILE"
		sed -i '/REDIS_PASSWORD=/d' "$JEFF_FILE"

		encrypt_and_store_secret "$AZURE_API_KEY" "azure_api_key" "azure_api_privkey"
		encrypt_and_store_secret "$GEMINI_API_KEY" "gemini_api_key" "gemini_api_privkey"
		encrypt_and_store_secret "$REDIS_PASSWORD" "redis_password" "redis_privkey"
	fi

	echo "Updated $JEFF_FILE"
fi

create_certificates $HOST_NAME

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
