# AGENTS.md — AI Agent Guide for onprem-templates

> This file documents conventions, architecture, and workflows for AI agents
> working on the **IriusRisk On-Prem Automation** repository.

---

## Project Overview

This repository provides **automation scripts** for deploying, upgrading, and
managing **IriusRisk on-premises** installations on Linux servers. It supports
both **Docker** and **Podman (rootless)** container engines across multiple
distributions (RHEL 9, Rocky, Amazon Linux 2023, Ubuntu 22–26).

### Core Concepts

| Concept | Description |
|---------|-------------|
| **Template-based compose** | Compose files are generated from `.tpl` templates in `templates/`, then customized per-deployment. Generated `.yml` files are `.gitignore`d. |
| **Container engine detection** | Auto-selected by OS: Podman on RHEL-like, Docker on Ubuntu/Amazon Linux. |
| **PostgreSQL** | Either internal (containerized) or external (user-provided connection). |
| **Jeff (AI Assistant)** | Optional AI component deployed as an additional compose layer. |
| **Offline mode** | Full air-gapped deployment via `--offline --bundle` flags. |
| **Version metadata** | `versions/<ver>.json` maps IriusRisk versions to Startleft/Reporting Module tags. |

---

## Directory Structure

```
onprem-templates/
├── .github/
│   ├── .gitleaks.toml          # Secret-scanning config
│   └── workflows/
│       └── validate-config.yml # CI: validates version JSON schemas
├── .pre-commit-config.yaml     # shfmt formatter for scripts/*.sh
├── .gitignore
├── README.md
├── scripts/                    # All automation scripts (bash)
│   ├── bootstrap.sh            # Entry point: clones repo + runs one-click
│   ├── one-click.sh            # Main end-to-end installer
│   ├── setup-wizard.sh         # Interactive configuration wizard
│   ├── preflight.sh            # Environment validation checks
│   ├── upgrade.sh              # Version upgrade with backups
│   ├── rollback.sh             # Rollback from upgrade backups
│   ├── migrate.sh              # Migrate legacy → template-based system
│   └── functions.sh            # Shared library (prompts, installs, helpers)
├── templates/                  # Compose templates (source of truth)
│   ├── docker/
│   │   ├── docker-compose.tpl          # Main services (nginx, tomcat, startleft, reporting)
│   │   ├── docker-compose.override.tpl # Environment overrides
│   │   ├── docker-compose.jeff.tpl     # Jeff AI assistant services
│   │   └── docker-compose.postgres.tpl # Internal PostgreSQL
│   └── podman/
│       ├── podman-compose.tpl
│       ├── podman-compose.override.tpl
│       ├── podman-compose.jeff.tpl
│       └── podman-compose.postgres.tpl
├── versions/                   # Version → component tag mappings
│   ├── 4.46.9.json
│   ├── 4.47.19.json
│   └── ...
└── logs/                       # Deployment logs (gitignored)
```

---

## Script Architecture

### Execution Flow

```
bootstrap.sh  (clones repo, jumps to one-click)
    └── one-click.sh
            ├── preflight.sh      (validate environment)
            ├── setup-wizard.sh   (interactive config)
            └── deploy_stack      (compose up + systemd)

upgrade.sh
    ├── backup_db + backup compose/service
    ├── refresh_generated_compose_files_from_templates()
    ├── update images/tags
    └── redeploy

rollback.sh
    └── restore from ~/irius_backups/

migrate.sh
    └── legacy compose → template-based system
```

### Shared Library: `functions.sh`

All scripts `source functions.sh`. This is the **single source of truth** for:
- Prompt helpers (`prompt_yn`, `prompt_engine`, `prompt_registry_settings`)
- Dependency installers (`install_docker`, `install_podman`, `install_java`, etc.)
- Image reference resolution (`image_ref`, `postgres_image_ref`, `redis_image_ref`)
- Compose file manipulation (`refresh_generated_compose_files_from_templates`)
- Systemd service generation
- Logging framework (`init_logging`)
- Offline mode helpers
- Podman secret management (GPG-encrypted passwords)
- Health checks (`wait_for_health`, `fetch_health`)

**Convention:** New shared functionality should be added to `functions.sh`, not duplicated across scripts.

### Template System

Templates in `templates/<engine>/` use **shell variable placeholders** (`${VAR}`) that are resolved at deployment time. The workflow is:

