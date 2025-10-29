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

# —————————————————————————————————————————————————————————————
# Script Start
# —————————————————————————————————————————————————————————————
echo "IriusRisk Upgrade Deployment"
echo "---------------------------------------"

# —————————————————————————————————————————————————————————————
# 0. Ensure we're in the scripts dir
# —————————————————————————————————————————————————————————————
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_PATH"

echo "Current directory: $(pwd)"
echo

# —————————————————————————————————————————————————————————————
# 1. Set engine and Postgres options
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
# 2. Pre-upgrade health/version (best-effort)
# —————————————————————————————————————————————————————————————
PREV_VERSION="unknown"
read -r pre_code pre_json < <(fetch_health)
if [[ $pre_code == "200" && -n $pre_json ]]; then
	PREV_VERSION="$(printf '%s' "$pre_json" | extract_version_from_json)"
fi
printf '%s\n' "$PREV_VERSION" >/tmp/iriusrisk_previous_version.txt || true
echo "Detected current IriusRisk version (pre-upgrade): $PREV_VERSION"

# —————————————————————————————————————————————————————————————
# 3. Discover highest tomcat tag (Hub API v2, private repo) & choose version
# —————————————————————————————————————————————————————————————
REPO_NS="continuumsecurity"
REPO_NAME="iriusrisk-prod"
HUB_LOGIN_URL="https://hub.docker.com/v2/users/login/"
TAGS_URL_BASE="https://hub.docker.com/v2/repositories/${REPO_NS}/${REPO_NAME}/tags"
echo "Discovering tomcat tags on Docker Hub for ${REPO_NS}/${REPO_NAME} ..."

# Ensure we have a password; your helper already sets REGISTRY_PASS
[[ -z ${REGISTRY_PASS:-} ]] && prompt_registry_password

# Obtain Hub JWT (separate from docker login credential store)
HUB_TOKEN="$(
	curl -fsSL -H 'Content-Type: application/json' \
		-d "{\"username\":\"iriusrisk\",\"password\":\"${REGISTRY_PASS}\"}" \
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

TARGET_TAG="tomcat-$CHOSEN_VERSION"
COMPOSE_YML="$COMPOSE_DIR/$CONTAINER_ENGINE-compose.yml"
[[ -f $COMPOSE_YML ]] || {
	echo "ERROR: Compose file not found: $COMPOSE_YML" >&2
	exit 4
}

# —————————————————————————————————————————————————————————————
# 4. Decide SAML handling based on version boundary and file existence
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
# 5. Build compose override (now that SAML decision is made)
# —————————————————————————————————————————————————————————————
COMPOSE_OVERRIDE=$(build_compose_override "$SAML_ENABLED" "$USE_INTERNAL_PG")

# —————————————————————————————————————————————————————————————
# 7. Backup DB
# —————————————————————————————————————————————————————————————
backup_db

# —————————————————————————————————————————————————————————————
# 7. Backup compose files referenced in COMPOSE_OVERRIDE
# —————————————————————————————————————————————————————————————
TMP_COMPOSE_TAR="/tmp/irius.compose.$TS.tar.gz"
OUT_COMPOSE_TAR="$BDIR/irius.compose.$VERSION.tar.gz"

echo "Backing up compose files referenced in COMPOSE_OVERRIDE from: $COMPOSE_DIR"
# Parse -f arguments safely
read -r -a _parts <<<"$COMPOSE_OVERRIDE"

