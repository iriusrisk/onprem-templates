#!/usr/bin/env bash
source functions.sh

# Fail fast and propagate failures from pipelines, unset vars, and traps.
set -e -o pipefail

# Helpful error message
trap 'echo "ERROR: Script failed at line $LINENO"; exit 1' ERR

# Fallback for environments where $USER isn't set
if [[ -z ${USER:-} ]]; then
	USER="$(id -un)"
	export USER
fi

init_logging "$0"

# Offline mode setup

OFFLINE=0
OFFLINE_BUNDLE_DIR="${OFFLINE_BUNDLE_DIR:-./offline_bundle}"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--offline)
			OFFLINE=1
			shift
			;;
		--bundle)
			OFFLINE_BUNDLE_DIR="$2"
			shift 2
			;;
		*)
			ARGS+=("$1")
			shift
			;;
	esac
done
set -- "${ARGS[@]:-}"

export OFFLINE OFFLINE_BUNDLE_DIR

# —————————————————————————————————————————————————————————————
# Script Start
# —————————————————————————————————————————————————————————————
echo "IriusRisk Upgrade Deployment"
echo "---------------------------------------"

# —————————————————————————————————————————————————————————————
# Ensure we're in the scripts dir
# —————————————————————————————————————————————————————————————
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_PATH"

echo "Current directory: $(pwd)"
echo

# —————————————————————————————————————————————————————————————
# Set engine and Postgres options, update templates
# —————————————————————————————————————————————————————————————
prompt_engine

COMPOSE_TOOL="$CONTAINER_ENGINE-compose"
prompt_postgres_option upgrade

if [[ $POSTGRES_SETUP_OPTION == "1" ]]; then
	USE_INTERNAL_PG="y"
else
	USE_INTERNAL_PG="n"
fi

# SAML will be determined later based on version boundary & file existence.
SAML_ENABLED=""

# Compose dir (used for SAML file detection and compose editing)
COMPOSE_DIR="$SCRIPT_PATH/../$CONTAINER_ENGINE"

# —————————————————————————————————————————————————————————————
# Pre-upgrade health/version (best-effort)
# —————————————————————————————————————————————————————————————
PREV_VERSION="unknown"
read -r pre_code pre_json < <(fetch_health)
if [[ $pre_code == "200" && -n $pre_json ]]; then
	PREV_VERSION="$(printf '%s' "$pre_json" | extract_version_from_json)"
fi
printf '%s\n' "$PREV_VERSION" >/tmp/iriusrisk_previous_version.txt || true
echo "Detected current IriusRisk version (pre-upgrade): $PREV_VERSION"

prompt_registry_settings

# —————————————————————————————————————————————————————————————
# Backup service
# —————————————————————————————————————————————————————————————

BDIR="${BDIR:-/home/$USER/irius_backups}"
mkdir -p "$BDIR"

case "$CONTAINER_ENGINE" in
	docker)
		UNIT_PATH="/etc/systemd/system/iriusrisk-docker.service"
		UNIT_BACKUP="$BDIR/iriusrisk-docker.service.pre-upgrade.bak"
		if [[ -f $UNIT_PATH ]]; then
			sudo cp "$UNIT_PATH" "$UNIT_BACKUP"
			echo "Backed up service unit: $UNIT_PATH -> $UNIT_BACKUP"
		else
			echo "WARNING: Service unit not found, nothing to back up: $UNIT_PATH"
		fi
		;;
	podman)
		UNIT_PATH="$HOME/.config/systemd/user/iriusrisk-podman.service"
		UNIT_BACKUP="$BDIR/iriusrisk-podman.service.pre-upgrade.bak"
		if [[ -f $UNIT_PATH ]]; then
			cp "$UNIT_PATH" "$UNIT_BACKUP"
			echo "Backed up service unit: $UNIT_PATH -> $UNIT_BACKUP"
		else
			echo "WARNING: Service unit not found, nothing to back up: $UNIT_PATH"
		fi
		;;
	*)
		echo "ERROR: Unsupported engine: $CONTAINER_ENGINE" >&2
		exit 1
		;;
