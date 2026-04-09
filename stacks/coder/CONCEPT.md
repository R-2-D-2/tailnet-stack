# Coder Stack — Concept & Architecture

## Goal

A self-hosted [Coder](https://coder.com/) deployment running on a VPS inside the Tailnet.  
Developers can open a browser, create a workspace, and get a full VS Code Web IDE with devcontainer support — no local Docker or IDE installation needed.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│  VPS (Tailnet node)                                          │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Host Docker daemon                                  │   │
│  │                                                      │   │
│  │  ┌────────────┐   (watches Docker socket for labels) │   │
│  │  │  tsdproxy  │ ──────────────────────────────────┐  │   │
│  │  │  (host)    │                                   │  │   │
│  │  └─────┬──────┘                                   │  │   │
│  │        │ HTTPS proxy                              ▼  │   │
│  │        │                                          │  │   │
│  │  ┌─────▼────────────────────────────────────────┐│  │   │
│  │  │  Docker Compose: coder stack                 ││  │   │
│  │  │                                              ││  │   │
│  │  │  ┌──────────┐  ┌──────────┐  ┌───────────┐  ││  │   │
│  │  │  │ postgres │  │  dind    │  │   coder   │◄─┘│  │   │
│  │  │  │          │  │  :2375   │  │   :7080   │   │  │   │
│  │  │  └──────────┘  └──────────┘  └───────────┘   │  │   │
│  │  │       ▲              ▲              │         │  │   │
│  │  │       └──────────────┴──────────────┘         │  │   │
│  │  │                 coder network                 │  │   │
│  │  └───────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  Tailscale interface  →  coder.tailaa3fee.ts.net             │
└──────────────────────────────────────────────────────────────┘
          ▲
          │  Tailnet (100.64.0.0/10)  —  HTTPS (auto-cert)
          │
  Developer Browser → https://coder.tailaa3fee.ts.net
```

### Workspace container (provisioned by Coder into DinD)

```
┌─────────────────────────────────────────────────┐
│  Workspace container  (privileged)              │
│                                                 │
│  ┌─────────────────────────────────────────┐   │
│  │  Inner dockerd  (unix:///var/run/docker) │   │
│  └────────────────────┬────────────────────┘   │
│                       │                         │
│  ┌────────────────────▼────────────────────┐   │
│  │  devcontainer  (via @devcontainers/cli)  │   │
│  │  ┌───────────────────────────────────┐  │   │
│  │  │  Project source  /workspaces/...  │  │   │
│  │  └───────────────────────────────────┘  │   │
│  └─────────────────────────────────────────┘   │
│                                                 │
│  ┌─────────────────────────────────────────┐   │
│  │  code-server  :13337  (VS Code Web)     │   │
│  │  proxied via Coder path-based proxy     │   │
│  └─────────────────────────────────────────┘   │
│                                                 │
│  Coder agent  (reports back to Coder server)    │
└─────────────────────────────────────────────────┘
```

---

## Components

### Infrastructure (docker-compose.yml)

| Service    | Image                      | Role                                                   |
|------------|----------------------------|--------------------------------------------------------|
| `postgres` | `postgres:16-alpine`       | Coder metadata, workspace state, user sessions         |
| `dind`     | `docker:27-dind`           | Docker daemon — creates & manages workspace containers |
| `coder`    | `ghcr.io/coder/coder`      | Web UI, API, workspace lifecycle, agent relay          |

**Why DinD as a sidecar?**  
Coder's Docker provisioner needs a Docker socket. Running a dedicated DinD container isolates workspace containers from the host and avoids bind-mounting `/var/run/docker.sock`, which would give workspaces host root access.

### Workspace Template (`templates/devcontainer-dind/`)

The Terraform template provisions one Docker container per workspace with:

| Feature                  | How it works                                                                 |
|--------------------------|------------------------------------------------------------------------------|
| **VS Code Web**          | `code-server` installed & started in the agent `startup_script` on port 13337; surfaced as a `coder_app` with `subdomain = false` (path-based proxy) |
| **Docker-in-Docker**     | Container runs `privileged: true`; inner `dockerd` starts at container boot |
| **devcontainer support** | `@devcontainers/cli` runs `devcontainer up` on the cloned repo if a `.devcontainer/` is present |
| **Persistent storage**   | Named Docker volume mounted at `/workspaces` — survives workspace stop/start |
| **Dotfiles**             | Optional parameter; applied via `coder dotfiles` on startup                 |
| **Resource limits**      | User-selectable CPU cores and memory at workspace creation                   |

---

## Data Flow — Workspace Start

```
1. Developer opens https://coder.tailaa3fee.ts.net (served by tsdproxy)
2. Clicks "Start workspace" in Coder UI
3. Coder server runs Terraform (devcontainer-dind template)
4. Terraform creates a Docker container in the DinD sidecar:
     - privileged=true (for inner dockerd)
     - injects CODER_AGENT_TOKEN
     - mounts /workspaces volume
5. Container boots, Coder agent binary starts (injected init script)
6. Agent phones home to Coder server at https://coder.tailaa3fee.ts.net
7. startup_script runs:
     a. Waits for inner dockerd
     b. git clone <repo> → /workspaces/<name>
     c. Installs & starts code-server on :13337
     d. Runs `devcontainer up` if .devcontainer/ found
     e. Applies dotfiles
8. Coder UI shows "VS Code Web" button
     → https://coder.tailaa3fee.ts.net/@<user>/<workspace>/apps/code/
```

---

## Networking

| Connection                          | Protocol / Port               | Notes                                          |
|-------------------------------------|-------------------------------|------------------------------------------------|
| Browser → tsdproxy                  | HTTPS :443 (Tailnet)          | Auto-cert via Tailscale                        |
| tsdproxy → Coder container          | HTTP :7080                    | Internal; tsdproxy terminates TLS              |
| Coder → DinD                        | TCP :2375 (plain)             | Internal compose network only                  |
| Workspace agent → Coder server      | HTTPS to coder.tailaa3fee.ts.net | Through tsdproxy, or DERP relay             |
| Browser → VS Code Web               | HTTPS path-based proxy        | `/@<user>/<ws>/apps/code/` — no wildcard DNS   |
| Inner dockerd → internet            | Via host NAT                  | For pulling devcontainer images                |

### tsdproxy Integration

tsdproxy runs as a separate container on the **host** Docker daemon. It:
1. Watches the Docker socket for containers with `tsdproxy.enable: "true"`
2. Registers a Tailscale machine named `coder` → `coder.tailaa3fee.ts.net`
3. Provisions a Tailscale auto-cert for that hostname
4. Proxies inbound HTTPS from the Tailnet to the Coder container on port 7080

Labels on the `coder` service in `docker-compose.yml`:

```yaml
labels:
  tsdproxy.enable: "true"
  tsdproxy.name: "coder"          # → coder.tailaa3fee.ts.net
  tsdproxy.container_port: "7080"
  tsdproxy.scheme: "http"         # Coder runs plain HTTP; TLS handled by tsdproxy
  tsdproxy.tlsvalidate: "false"
```

### Why no `CODER_WILDCARD_ACCESS_URL`

tsdproxy creates **one Tailscale machine per container** with a fixed hostname. It does not support wildcard subdomain routing (`*.coder.tailaa3fee.ts.net`), which Coder needs for its subdomain-based port-forwarding feature.

**Impact:** VS Code Web is served via Coder's **path-based proxy** (`subdomain = false` in the template) at:
```
https://coder.tailaa3fee.ts.net/@<user>/<workspace>/apps/code/
```
This is fully functional. The only limitation is that each workspace port-forward requires a separate path, not a subdomain — which is fine for a personal or small-team Tailnet setup.

---

## VS Code Web — How it's served

`code-server` (open-source VS Code Web, maintained by Coder) runs inside the workspace container on port 13337. Coder's agent proxies it through the Coder server using a path-based URL:

```
https://coder.tailaa3fee.ts.net/@<user>/<workspace>/apps/code/?folder=/workspaces/<name>
```

The developer gets a full VS Code experience with extensions, terminal, Git integration, and Settings Sync — all in the browser, zero local setup.

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

| Risk                                | Mitigation                                                         |
|-------------------------------------|--------------------------------------------------------------------|
| DinD requires host privileges       | Isolated in dedicated DinD container; not bind-mounting host sock  |
| Workspace containers are privileged | Limit to trusted users; consider rootless Docker alternatives      |
| Coder UI access                     | Restricted to Tailnet via tsdproxy — not reachable from public internet |
| Docker daemon on TCP 2375 (plain)   | Internal compose network only; never exposed to host               |
| tsdproxy → Coder connection (HTTP)  | Internal host-level traffic only; TLS not needed here              |
| Devcontainer pulls arbitrary images | Coder can be configured with allowed registries (future)           |

---

## Open Questions / TODOs

- [ ] Build custom workspace base image (see above)
- [ ] Evaluate rootless Docker (sysbox, usernetes) as `privileged` alternative
- [ ] Coder template versioning strategy (push via `coder templates push`)
- [ ] Multi-node setup: run workspace containers on a separate VPS via remote Docker context
- [ ] Registry mirror / pull-through cache to speed up devcontainer image pulls
- [ ] Backup strategy for `postgres_data` and `coder_data` volumes
- [ ] Explore Tailscale Serve/Funnel as an alternative to tsdproxy if wildcard subdomain support is needed in the future
