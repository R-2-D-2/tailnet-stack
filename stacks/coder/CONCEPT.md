# Coder Stack — Concept & Architecture

## Goal

A self-hosted [Coder](https://coder.com/) deployment running on a VPS inside the Tailnet.  
Developers can open a browser, create a workspace, and get a full VS Code Web IDE with devcontainer support — no local Docker or IDE installation needed.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  VPS (Tailnet node)                                 │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │  Docker Compose: coder stack                │   │
│  │                                             │   │
│  │  ┌──────────┐   ┌──────────┐  ┌─────────┐  │   │
│  │  │ postgres │   │  dind    │  │  coder  │  │   │
│  │  │ :5432    │   │  :2375   │  │  :7080  │  │   │
│  │  └──────────┘   └──────────┘  └────┬────┘  │   │
│  │       ▲               ▲            │       │   │
│  │       └───────────────┴────────────┘       │   │
│  │                  coder network             │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  Tailscale interface (tailscale0)                   │
└─────────────────────────────────────────────────────┘
          ▲
          │  Tailnet (100.64.0.0/10)
          │
  Developer Browser → http://<vps-tailnet-host>:7080
```

### Workspace container (provisioned by Coder into DinD)

```
┌─────────────────────────────────────────────────────┐
│  Workspace container  (privileged)                  │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │  Inner dockerd  (unix:///var/run/docker.sock)│   │
│  └──────────────────────────┬──────────────────┘   │
│                             │                       │
│  ┌──────────────────────────▼──────────────────┐   │
│  │  devcontainer  (via @devcontainers/cli)      │   │
│  │  ┌───────────────────────────────────────┐  │   │
│  │  │  Project source  /workspaces/<name>   │  │   │
│  │  └───────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │  code-server  :13337  (VS Code Web)         │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  Coder agent  (injected binary, reports back to     │
│  Coder server over Tailnet)                         │
└─────────────────────────────────────────────────────┘
```

---

## Components

### Infrastructure (docker-compose.yml)

| Service    | Image                      | Role                                                  |
|------------|----------------------------|-------------------------------------------------------|
| `postgres` | `postgres:16-alpine`       | Coder metadata, workspace state, user sessions        |
| `dind`     | `docker:27-dind`           | Docker daemon — creates & manages workspace containers|
| `coder`    | `ghcr.io/coder/coder`      | Web UI, API, workspace lifecycle, agent relay         |

**Why DinD as a sidecar?**  
Coder's Docker provisioner needs a Docker socket. Running a dedicated DinD container isolates workspace containers from the host and avoids bind-mounting `/var/run/docker.sock`, which would give workspaces host root access.

### Workspace Template (`templates/devcontainer-dind/`)

The Terraform template provisions one Docker container per workspace with:

| Feature                  | How it works                                                                 |
|--------------------------|------------------------------------------------------------------------------|
| **VS Code Web**          | `code-server` installed & started in the agent `startup_script` on port 13337; surfaced as a `coder_app` with `subdomain = true` |
| **Docker-in-Docker**     | Container runs `privileged: true`; inner `dockerd` starts at container boot |
| **devcontainer support** | `@devcontainers/cli` runs `devcontainer up` on the cloned repo if a `.devcontainer/` is present |
| **Persistent storage**   | Named Docker volume mounted at `/workspaces` — survives workspace stop/start |
| **Dotfiles**             | Optional parameter; applied via `coder dotfiles` on startup                 |
| **Resource limits**      | User-selectable CPU cores and memory at workspace creation                   |

---

## Data Flow — Workspace Start

```
1. Developer clicks "Start workspace" in Coder UI
2. Coder server runs Terraform (devcontainer-dind template)
3. Terraform creates a Docker container in the DinD sidecar:
     - privileged=true (for inner dockerd)
     - injects CODER_AGENT_TOKEN
     - mounts /workspaces volume
4. Container boots, Coder agent binary starts (injected init script)
5. Agent phones home to Coder server (over Tailnet)
6. startup_script runs:
     a. Waits for inner dockerd
     b. git clone <repo> → /workspaces/<name>
     c. Installs & starts code-server on :13337
     d. Runs `devcontainer up` if .devcontainer/ found
     e. Applies dotfiles
7. Coder UI shows "VS Code Web" button → proxied through Coder to :13337
```

---

## Networking

| Connection                          | Protocol / Port      | Notes                                  |
|-------------------------------------|----------------------|----------------------------------------|
| Browser → Coder UI                  | HTTP :7080           | Via Tailnet only                       |
| Browser → VS Code Web               | HTTP (wildcard sub.) | `CODER_WILDCARD_ACCESS_URL` required   |
| Coder → DinD                        | TCP :2375 (plain)    | Internal compose network, no TLS needed|
| Workspace agent → Coder server      | HTTPS / DERP relay   | Tailnet or direct TCP                  |
| Inner dockerd → internet            | Via host NAT         | For pulling devcontainer images        |

**Tailnet access only:**  
The VPS firewall should block port 7080 from the public internet and allow it only from `100.64.0.0/10` (Tailscale CGNAT range). Coder's built-in TLS or a Tailscale Serve/Funnel setup can handle HTTPS termination.

---

## VS Code Web — How it's served

Coder natively proxies web apps running inside workspaces. The template declares:

```hcl
resource "coder_app" "vscode_web" {
  slug      = "code"
  url       = "http://localhost:13337/?folder=/workspaces/<name>"
  subdomain = true   # served at  code--<workspace>--<user>.<wildcard-domain>
}
```

`code-server` (open-source VS Code Web, maintained by Coder) runs inside the workspace container. The developer gets a full VS Code experience with extensions, terminal, Git integration, and Settings Sync — all in the browser.

---

## Custom Workspace Image (Recommended Next Step)

The template currently uses `codercom/enterprise-base:ubuntu`. For production, build a custom image that bakes in:

- Docker CLI + daemon (`docker-ce`)
- `dockerd` as a supervised process (s6 or supervisord)
- `@devcontainers/cli` (Node.js)
- `code-server`
- Coder agent dependencies (`curl`, `git`, `unzip`)

```
stacks/coder/
└── images/
    └── workspace-base/
        ├── Dockerfile
        └── supervisord.conf   # manages: dockerd, coder agent
```

This removes the startup_script installation overhead and makes workspace boot significantly faster.

---

## Security Considerations

| Risk                              | Mitigation                                                       |
|-----------------------------------|------------------------------------------------------------------|
| DinD requires host privileges     | Isolated in dedicated DinD container; not bind-mounting host sock|
| Workspace containers are privileged | Limit to trusted users; consider rootless Docker alternatives  |
| Coder UI exposed on TCP port      | Restrict to Tailnet CIDR via firewall; add Coder user auth      |
| Docker daemon on TCP 2375 (plain) | Internal compose network only; never expose to host             |
| Devcontainer pulls arbitrary images | Coder can be configured with allowed registries (future)       |

---

## Open Questions / TODOs

- [ ] Build custom workspace base image (see above)
- [ ] Evaluate rootless Docker (sysbox, usernetes) as `privileged` alternative
- [ ] Add Traefik or Caddy as reverse proxy for HTTPS + automatic cert from Let's Encrypt / Tailscale cert
- [ ] Coder template versioning strategy (push via `coder templates push`)
- [ ] Multi-node setup: run workspace containers on a separate VPS via remote Docker context
- [ ] Registry mirror / pull-through cache to speed up devcontainer image pulls
- [ ] Backup strategy for `postgres_data` and `coder_data` volumes