esac

# —————————————————————————————————————————————————————————————
# Backup DB
# —————————————————————————————————————————————————————————————
backup_db

# —————————————————————————————————————————————————————————————
# Backup original compose files + certificates + SAML files (if any)
# —————————————————————————————————————————————————————————————
# Assumes: COMPOSE_DIR, BDIR, VERSION, TS set
TMP_COMPOSE_TAR="/tmp/irius.compose.$TS.tar.gz"
OUT_COMPOSE_TAR="$BDIR/irius.compose.$VERSION.tar.gz"

echo "Backing up contents of: $COMPOSE_DIR"

if [[ ! -d $COMPOSE_DIR ]]; then
	echo "ERROR: COMPOSE_DIR does not exist: $COMPOSE_DIR"
	exit 1
fi

# Create tar.gz, excluding the postgres directory if it exists
tar -C "$COMPOSE_DIR" --exclude='./postgres' -czf "$TMP_COMPOSE_TAR" .

# Replace any previous archives for this run
rm -f "$BDIR"/irius.compose.*.tar.gz || true
mv -f "$TMP_COMPOSE_TAR" "$OUT_COMPOSE_TAR"

C_TAR_SIZE="$(du -h "$OUT_COMPOSE_TAR" | cut -f1)"
echo "Compose dir backed up: $C_TAR_SIZE -> $OUT_COMPOSE_TAR"

# —————————————————————————————————————————————————————————————
# Backup original container images (offline mode only)
# —————————————————————————————————————————————————————————————

