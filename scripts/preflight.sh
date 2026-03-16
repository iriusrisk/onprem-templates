#!/usr/bin/env bash
source functions.sh

init_logging "$0"

# —————————————————————————————————————————————————————————————
# Set static variables
# —————————————————————————————————————————————————————————————
echo "IriusRisk On-Prem Preflight Check"
echo "----------------------------------"

REQUIRED_DOCKER="20.10.0"
REQUIRED_DOCKER_COMPOSE="1.29.0"
REQUIRED_PODMAN="5.0.0"
REQUIRED_JAVA="17"

ERRORS=()
WARNINGS=()

# —————————————————————————————————————————————————————————————
# Decide on container engine & set compose locations
# —————————————————————————————————————————————————————————————
prompt_engine

OVERRIDE_FILE="../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.override.yml"
COMPOSE_FILE="../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.yml"
JEFF_FILE="../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.jeff.yml"

# —————————————————————————————————————————————————————————————
# Check OS type
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
# Check for git and global git config
# —————————————————————————————————————————————————————————————
if [ "$OFFLINE" -eq 0 ]; then
	if command -v git &>/dev/null; then
		echo "git found."
		GIT_NAME=$(git config --global user.name)
		if [[ -z $GIT_NAME ]]; then
			msg="WARNING: git user.name is not set globally. Use: git config --global user.name 'Your Name'"
			echo "$msg"
			WARNINGS+=("$msg")
		else
			echo "git user.name: $GIT_NAME"
		fi
		GIT_EMAIL=$(git config --global user.email)
		if [[ -z $GIT_EMAIL ]]; then
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
fi
# —————————————————————————————————————————————————————————————
# Check chosen engine and versions
# —————————————————————————————————————————————————————————————
case "$CONTAINER_ENGINE" in
	docker)
		if command -v docker &>/dev/null; then
			echo "Docker found."
			check_version docker "$REQUIRED_DOCKER"
			if command -v docker-compose &>/dev/null; then
				check_version docker-compose "$REQUIRED_DOCKER_COMPOSE"
			else
				msg="ERROR: 'docker-compose' is not installed."
				echo "$msg"
				ERRORS+=("$msg")
			fi
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
			if ! command -v podman-compose &>/dev/null; then
				msg="ERROR: 'podman-compose' is not installed."
				echo "$msg"
				ERRORS+=("$msg")
			fi
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
# Check dependencies
# —————————————————————————————————————————————————————————————
if command -v java &>/dev/null; then
	JAVA_FULL_VER=$(java -version 2>&1 | head -n 1)
	JAVA_VER=$(echo "$JAVA_FULL_VER" | grep -oE '[0-9]+' | head -n1)
	if [[ -z $JAVA_VER ]]; then
		msg="ERROR: Could not parse Java version from \"$JAVA_FULL_VER\""
		echo "$msg"
		ERRORS+=("$msg")
	elif ((JAVA_VER < REQUIRED_JAVA)); then
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

if command -v psql &>/dev/null; then
	echo "psql found."
else
	msg="ERROR: psql is not installed"
	echo "$msg"
	ERRORS+=("$msg")
fi

if command -v jq &>/dev/null; then
	echo "jq found."
else
	msg="ERROR: jq is not installed"
	echo "$msg"
	ERRORS+=("$msg")
fi

# —————————————————————————————————————————————————————————————
# Check required local certificate/key files
# —————————————————————————————————————————————————————————————
echo "Checking required local certificate/key files..."
for f in cert.pem key.pem ec_private.pem; do
	check_file "../$CONTAINER_ENGINE/$f"
done

# —————————————————————————————————————————————————————————————
# Check override files for required variables and valid values
# —————————————————————————————————————————————————————————————
POSTGRES_VALUES_FILLED=1
JEFF_VALUES_FILLED=1

