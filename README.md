# IriusRisk On-Prem Templates Repository


This repository contains official Docker, Podman, and Kubernetes configuration templates for deploying IriusRisk on-premise, including optional SAML integration. It is designed for clarity, maintainability, and reuse by structuring configs by deployment method and identity provider.

Get the latest base templates directly from GitHub, inject only your local secrets, and deploy in one command.

---

## 📁 Repository Structure Overview

```
├── docker
│   ├── docker-compose.override.yml     # Compose file for customer secrets (local only)
│   ├── docker-compose.saml.yml         # Compose file for SAML config (local only)
│   └── docker-compose.yml              # Base compose file (public)
├── kubernetes
│   └── README.md                       # Kubernetes guidance
├── podman
│   ├── container-compose.override.yml  # Podman secrets file (local only)
│   ├── container-compose.saml.yml      # Podman SAML config (local only)
│   └── container-compose.yml           # Podman base compose (public)
├── saml
│   ├── auth0
│   │   └── SAMLv2-config.groovy        # SAML config for Auth0
│   ├── azure
│   │   └── SAMLv2-config.groovy        # SAML config for Azure
│   ├── keycloak
│   │   └── SAMLv2-config.groovy        # SAML config for Keycloak
│   └── okta
│       └── SAMLv2-config.groovy        # SAML config for Okta
└── README.md                           # ← You are here
```

---

## 🗃️ Prepare Your Local Files

1. **Clone** to get the base templates:

   ```bash
   git clone https://github.com/iriusrisk/onprem-templates.git ; cd onprem-templates
   ```

2. **Copy & edit** the files of your chosen deployment, replacing the variables. Docker-compose based example:

   - `docker/docker-compose.override.yml` → fill in  
     `NG_SERVER_NAME`, `POSTGRES_IP`, `POSTGRES_PASSWORD`, `IRIUS_EXT_URL`, etc.

   - `docker/docker-compose.saml.yml` → if you use SAML, fill in  
     `KEYSTORE_PASSWORD`, `KEY_ALIAS_PASSWORD`.


---

## 🚀 Deploy

You can fetch the latest public base and layer your local overrides in one line. Docker-compose based example:

### Standard Docker

```bash
curl -o docker-compose.yml https://raw.githubusercontent.com/iriusrisk/onprem-templates/main/docker/docker-compose.yml ; 
docker-compose -f docker-compose.yml -f docker-compose-override.yml up -d
```

### Docker with SAML

```bash
curl -o docker-compose.yml https://raw.githubusercontent.com/iriusrisk/onprem-templates/main/docker/docker-compose.yml ; docker-compose -f docker-compose.yml -f docker-compose.saml.yml -f docker/docker-compose.override.yml up -d
```

- The first `-f` pulls the **public** base from GitHub.
- The next `-f` files live **locally**, containing only your secrets and custom settings.

**Alternative (full local clone):**

If you want more control over the configuration files, you can clone the repository and, after editing the customizable files, start the Docker stack using fully local configuration files.

```bash
# clone the repository
git clone https://github.com/iriusrisk/onprem-templates.git ; cd onprem-templates
# edit the files
# deploy the stack
docker-compose \
  -f docker/docker-compose.yml \
  -f docker/docker-compose.saml.yml \
  -f docker/docker-compose.override.yml \
  up -d
```

Similarly, use the `podman/` directory for Podman-based deployments, replacing docker-compose with container-compose.

---

## 📘 Customer Support Documentation

- **Docker On-Prem Install**  
  https://enterprise-support.iriusrisk.com/s/article/Installing-and-Configuring-IriusRisk-On-Premise

- **Podman On-Prem Install**  
  https://enterprise-support.iriusrisk.com/s/article/Installing-and-Configuring-IriusRisk-On-Premise-with-Podman

- **Azure SAML Example**  
  https://enterprise-support.iriusrisk.com/s/article/SAML-use-case-Microsoft-Azure-as-Identity-Provider

---

## 💻 Technical Requirements

| Component            | Minimum                                                               |
|----------------------|-----------------------------------------------------------------------|
| **OS**               | Linux (RHEL 9+, CentOS-based, Debian-based, AWS Linux-based)          |
| **PostgreSQL**       | 15+ (containerized or host-managed)                                   |
| **Java**             | 17+ (IriusRisk v4.29+)                                                |
| **Docker**           | 20.10+                                                                |
| **Docker Compose**   | 1.29.x                                                                |
| **Podman** _(alt.)_  | 5.x+ with `podman-compose` & rootless support                        |
| **Helm** _(K8s only)_| 3.11+                                                                 |
| **Docker Hub Access**| Required to pull IriusRisk images (credentials via Support ticket)    |

**Required local files** (beside your override/SAML templates):

- `cert.pem` – public SSL certificate  
- `key.pem` – private SSL key  
- `ec_private.pem` – ECC private key for JWT signing  