1. Copy `.tpl` → `.yml` in the engine-specific directory (`docker/` or `podman/`)
2. Replace placeholders with actual values via `sed` or variable expansion
3. Generated `.yml` files are **never committed** (`.gitignore`d)

**When updating compose structure:** Edit the `.tpl` files, not generated `.yml` files.

---

## Version Metadata

Each `versions/<ver>.json` file maps an IriusRisk version to component tags:

```json
{
  "Startleft": { "S": "v2.3.1" },
  "ReportingModule": { "S": "1.4.0" }
}
```

- Filename = IriusRisk version (e.g., `4.46.9.json`)
- Used by `upgrade.sh` to update Startleft and Reporting Module image tags
- Validated by CI workflow (`.github/workflows/validate-config.yml`)

**Adding a new version:** Create `versions/<ver>.json` with the correct component tags.

---

## Conventions

### Shell Scripts

- **Shebang:** `#!/usr/bin/env bash`
- **Strict mode:** `set -e` (and `set -e -o pipefail` for upgrade.sh)
- **Formatting:** `shfmt -ci -s` (enforced by pre-commit hook)
- **Sourcing:** Always `source functions.sh` at the top, never duplicate logic
- **Paths:** Use `SCRIPT_PATH` and `REPO_ROOT` variables, never hardcode relative paths
- **User input:** Use `prompt_yn`, `prompt_nonempty`, etc. from `functions.sh`
- **Logging:** Use `init_logging "$0"` to auto-log to `logs/<script>_<timestamp>.log`

### Compose Templates

- Use `${VARIABLE_NAME}` placeholders for dynamic values
- Keep Docker and Podman templates in sync (same structure, engine-specific differences only)
- Generated files go in `docker/` or `podman/` at repo root (not in `templates/`)

### Git

- Generated compose files (`.yml`), logs, certificates, and `.env` are `.gitignore`d
- Only `.tpl` templates, scripts, and version metadata are tracked

### Security

- **Never commit secrets** — passwords are handled via prompts or Podman secrets (GPG-encrypted)
- `.gitleaks.toml` is configured for pre-commit secret scanning
- Certificates (`.pem`) are gitignored

---

## Common Tasks for Agents

### Adding a New IriusRisk Version

1. Create `versions/<ver>.json` with Startleft and Reporting Module tags
2. Run `./.github/workflows/validate-config.yml` locally or push to trigger CI

### Adding a New Service to Compose

1. Add the service block to both `templates/docker/docker-compose.tpl` and `templates/podman/podman-compose.tpl`
2. If the service needs environment variables, add them to the override template
3. Update `functions.sh` if new image placeholders or registry logic is needed

### Modifying the Upgrade Flow

1. Edit `upgrade.sh` — it is the canonical upgrade script
2. Ensure backward compatibility with existing backups
3. Test with both Docker and Podman engines

### Adding a New Dependency Check

1. Add the check to `preflight.sh`
2. Add the installer function to `functions.sh`
3. Call the installer from `one-click.sh` based on preflight output

---

## Testing & Validation

- **Pre-commit:** Run `pre-commit run --all-files` to format all scripts with shfmt
- **CI:** Push to `main` triggers `validate-config.yml` (validates version JSON schemas)
- **Manual testing:** Always test scripts on the target OS distribution (RHEL, Ubuntu, Amazon Linux)
- **Offline mode:** Test with `--offline --bundle` flags for air-gapped scenarios

---

## Troubleshooting Patterns

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `permission denied` on Docker | User not in `docker` group yet | `newgrp docker` or re-login |
| Podman boot ID mismatch | `/tmp` storage reset on reboot | Symlinks to `/run/user/<uid>` (handled by scripts) |
| Compose merge conflicts on `git pull` | Generated `.yml` files tracked | Move `.yml` to `/tmp`, `git pull`, move back |
| `No medium found` on systemctl | Missing XDG env vars in SSH | Scripts install `/etc/profile.d/10-xdg-user-bus.sh` |

---

## External References

- [Hardware & Software Requirements](https://enterprise-support.iriusrisk.com/s/article/Hardware-and-Software-Requirements-for-IriusRisk)
- Container registry: `docker.io/continuumsecurity/iriusrisk-prod`
- Supported OS: RHEL 9, Rocky 9.7, Amazon Linux 2023, Ubuntu 22–26