if [[ -n $OVERRIDE_FILE && -f $OVERRIDE_FILE ]]; then
	echo "Checking $OVERRIDE_FILE for required variables and valid values..."

	NG_SERVER_NAME=$(grep 'NG_SERVER_NAME=' "$OVERRIDE_FILE" | head -1 | sed 's/.*NG_SERVER_NAME=//;s/"//g' | xargs)
	if [[ -z $NG_SERVER_NAME || $NG_SERVER_NAME == '${HOST_NAME}' ]]; then
		msg="WARNING: NG_SERVER_NAME must be set to a real value in $OVERRIDE_FILE (not left as \${HOST_NAME})"
		echo "$msg"
		WARNINGS+=("$msg")
	else
		echo "NG_SERVER_NAME: $NG_SERVER_NAME"
	fi

	IRIUS_EXT_URL=$(grep 'IRIUS_EXT_URL=' "$OVERRIDE_FILE" | head -1 | sed 's/.*IRIUS_EXT_URL=//;s/"//g' | xargs)
	if [[ -z $IRIUS_EXT_URL || $IRIUS_EXT_URL == *'${HOST_NAME}'* ]]; then
		msg="WARNING: IRIUS_EXT_URL must be set to a real value in $OVERRIDE_FILE (not left as \${HOST_NAME})"
		echo "$msg"
		WARNINGS+=("$msg")
	else
		echo "IRIUS_EXT_URL: $IRIUS_EXT_URL"
	fi

	IRIUS_DB_URL=$(grep 'IRIUS_DB_URL=' "$OVERRIDE_FILE" | head -1 | sed 's/.*IRIUS_DB_URL=//;s/"//g' | xargs)
	if [[ -z $IRIUS_DB_URL ]]; then
		msg="WARNING: IRIUS_DB_URL must be set in $OVERRIDE_FILE"
		echo "$msg"
		WARNINGS+=("$msg")
		POSTGRES_VALUES_FILLED=0
	elif [[ $CONTAINER_ENGINE == "docker" && ($IRIUS_DB_URL == *'${POSTGRES_IP}'* || $IRIUS_DB_URL == *'${POSTGRES_PASSWORD}'*) ]]; then
		msg="WARNING: IRIUS_DB_URL must be filled in with real Postgres IP and password, not left as template variables in $OVERRIDE_FILE"
		echo "$msg"
		WARNINGS+=("$msg")
		POSTGRES_VALUES_FILLED=0
	else
		echo "IRIUS_DB_URL: $IRIUS_DB_URL"
	fi
else
	msg="WARNING: $OVERRIDE_FILE not found (required for custom config)"
	echo "$msg"
	WARNINGS+=("$msg")
	POSTGRES_VALUES_FILLED=0
fi

if [[ $JEFF_ENABLED == "y" ]]; then
	if [[ -n $JEFF_FILE && -f $JEFF_FILE ]]; then
		echo "Checking $JEFF_FILE for required Jeff variables and valid values..."

		AZURE_ENDPOINT_VALUE=$(grep 'AZURE_ENDPOINT=' "$JEFF_FILE" | head -1 | sed 's/.*AZURE_ENDPOINT=//;s/"//g' | xargs)
		if [[ -z $AZURE_ENDPOINT_VALUE || $AZURE_ENDPOINT_VALUE == '${AZURE_ENDPOINT}' ]]; then
			msg="WARNING: AZURE_ENDPOINT must be set to a real value in $JEFF_FILE when Jeff is enabled"
			echo "$msg"
			WARNINGS+=("$msg")
			JEFF_VALUES_FILLED=0
		else
			echo "AZURE_ENDPOINT: $AZURE_ENDPOINT_VALUE"
		fi

		GEMINI_ENDPOINT_VALUE=$(grep 'GEMINI_API_BASE=' "$JEFF_FILE" | head -1 | sed 's/.*GEMINI_API_BASE=//;s/"//g' | xargs)
		if [[ -z $GEMINI_ENDPOINT_VALUE || $GEMINI_ENDPOINT_VALUE == '${GEMINI_API_BASE}' ]]; then
			msg="WARNING: GEMINI_API_BASE must be set to a real value in $JEFF_FILE when Jeff is enabled"
			echo "$msg"
			WARNINGS+=("$msg")
			JEFF_VALUES_FILLED=0
		else
			echo "GEMINI_API_BASE: $GEMINI_ENDPOINT_VALUE"
		fi

		if [[ $CONTAINER_ENGINE == "podman" ]]; then
			AZURE_API_KEY_VALUE="$(read_podman_secret_plaintext azure_api_key || true)"
			GEMINI_API_KEY_VALUE="$(read_podman_secret_plaintext gemini_api_key || true)"
			REDIS_PASSWORD_VALUE="$(read_podman_secret_plaintext redis_password || true)"

			if [[ -z $AZURE_API_KEY_VALUE ]]; then
				msg="WARNING: Podman secret 'azure_api_key' must exist and be readable when Jeff is enabled"
				echo "$msg"
				WARNINGS+=("$msg")
				JEFF_VALUES_FILLED=0
			else
				echo "azure_api_key Podman secret is set"
			fi

			if [[ -z $GEMINI_API_KEY_VALUE ]]; then
				msg="WARNING: Podman secret 'gemini_api_key' must exist and be readable when Jeff is enabled"
				echo "$msg"
				WARNINGS+=("$msg")
				JEFF_VALUES_FILLED=0
			else
				echo "gemini_api_key Podman secret is set"
			fi

			if [[ -z $REDIS_PASSWORD_VALUE ]]; then
				msg="WARNING: Podman secret 'redis_password' must exist and be readable when Jeff is enabled"
				echo "$msg"
				WARNINGS+=("$msg")
				JEFF_VALUES_FILLED=0
			else
				echo "redis_password Podman secret is set"
			fi
		else
			AZURE_API_KEY_VALUE=$(grep 'AZURE_API_KEY=' "$JEFF_FILE" | head -1 | sed 's/.*AZURE_API_KEY=//;s/"//g' | xargs)
			if [[ -z $AZURE_API_KEY_VALUE || $AZURE_API_KEY_VALUE == '${AZURE_API_KEY}' ]]; then
				msg="WARNING: AZURE_API_KEY must be set to a real value in $JEFF_FILE when Jeff is enabled"
				echo "$msg"
				WARNINGS+=("$msg")
				JEFF_VALUES_FILLED=0
			else
				echo "AZURE_API_KEY is set"
			fi

			GEMINI_API_KEY_VALUE=$(grep 'GEMINI_API_KEY=' "$JEFF_FILE" | head -1 | sed 's/.*GEMINI_API_KEY=//;s/"//g' | xargs)
			if [[ -z $GEMINI_API_KEY_VALUE || $GEMINI_API_KEY_VALUE == '${GEMINI_API_KEY}' ]]; then
				msg="WARNING: GEMINI_API_KEY must be set to a real value in $JEFF_FILE when Jeff is enabled"
				echo "$msg"
				WARNINGS+=("$msg")
				JEFF_VALUES_FILLED=0
			else
				echo "GEMINI_API_KEY is set"
			fi

			REDIS_PASSWORD_VALUE=$(grep 'REDIS_PASSWORD=' "$JEFF_FILE" | head -1 | sed 's/.*REDIS_PASSWORD=//;s/"//g' | xargs)
			if [[ -z $REDIS_PASSWORD_VALUE || $REDIS_PASSWORD_VALUE == '${REDIS_PASSWORD}' ]]; then
				msg="WARNING: REDIS_PASSWORD must be set to a real value in $JEFF_FILE when Jeff is enabled"
				echo "$msg"
				WARNINGS+=("$msg")
				JEFF_VALUES_FILLED=0
			else
				echo "REDIS_PASSWORD is set"
			fi
		fi
	else
		msg="WARNING: $JEFF_FILE not found (required when Jeff is enabled)"
		echo "$msg"
		WARNINGS+=("$msg")
		JEFF_VALUES_FILLED=0
	fi