if [ "$OFFLINE" -eq 1 ]; then
	copy_with_fullref "$(image_ref "startleft")" \
		"$(image_ref "startleft" | sed 's#/#_#g; s#:#_#g').oci.tar"

	copy_with_fullref "$(image_ref "reporting-module")" \
		"$(image_ref "reporting-module" | sed 's#/#_#g; s#:#_#g').oci.tar"

	# Ensure your local custom images exist
	# nginx:
	podman image exists localhost/nginx-rhel:latest || die "Missing image: localhost/nginx-rhel:latest"
	# tomcat: ensure we have :latest (retag if only versioned exists)
	if ! podman image exists localhost/tomcat-rhel:latest; then
		if podman image exists "localhost/tomcat-rhel:tomcat-$TOMCAT_V"; then
			echo "Retagging localhost/tomcat-rhel:tomcat-$TOMCAT_V -> localhost/tomcat-rhel:latest"
			podman tag "localhost/tomcat-rhel:tomcat-$TOMCAT_V" localhost/tomcat-rhel:latest
		else
			die "Missing image: localhost/tomcat-rhel:(latest or tomcat-$TOMCAT_V)"
		fi
	fi
	# postgres:
	podman image exists localhost/postgres-gpg:15.4 || die "Missing image: localhost/postgres-gpg:15.4"

	# Save local custom images with embedded refs
	save_local_with_fullref localhost/nginx-rhel:latest localhost_nginx-rhel.oci.tar
	save_local_with_fullref localhost/tomcat-rhel:latest localhost_tomcat-rhel.oci.tar
	save_local_with_fullref localhost/postgres-gpg:15.4 localhost_postgres-gpg_15.4.oci.tar

	echo "Writing checksums"
	(cd "$BDIR" && rm -f checksums.sha256 && sha256sum images/*.oci.tar >checksums.sha256)
fi

# —————————————————————————————————————————————————————————————
# Decide on Jeff handling
# —————————————————————————————————————————————————————————————
OVERRIDE_FILE="$SCRIPT_PATH/../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.override.yml"
JEFF_FILE="$SCRIPT_PATH/../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.jeff.yml"
JEFF_TEMPLATE="$SCRIPT_PATH/../templates/$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.jeff.tpl"

USING_JEFF="$(prompt_yn "Are you using Jeff?")"

if [[ $USING_JEFF == "y" ]]; then
	JEFF_ENABLED="y"
	JEFF_NEWLY_ENABLED="n"

	if [[ ! -f $JEFF_FILE ]]; then
		echo "ERROR: Jeff is marked as enabled but Jeff compose file is missing: $JEFF_FILE" >&2
		exit 1
	fi
else
	ENABLE_JEFF_NOW="$(prompt_yn "Do you want to set up Jeff now?")"
	if [[ $ENABLE_JEFF_NOW == "y" ]]; then
		JEFF_ENABLED="y"
		JEFF_NEWLY_ENABLED="y"
		cp "$JEFF_TEMPLATE" "$JEFF_FILE"
	else
		JEFF_ENABLED="n"
		JEFF_NEWLY_ENABLED="n"
	fi
fi

export JEFF_ENABLED

# —————————————————————————————————————————————————————————————
# Ensure we have up-to-date compose files
# —————————————————————————————————————————————————————————————

echo "Refreshing generated compose files from templates while preserving client-specific values..."
refresh_generated_compose_files_from_templates "$SCRIPT_PATH/../$CONTAINER_ENGINE" "$CONTAINER_ENGINE"

POSTGRES_FILE="$SCRIPT_PATH/../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.postgres.yml"
COMPOSE_YML="$SCRIPT_PATH/../$CONTAINER_ENGINE/$CONTAINER_ENGINE-compose.yml"

update_compose_image_placeholders "$COMPOSE_YML" "$JEFF_FILE" "$POSTGRES_FILE"

# —————————————————————————————————————————————————————————————
# Setup Jeff if enabled now but not previously (pre-upgrade)
# —————————————————————————————————————————————————————————————

if [[ $JEFF_NEWLY_ENABLED == "y" ]]; then
	echo "Setting up Jeff for this existing installation..."

	prompt_jeff_config
	enable_jeff_override_env "$OVERRIDE_FILE"
	configure_jeff_file "$JEFF_FILE"

	case "$CONTAINER_ENGINE" in
		docker)
			UNIT_PATH="/etc/systemd/system/iriusrisk-docker.service"
			SYSTEMCTL_CMD="sudo systemctl"
			SED_CMD="sudo sed"
			;;
		podman)
			UNIT_PATH="$HOME/.config/systemd/user/iriusrisk-podman.service"
			SYSTEMCTL_CMD="systemctl --user"
			SED_CMD="sed"
			;;
		*)
			echo "ERROR: Unsupported engine: $CONTAINER_ENGINE" >&2
			exit 1
			;;
	esac

	if [[ ! -f $UNIT_PATH ]]; then
		echo "ERROR: Service unit not found: $UNIT_PATH" >&2
		exit 1
	fi

	if [[ ! -f $JEFF_FILE ]]; then
		echo "ERROR: Jeff compose file not found: $JEFF_FILE" >&2
		exit 1
	fi

	if grep -q -- "${CONTAINER_ENGINE}-compose.jeff.yml" "$UNIT_PATH"; then
		echo "Jeff compose file already present in service unit."
	else
		$SED_CMD -i -E \
			"s#^(ExecStart=.*)#\1 -f ${JEFF_FILE}#" \
			"$UNIT_PATH"

		$SED_CMD -i -E \
			"s#^(ExecStop=.*)#\1 -f ${JEFF_FILE}#" \
			"$UNIT_PATH"

		$SYSTEMCTL_CMD daemon-reload
		echo "Jeff compose file added to service unit."
	fi
fi

# —————————————————————————————————————————————————————————————
# Discover highest tomcat tag (registry-aware) & choose version
# —————————————————————————————————————————————————————————————
if [ "$OFFLINE" -eq 0 ]; then

	COMPOSE_YML="$COMPOSE_DIR/$CONTAINER_ENGINE-compose.yml"
	[[ -f $COMPOSE_YML ]] || {
		echo "ERROR: Compose file not found: $COMPOSE_YML" >&2
		exit 4
	}

	if [[ ${REGISTRY_URL:-docker.io} != "docker.io" ]]; then
		echo "Custom registry selected: skipping Docker Hub tag discovery."
		read -r -p "Version to upgrade to: " CHOSEN_VERSION
		if [[ ! $CHOSEN_VERSION =~ ^[0-9]+$ && ! $CHOSEN_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo "ERROR: Version must be 'N' or 'N.N.N' (e.g., 4 or 4.46.9). You entered: $CHOSEN_VERSION" >&2
			exit 6
		fi
	else
		REPO_NS="${REGISTRY_NAMESPACE:-continuumsecurity/iriusrisk-prod}"
		HUB_LOGIN_URL="https://hub.docker.com/v2/users/login/"
		TAGS_URL_BASE="https://hub.docker.com/v2/repositories/${REPO_NS}/tags"
		echo "Discovering tomcat tags on Docker Hub for ${REPO_NS} ..."

		# Ensure we have a password; helper will prompt if needed
		[[ -z ${REGISTRY_PASS:-} ]] && prompt_registry_password

		# Obtain Hub JWT (separate from docker login credential store)
		HUB_TOKEN="$(
			curl -fsSL -H 'Content-Type: application/json' \
				-d "{\"username\":\"${REGISTRY_USERNAME:-iriusrisk}\",\"password\":\"${REGISTRY_PASS}\"}" \
				"${HUB_LOGIN_URL}" 2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
		)" || true

		if [[ -z $HUB_TOKEN || $HUB_TOKEN == "null" ]]; then
			echo "WARNING: Hub login failed; you can still type the version manually."
		fi

		# Gather tomcat-* tags from Hub API (paginate via .next)
		versions=()
		if [[ -n $HUB_TOKEN ]]; then
			url="${TAGS_URL_BASE}?page_size=100&name=tomcat"
			while [[ -n $url ]]; do
				page="$(curl -fsSL -H "Authorization: JWT ${HUB_TOKEN}" "$url" 2>/dev/null || true)"
				[[ -z $page ]] && break

				if command -v jq >/dev/null 2>&1; then
					while IFS= read -r tag; do
						[[ $tag =~ ^tomcat-([0-9]+(\.[0-9]+){0,2})$ ]] && versions+=("${tag#tomcat-}")
					done < <(printf '%s' "$page" | jq -r '.results[].name' 2>/dev/null)
					next="$(printf '%s' "$page" | jq -r '.next // empty')"
				else
					while IFS= read -r tag; do
						tag="${tag#\"}"
						tag="${tag%\"}"
						[[ $tag =~ ^tomcat-([0-9]+(\.[0-9]+){0,2})$ ]] && versions+=("${tag#tomcat-}")
					done < <(printf '%s' "$page" | grep -o '"name"[[:space:]]*:[[:space:]]*"tomcat-[^"]*"' | sed -E 's/.*"tomcat-/tomcat-/' | sed -E 's/"$//')
					next="$(printf '%s' "$page" | grep -o '"next"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:"(.*)"/\1/')"
					[[ $next == "null" ]] && next=""
				fi

				url="$next"
			done
		fi

		# Choose default: prefer full semver X.Y.Z; else highest major
		DEFAULT_VERSION=""
		if [[ ${#versions[@]} -gt 0 ]]; then
			full=() majors=()
			for v in "${versions[@]}"; do
				[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && full+=("$v") || majors+=("$v")
			done
			if [[ ${#full[@]} -gt 0 ]]; then
				mapfile -t sorted_full < <(printf '%s\n' "${full[@]}" | sort -uV)
				DEFAULT_VERSION="${sorted_full[-1]}"
			elif [[ ${#majors[@]} -gt 0 ]]; then
				mapfile -t sorted_maj < <(printf '%s\n' "${majors[@]}" | sort -u)
				DEFAULT_VERSION="${sorted_maj[-1]}"
			fi
		fi
		[[ -z $DEFAULT_VERSION ]] && DEFAULT_VERSION="4"
		echo "Highest available tomcat version (Hub): $DEFAULT_VERSION"

		read -r -p "Version to upgrade to [${DEFAULT_VERSION}]: " CHOSEN_VERSION
		[[ -z $CHOSEN_VERSION ]] && CHOSEN_VERSION="$DEFAULT_VERSION"
		if [[ ! $CHOSEN_VERSION =~ ^[0-9]+$ && ! $CHOSEN_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo "ERROR: Version must be 'N' or 'N.N.N' (e.g., 4 or 4.46.9). You entered: $CHOSEN_VERSION" >&2
			exit 6
		fi
	fi

	TARGET_TAG="tomcat-$CHOSEN_VERSION"
else
	CHOSEN_VERSION=$(tr -d '[:space:]' <"${OFFLINE_BUNDLE_DIR}/iriusrisk_version")
	COMPOSE_YML="$COMPOSE_DIR/$CONTAINER_ENGINE-compose.yml"
fi

# —————————————————————————————————————————————————————————————
# Decide SAML handling based on version boundary and file existence
# —————————————————————————————————————————————————————————————
LEGACY_SAML_PRESENT="n"
if saml_files_exist; then LEGACY_SAML_PRESENT="y"; fi

TARGET_GE_4_48="n"
version_ge_4_48 "$CHOSEN_VERSION" && TARGET_GE_4_48="y"

PREV_LT_4_48="n"
if [[ $PREV_VERSION != "unknown" ]]; then
	version_lt_4_48 "$PREV_VERSION" && PREV_LT_4_48="y"
else
	# Be safe: if unknown previous & legacy files exist and target >= 4.48, include for migration
	if [[ $LEGACY_SAML_PRESENT == "y" && $TARGET_GE_4_48 == "y" ]]; then
		PREV_LT_4_48="y"
	fi
fi

# Rules:
# - If target < 4.48: keep using legacy files if present.
# - If target ≥ 4.48:
#     * If previous < 4.48 and legacy files exist → include them for auto-migration (then delete after successful upgrade)
#     * Otherwise → do not include legacy SAML (app-managed or no files present)
if [[ $TARGET_GE_4_48 == "y" ]]; then
	if [[ $PREV_LT_4_48 == "y" && $LEGACY_SAML_PRESENT == "y" ]]; then
		SAML_ENABLED="y"
		echo "Crossing <4.48 → ≥4.48 with legacy SAML present → including legacy SAML for migration."
	else
		SAML_ENABLED="n"
		echo "Target ≥4.48 without legacy migration need → SAML managed by application (no legacy include)."
	fi
else
	if [[ $LEGACY_SAML_PRESENT == "y" ]]; then
		SAML_ENABLED="y"
		echo "Target <4.48 with legacy SAML present → including legacy SAML (file-based)."
	else
		SAML_ENABLED="n"
		echo "Target <4.48 with no legacy SAML files → not including SAML."
	fi
fi

# —————————————————————————————————————————————————————————————
# Build compose override (now that SAML decision is made)
# —————————————————————————————————————————————————————————————
COMPOSE_OVERRIDE=$(build_compose_override "$SAML_ENABLED" "$USE_INTERNAL_PG")

# —————————————————————————————————————————————————————————————
# Migrate legacy Podman services → single user unit (pre-change)
# —————————————————————————————————————————————————————————————
if [[ $CONTAINER_ENGINE == "podman" ]]; then
	# Detect if any legacy user services are present (enabled/running) or unit files exist.
	HAVE_LEGACY=""
	if systemctl --user list-units 'container-*.service' --no-legend 2>/dev/null | grep -q .; then
		HAVE_LEGACY="yes"
	elif compgen -G "$HOME/.config/systemd/user/container-*.service" >/dev/null 2>&1; then
		HAVE_LEGACY="yes"
	fi

	if [[ -n $HAVE_LEGACY ]]; then
		echo "Migrating legacy Podman services to single user unit (iriusrisk-podman.service)..."
		cleanup_legacy_podman_units
		ensure_single_podman_unit_created
	fi
fi

# —————————————————————————————————————————————————————————————
# Update compose tomcat tag (docker) or note podman build
# —————————————————————————————————————————————————————————————
if [[ $CONTAINER_ENGINE == "docker" ]]; then
	replace_placeholder_in_file "$COMPOSE_YML" "TOMCAT_IMAGE" "$(image_ref "tomcat-$CHOSEN_VERSION")"
	echo "Updated tomcat image tag → $(image_ref "tomcat-$CHOSEN_VERSION")"
else
	echo "Compose uses localhost/tomcat-rhel; will rebuild the local image instead of sed."
fi

# —————————————————————————————————————————————————————————————
# Update Startleft & Reporting Module tags from /versions/<ver>.json
# —————————————————————————————————————————————————————————————
if [ "$OFFLINE" -eq 0 ]; then
	VERSIONS_DIR="$SCRIPT_PATH/../versions"
	VER_FILE="$VERSIONS_DIR/$CHOSEN_VERSION.json"

	echo "Looking for version metadata: $VER_FILE"
	if [[ -f $VER_FILE ]]; then
		SL_VER="$(jq -r '.Startleft.S // empty' "$VER_FILE" 2>/dev/null || true)"
		RM_VER="$(jq -r '.ReportingModule.S // empty' "$VER_FILE" 2>/dev/null || true)"

		update_component_tag "startleft" "$SL_VER"
		update_component_tag "reporting-module" "$RM_VER"
	else
		echo "WARNING: Version metadata file not found: $VER_FILE — skipping Startleft/Reporting Module updates."
	fi
fi

# —————————————————————————————————————————————————————————————
# Rebuild local base images for podman (if applicable)
# —————————————————————————————————————————————————————————————
if [[ $CONTAINER_ENGINE == "podman" && $OFFLINE -eq 0 ]]; then
	container_registry_login
	migrate_existing_podman_secrets_if_needed
	build_podman_custom_images "$CHOSEN_VERSION"
fi

# —————————————————————————————————————————————————————————————
# Update the stack
# —————————————————————————————————————————————————————————————
echo "Cleaning up current stack and loading latest images"

if [[ $CONTAINER_ENGINE == "docker" ]]; then
	container_registry_login
fi

if [[ $CONTAINER_ENGINE == "podman" ]]; then
	ensure_podman_network_kernel_modules
fi

$CONTAINER_ENGINE system prune -f
cd "$COMPOSE_DIR"

# Destroy whole IriusRisk stack
$COMPOSE_TOOL $COMPOSE_OVERRIDE down

if [ "$OFFLINE" -eq 0 ]; then
	# Force download latest images
	$COMPOSE_TOOL $COMPOSE_OVERRIDE pull
else
	offline_load_images
fi

echo "Restarting stack to complete upgrade"

if [[ $CONTAINER_ENGINE == "podman" ]]; then
	ensure_podman_network_kernel_modules
fi

# Spin up IriusRisk stack
$COMPOSE_TOOL $COMPOSE_OVERRIDE up -d

echo "Stack restarted with latest images"

# —————————————————————————————————————————————————————————————
# Post-upgrade health wait (≤ 60 min) and conditional SAML cleanup
# —————————————————————————————————————————————————————————————
echo
echo "Waiting for IriusRisk to become healthy (up to 60 minutes)..."
POST_JSON=""

if wait_for_health 60 60; then
	POST_JSON="$(cat /tmp/irius_health.json 2>/dev/null || true)"
	POST_VERSION="$(printf '%s' "$POST_JSON" | extract_version_from_json)"
	echo "Post-upgrade IriusRisk is healthy. Detected version: ${POST_VERSION:-unknown}"

	TARGET_GE_4_48_POST="n"
	if [[ -n $POST_VERSION ]] && version_ge_4_48 "$POST_VERSION"; then
		TARGET_GE_4_48_POST="y"
	fi

	# If we crossed <4.48 → ≥4.48 and used legacy SAML for migration, delete legacy files now.
	if [[ $TARGET_GE_4_48_POST == "y" && $LEGACY_SAML_PRESENT == "y" && $PREV_LT_4_48 == "y" ]]; then
		echo "Upgrade to ≥4.48 confirmed healthy and prior was <4.48 → removing legacy SAML files."
		rm -f "$COMPOSE_DIR/SAMLv2-config.groovy" "$COMPOSE_DIR/idp.xml" "$COMPOSE_DIR/iriusrisk-sp.jks" || true

		# --- Remove SAML override from services/stack now that migration succeeded ---
		echo "SAML migration complete. Updating services to exclude legacy SAML override..."
		NO_SAML_OVERRIDE="$(build_compose_override "n" "$USE_INTERNAL_PG")"

		case "$CONTAINER_ENGINE" in
			docker)
				UNIT_PATH="/etc/systemd/system/iriusrisk-docker.service"
				SYSTEMCTL_CMD="sudo systemctl"
				SED_CMD="sudo sed"
				;;
			podman)
				UNIT_PATH="$HOME/.config/systemd/user/iriusrisk-podman.service"
				SYSTEMCTL_CMD="systemctl --user"
				SED_CMD="sed"
				;;
			*)
				echo "ERROR: Unsupported CONTAINER_ENGINE=$CONTAINER_ENGINE" >&2
				exit 1
				;;
		esac

		SERVICE_NAME="iriusrisk-$CONTAINER_ENGINE.service"

		if [[ -f $UNIT_PATH ]]; then
			echo "Patching ${CONTAINER_ENGINE^} service to drop SAML override..."
			# Remove any '-f <...>/docker-compose.saml.yml' from ExecStart/ExecStop lines
			$SED_CMD -i -E \
				"s/^(Exec(Start|Stop)=.*)[[:space:]]+-f[[:space:]]+[^[:space:]]*${CONTAINER_ENGINE}-compose\.saml\.yml/\1/g" \
				"$UNIT_PATH"

			$SYSTEMCTL_CMD daemon-reload
			$SYSTEMCTL_CMD restart "$SERVICE_NAME"
			echo "${CONTAINER_ENGINE^} service restarted without SAML override."
		else
			echo "Service file not found; reconciling stack without SAML override via compose..."
			# Falls back to compose (expects $COMPOSE_TOOL and $NO_SAML_OVERRIDE set by caller)
			$COMPOSE_TOOL $NO_SAML_OVERRIDE up -d
		fi

		echo "Waiting for IriusRisk to become healthy after removing SAML override..."
		if wait_for_health 60 60; then
			echo "Post-migration stack is healthy without SAML override."
		else
			echo "WARNING: Stack did not become healthy within 60 minutes after removing SAML override."
			echo "Starting rollback..."
			if [ "$OFFLINE" -eq 0 ]; then
				bash "$SCRIPT_PATH/rollback.sh"
			else
				bash "$SCRIPT_PATH/rollback.sh" --offline
			fi
		fi
	fi

else
	echo "WARNING: IriusRisk did not become healthy within 60 minutes; legacy SAML files (if any) were NOT deleted."
	echo "Starting rollback."
	if [ "$OFFLINE" -eq 0 ]; then
		bash "$SCRIPT_PATH/rollback.sh"
	else
		bash "$SCRIPT_PATH/rollback.sh" --offline
	fi
fi

echo "Upgrade script completed."