compose_files=()
i=0
while [[ $i -lt ${#_parts[@]} ]]; do
	if [[ ${_parts[i]} == "-f" && -n ${_parts[i + 1]:-} ]]; then
		compose_files+=("${_parts[i + 1]}")
		i=$((i + 2))
	else
		i=$((i + 1))
	fi
done

# De-duplicate
declare -A seen
uniq_files=()
for f in "${compose_files[@]}"; do
	if [[ -n $f && -z ${seen[$f]:-} ]]; then
		seen[$f]=1
		uniq_files+=("$f")
	fi
done

pushd "$COMPOSE_DIR" >/dev/null
valid_files=()
missing_files=()
for f in "${uniq_files[@]}"; do
	if [[ -f $f ]]; then
		valid_files+=("$f")
	elif [[ -f "./$f" ]]; then
		valid_files+=("./$f")
	elif [[ -f "$(basename "$f")" ]]; then
		valid_files+=("$(basename "$f")")
	elif [[ $f == /* && -f $f ]]; then
		valid_files+=("$f")
	else
		missing_files+=("$f")
	fi
done

if [[ ${#missing_files[@]} -gt 0 ]]; then
	echo "WARNING: The following compose files were referenced but not found and won't be backed up:"
	for m in "${missing_files[@]}"; do echo " - $m"; done
fi

if [[ ${#valid_files[@]} -gt 0 ]]; then
	tar -czf "$TMP_COMPOSE_TAR" "${valid_files[@]}"
	rm -f "$BDIR"/irius.compose.*.tar.gz || true
	mv -f "$TMP_COMPOSE_TAR" "$OUT_COMPOSE_TAR"
	C_TAR_SIZE="$(du -h "$OUT_COMPOSE_TAR" | cut -f1)"
	echo "Compose files backed up: $C_TAR_SIZE -> $OUT_COMPOSE_TAR"
else
	echo "WARNING: No valid compose files found to back up."
fi
popd >/dev/null

# —————————————————————————————————————————————————————————————
# 8. Update compose tomcat tag (docker) or note podman build
# —————————————————————————————————————————————————————————————
if [[ $CONTAINER_ENGINE == "docker" ]]; then
	# Update ONLY Tomcat line (matches major-only or full semver; docker.io prefix optional)
	if grep -qE '^[[:space:]]*image:[[:space:]]*(docker\.io/)?continuumsecurity/iriusrisk-prod:tomcat-[0-9.]+([[:space:]]|$)' "$COMPOSE_YML"; then
		sed -i -E \
			"s@(^[[:space:]]*image:[[:space:]]*(docker\.io/)?continuumsecurity/iriusrisk-prod:tomcat-)[0-9]+([.][0-9]+){0,2}([[:space:]]*(#.*)?\$)@\\1${CHOSEN_VERSION}\\4@" \
			"$COMPOSE_YML"
		echo "Updated tomcat image tag → docker.io/continuumsecurity/iriusrisk-prod:tomcat-${CHOSEN_VERSION}"
	else
		echo "ERROR: No tomcat image line found in $COMPOSE_YML (expected ':tomcat-<major>' or ':tomcat-<X.Y.Z>')." >&2
		exit 5
	fi
else
	echo "Compose uses localhost/tomcat-rhel; will rebuild the local image instead of sed."
fi

# —————————————————————————————————————————————————————————————
# 9. Update Startleft & Reporting Module tags from /versions/<ver>.json
# —————————————————————————————————————————————————————————————
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

# —————————————————————————————————————————————————————————————
# 10. Rebuild local base images for podman (if applicable)
# —————————————————————————————————————————————————————————————
if [[ $CONTAINER_ENGINE == "podman" ]]; then
	build_podman_custom_images "$CHOSEN_VERSION"
fi

# —————————————————————————————————————————————————————————————
# 11. Update the stack
# —————————————————————————————————————————————————————————————
echo "Cleaning up current stack and pulling latest images"
container_registry_login
$CONTAINER_ENGINE system prune -f
cd "$COMPOSE_DIR"

# Destroy whole IriusRisk stack
$COMPOSE_TOOL $COMPOSE_OVERRIDE down

# Force download latest images
$COMPOSE_TOOL $COMPOSE_OVERRIDE pull --ignore-pull-failures || true

echo "Restarting stack to complete upgrade"

# Spin up IriusRisk stack
$COMPOSE_TOOL $COMPOSE_OVERRIDE up -d

echo "Stack restarted with latest images"

# —————————————————————————————————————————————————————————————
# 12. Post-upgrade health wait (≤ 60 min) and conditional SAML cleanup
# —————————————————————————————————————————————————————————————
echo
echo "Waiting for IriusRisk to become healthy (up to 60 minutes)..."
POST_JSON=""
if wait_for_health 60 60; then
	POST_JSON="$(cat /tmp/irius_health.json 2>/dev/null || true)"
	POST_VERSION="$(printf '%s' "$POST_JSON" | extract_version_from_json)"
	echo "Post-upgrade IriusRisk is healthy. Detected version: ${POST_VERSION:-unknown}"

	TARGET_GE_4_48_POST="n"
	if [[ -n $POST_VERSION ]] && version_ge_4_48 "$POST_VERSION"; then TARGET_GE_4_48_POST="y"; fi

	# If we crossed <4.48 → ≥4.48 and used legacy SAML for migration, delete legacy files now.
	if [[ $TARGET_GE_4_48_POST == "y" && $LEGACY_SAML_PRESENT == "y" && $PREV_LT_4_48 == "y" ]]; then
		echo "Upgrade to ≥4.48 confirmed healthy and prior was <4.48 → removing legacy SAML files."
		rm -f "$COMPOSE_DIR/SAMLv2-config.groovy" "$COMPOSE_DIR/idp.xml" "$COMPOSE_DIR/iriusrisk-sp.jks" || true
		# --- Remove SAML override from services/stack now that migration succeeded ---
		echo "SAML migration complete. Updating services to exclude legacy SAML override..."
		NO_SAML_OVERRIDE="$(build_compose_override "n" "$USE_INTERNAL_PG")"

		case "$CONTAINER_ENGINE" in
			docker)
				if [[ -f /etc/systemd/system/iriusrisk-docker.service ]]; then
					echo "Patching Docker systemd service to drop SAML override..."
					# Remove any '-f docker-compose.saml.yml' segments from Exec lines
					sudo sed -i -E 's/(Exec(Start|Stop)=.*)( -f docker-compose\.saml\.yml)/\1/g' /etc/systemd/system/iriusrisk-docker.service
					sudo systemctl daemon-reload
					sudo systemctl restart iriusrisk-docker.service
					echo "Docker service restarted without SAML override."
				else
					echo "Docker service file not found; reconciling stack without SAML override via compose..."
					$COMPOSE_TOOL $NO_SAML_OVERRIDE up -d
				fi
				;;
			podman)
				echo "Recreating Podman rootless stack without SAML override and refreshing user units..."
				# Reconcile the stack without SAML override
				$COMPOSE_TOOL $NO_SAML_OVERRIDE up -d

				# Stop/disable any existing user units for this project
				stop_disable_user_units_for_project "$CONTAINER_ENGINE" || true

				# Discover compose project and regenerate per-container units
				PROJECT_LABEL="$(podman ps -a --format '{{ index .Labels "io.podman.compose.project" }}' | head -n1)"
				UNIT_DIR="$HOME/.config/systemd/user"
				mkdir -p "$UNIT_DIR"
				mapfile -t containers < <(
					podman ps -a --filter "label=io.podman.compose.project=${PROJECT_LABEL}" --format "{{.Names}}"
				)
				for cname in "${containers[@]}"; do
					podman generate systemd --files --name "$cname" 2> >(grep -v "DEPRECATED command" >&2)
					[[ -f "container-$cname.service" ]] && mv "container-$cname.service" "$UNIT_DIR"/ || true
				done

				if ensure_user_systemd_ready "$(id -un)"; then
					systemctl --user daemon-reload
					for cname in "${containers[@]}"; do
						svc="container-$cname.service"
						[[ -f "$UNIT_DIR/$svc" ]] && systemctl --user enable --now "$svc" || true
					done
					echo "Podman user services updated without SAML override."
				else
					echo "WARNING: user systemd not reachable; units written to $UNIT_DIR and will activate on next login/reboot."
				fi
				;;
		esac
	fi
else
	echo "WARNING: IriusRisk did not become healthy within 60 minutes; legacy SAML files (if any) were NOT deleted."
	echo "Starting rollback"
	bash "$SCRIPT_PATH/rollback.sh"
fi

echo "Upgrade script completed."