fi

# —————————————————————————————————————————————————————————————
# Postgres connectivity check (if applicable)
# —————————————————————————————————————————————————————————————
if [[ $POSTGRES_VALUES_FILLED -eq 1 ]]; then
	if [[ $DB_IP == "postgres" ]]; then
		DB_IP="localhost"
	fi
	if PGPASSWORD="$DB_PASS" psql -h "$DB_IP" -U iriusprod -c '\q' 2>/dev/null; then
		echo "Postgres connection to $DB_IP OK"
	else
		msg="ERROR: Could not connect to Postgres at $DB_IP with supplied password (check Postgres service, IP, and credentials)"
		echo "$msg"
		ERRORS+=("$msg")
	fi
else
	echo "Postgres connectivity check skipped due to unmodified IRIUS_DB_URL."
fi

# —————————————————————————————————————————————————————————————
# Jeff connectivity check (if applicable)
# —————————————————————————————————————————————————————————————

echo "DEBUG: JEFF_ENABLED=[$JEFF_ENABLED]"
echo "DEBUG: AZURE_ENDPOINT=[$AZURE_ENDPOINT_VALUE]"
echo "DEBUG: GEMINI_ENDPOINT=[$GEMINI_ENDPOINT_VALUE]"
echo "DEBUG: AZURE_API_KEY set? [$([[ -n $AZURE_API_KEY_VALUE ]] && echo yes || echo no)]"
echo "DEBUG: GEMINI_API_KEY set? [$([[ -n $GEMINI_API_KEY_VALUE ]] && echo yes || echo no)]"

if [[ $JEFF_ENABLED == "y" && $JEFF_VALUES_FILLED -eq 1 ]]; then
	echo "Checking Azure and Gemini API connectivity..."
	check_gemini_api "$GEMINI_ENDPOINT_VALUE" "$GEMINI_API_KEY_VALUE"
	check_azure_endpoint "$AZURE_ENDPOINT_VALUE" "$AZURE_API_KEY_VALUE"
else
	echo "Azure/Gemini connectivity checks skipped."
fi

# —————————————————————————————————————————————————————————————
# Print summary report
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
