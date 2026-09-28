<!--
---------------------------------------------------------------------------
Author: Labiyb M. Said — DevSecOps Engineer
Contact: saidlabiybm@gmail.com
---------------------------------------------------------------------------
-->
# k8s-dashboard Helm chart

Packages a **read-only Kubernetes cluster dashboard** — pods, deployments,
nodes, namespaces, an audit log of who-did-what, and log viewing — plus
its bundled logging stack and audit collector, replacing the raw manifests
previously kept in `../../k8s/` and `../../k8s-collector/`.

If you've never used Helm before, read "New to Helm?" below first. If you
just need the install command, skip to [Install](#install).

---

## New to Helm?

A **Helm chart** is a template for a set of Kubernetes objects. Instead of
hand-editing raw YAML for every environment, you fill in one `values.yaml`
with your settings, and Helm generates the final Kubernetes YAML for you.

- `values.yaml` — every setting this chart understands, with sensible
  defaults. You override pieces of it with `--set` flags or your own
  values file — you don't need to edit this file directly.
- `charts/k8s-collector/` — a **subchart**: a second, smaller chart bundled
  inside this one, because the dashboard's Audit Log page needs it to work.
  Its own settings live under this chart's `values.yaml` `k8sCollector:`
  key.
- `helm dependency update .` — links the subchart in. **Run this once
  before `helm lint`/`helm template`/`helm install`**, or Helm won't know
  about `charts/k8s-collector/`.
- `helm template` — renders the final YAML to your screen without touching
  any cluster. Always safe.
- `helm install` — renders the YAML *and* applies it to whatever cluster
  your `kubectl` is currently pointed at. This changes real infrastructure.

---

## Architecture — what this app actually does

```
  kube-apiserver ──(watch API)──→ k8s-dashboard ──→ browser
  (read-only: pods, deploys,       (THIS chart's                 view pods,
   nodes, namespaces, RBAC)         main Deployment)              deployments,
                                          │                        nodes, logs,
                                          │ reads                  audit trail
                                          ▼
                                  ┌───────────────┐
                                  │ Loki + Promtail│ ← Promtail tails every
                                  │  (bundled,      │   node's /var/log/pods,
                                  │  loki.enabled)   │   Loki stores it, the
                                  └───────────────┘   dashboard's Logs page
                                                       queries Loki

  kube-apiserver audit ──webhook──→ k8s-collector ──→ Postgres ──→ k8s-dashboard
  log (every API call,             (bundled subchart,  (audit      Audit Log page
   who did what)                    DaemonSet on        trail)     (superadmin only)
                                     control-plane
                                     nodes)

  Keycloak (optional) ──OIDC login──→ k8s-dashboard
```

**Three access levels**, all via Keycloak group membership (or two static
local accounts if you don't use Keycloak):
- **superadmin** — everything an admin has, **plus** the Audit Log page.
  Deliberately a *separate* group from admin, so a cluster operator can't
  read the trail of their own actions.
- **admin** — cluster-wide operational access (the resources this
  dashboard's RBAC grants — see `rbac.create` below).
- **viewer** — read-only. Can be scoped to specific namespaces via
  `k8s-<namespace>-view`/`-edit` Keycloak groups, or given cluster-wide
  read via a `k8s-managers-view` group membership.

**What's currently live on SoftNet's dev cluster** (namespace
`k8s-dashboard`), as a concrete example of what these values mean in
practice:
- `config.companyName` = `"SoftNet Technologies"`, `config.appEnv` =
  `"Development Cluster"`
- `config.oidc.adminGroup` = `k8s-cluster-admins`,
  `config.oidc.superadminGroup` = `k8s-platform-admins`
- Email alerting is on, notifying `lsaid@softnet.co.tz` only on state
  changes (not every poll)
- `image.tag` on dev is a git-SHA build tag (e.g. `dev-3f292ad`), not a
  semantic version — see [Known gaps](#known-gaps--judgment-calls) below

---

## What's in this chart

| File | Kubernetes object | What it's for |
|---|---|---|
| `templates/configmap.yaml` | ConfigMap | Non-secret settings — company name, thresholds, OIDC config, email config |
| `templates/deployment.yaml` | Deployment | The dashboard app itself (1 replica — sessions are in-memory) |
| `templates/service.yaml` | Service | Exposes the app's HTTP port inside the cluster |
| `templates/httproute.yaml` | HTTPRoute (Gateway API) | Optional public hostname routing |
| `templates/secret.yaml` | Secret | Login credentials, session/embed tokens, SMTP password, OIDC client secret, audit webhook token |
| `templates/serviceaccount.yaml` + `clusterrole.yaml` + `clusterrolebinding.yaml` | RBAC | Read-only access to the resources the dashboard displays, plus an optional cluster-admin binding for the superadmin group |
| `templates/audit-pvc.yaml` | PersistentVolumeClaim | Currently unused — see [Notable design choices](#notable-design-choices--things-to-sign-off-on) |
| `templates/loki.yaml` | Deployment + PVC + Service | Bundled single-binary Loki — stores logs for the Logs page |
| `templates/promtail.yaml` | DaemonSet + RBAC | Tails every node's pod logs into Loki |
| `charts/k8s-collector/` | Subchart (see below) | Feeds the Audit Log page |

### The `k8s-collector` subchart

A separate small chart, bundled because the Audit Log page needs it:

| File | Kubernetes object | What it's for |
|---|---|---|
| `templates/namespace.yaml` | Namespace | Its own namespace (only if `k8sCollector.createNamespace: true`) |
| `templates/daemonset.yaml` | DaemonSet | Runs on control-plane nodes only (`nodeSelector`) — `kube-apiserver`'s audit log is mode `600 root:root`, so this has to run as root, right where the file is |
| `templates/secret.yaml` | Secret | Postgres connection string |
| `templates/cronjob-retention.yaml` | CronJob | Deletes audit rows older than `k8sCollector.retention.days` (default 90), daily |

---

## Before you install: decisions to make

1. **Do you have Keycloak?** If yes, fill in `config.oidc.*` +
   `secret.oidcClientSecret`. If no, leave `config.oidc.enabled: false` —
   the app falls back to the two static local accounts (see
   [Secrets](#secrets) below).
2. **Do you want the Audit Log page?** It needs `k8sCollector.enabled: true`
   (the default) *and* a Postgres database — either let the subchart create
   a throwaway one for testing (`db.create: true`, the default) or point
   `auditDB.existingSecretName` at a real one.
3. **Do you want the Logs page?** Needs `loki.enabled: true` (the default).
   Turn both `loki.enabled` and `config.logs.enabled` off together if you
   don't want to run a log stack at all.
4. **Does your cluster schedule pods on control-plane nodes?** The
   `k8s-collector` DaemonSet needs to — that's where the audit log file
   lives. If your control-plane is fully managed/inaccessible (e.g. some
   managed Kubernetes offerings), the Audit Log feature won't work
   regardless of chart settings.
5. **Does your cluster have Gateway API installed?** If not, set
   `httpRoute.enabled: false`.

---

## Preview

```sh
helm dependency update .
helm lint .
helm template my-release . --namespace k8s-dashboard
```

## Install

```sh
helm dependency update .
helm install k8s-dashboard . \
  --namespace k8s-dashboard --create-namespace \
  -f values.yaml \
  --set image.tag=<your-build-tag> \
  --set config.oidc.enabled=true \
  --set config.oidc.issuerURL=https://your-keycloak/realms/YourRealm \
  --set secret.create=false \
  --set secret.existingSecretName=<your-vault-managed-secret>
```

**Secrets on a fresh install**: `secret.dashboardSecret`, `secret.embedToken`,
and `secret.auditWebhookToken` are pure random tokens — leave them blank
and they auto-generate on first install, staying stable across upgrades (so
`helm upgrade` never silently invalidates sessions or the audit webhook).
`secret.adminUser`/`adminPass`/`viewerUser`/`viewerPass` are **also**
deliberately left blank by default — the app itself falls back to
`admin`/`admin` and `viewer`/`viewer` when they're unset, and logs a
"default credentials in use" warning every time it does. That's fine for a
five-minute eval; set real values before anyone relies on this install.

---

## What's parameterized vs. fixed

- **Parameterized**: image repo/tag, replica count/resources, HTTPRoute
  hostname/Gateway (or disable it entirely for Ingress/other routing),
  company name & branding text, SMTP/email alerting, OIDC/Keycloak SSO,
  RBAC creation + optional cluster-admin binding for a platform-admin group,
  Loki/Promtail enable + sizing, k8s-collector enable + DB connection.
- **Fixed by design**: resource *names* (ConfigMap `dashboard-config`,
  Secret `dashboard-secrets`, Deployment `k8s-dashboard`/`loki`/`promtail`,
  ClusterRole `k8s-dashboard-reader`, ...) — this is what makes installing
  into an existing namespace with equivalent values a **drop-in
  replacement, not a migration** — plus the probe paths/timings and the
  security contexts (non-root, dropped capabilities, read-only root
  filesystem).

## ArgoCD migration

The live Applications (`../../argocd/k8s-dashboard-*.yaml`,
`k8s-collector-*.yaml`) currently point `source.path` at the raw `k8s` /
`k8s-collector` folders. See `argocd/*.yaml.helm-example` in this directory
for what pointing them at this chart instead would look like — these are
examples only; the real Application files were intentionally left untouched.

---

## Full values reference

### Image, scaling, scheduling

| Key | Default | What it does |
|---|---|---|
| `image.repository` / `.tag` | SoftNet's real values | **Change these** for any other cluster. |
| `replicaCount` | `1` | Kept at 1 by design — user sessions live in the pod's memory, not a shared store. Scaling this up without also externalizing sessions will randomly log people out. |
| `controlPlaneAffinity.enabled` | `true` | Pins the dashboard pod to control-plane nodes so audit webhook events don't cross node boundaries. Turn off on a cluster where you can't/don't schedule there. |

### Networking

| Key | Default | What it does |
|---|---|---|
| `service.port` / `.targetPort` | `80` / `8080` | Standard Service fields. |
| `httpRoute.enabled` | `true` | Gateway API public routing — turn off for clusters without Gateway API, use your own Ingress/routing instead. |
| `httpRoute.gatewayName` / `.gatewayNamespace` / `.hostname` | example values | Which Gateway this attaches to, and the public hostname. |

### RBAC

| Key | Default | What it does |
|---|---|---|
| `rbac.create` | `true` | Grants read-only cluster access to the resources the dashboard displays. |
| `rbac.platformAdminGroup` | `""` | Keycloak group to bind to `cluster-admin`. **Empty by default on purpose** — granting cluster-admin out of the box felt like the wrong default for a chart meant to run on someone else's cluster. Set this to reproduce SoftNet's live behavior (`k8s-platform-admins`). |
| `serviceAccount.create` / `.name` | `true` / `"k8s-dashboard"` | Standard fields. |

### App config (`config.*`)

| Key | Default | What it does |
|---|---|---|
| `config.appEnv` | `"Development Cluster"` | Shown in the dashboard's header badge. |
| `config.companyName` | `"Your Company"` | Shown throughout the UI. |
| `config.pollInterval` | `30s` | How often the dashboard re-reads cluster state. |
| `config.excludedNamespaces` | system namespaces | Namespaces hidden from the dashboard's views entirely. |
| `config.thresholds.healthy` / `.degraded` | `100` / `70` | Health-score cutoffs shown in the UI. |

### Email alerting (`config.email.*`, optional)

| Key | Default | What it does |
|---|---|---|
| `config.email.enabled` | `false` | Master switch. |
| `config.email.smtpHost` / `.smtpPort` / `.smtpUsername` / `.from` | example values | Your SMTP server. |
| `config.email.fromDisplayName` | `"K8s Dashboard"` | Sender display name — kept separate from the envelope address because some providers (Zoho included) reject envelopes that carry a display name. |
| `config.email.to` | `[]` | Recipients. |
| `config.email.onStateChangeOnly` | `true` | Email only when a resource's health *changes*, not on every poll — set `false` for a noisier "remind me every cycle" mode. |
| `config.email.dashboardURL` | example | The "View dashboard" link in the alert email body. |
| `config.email.htmlBody` | `true` | Styled HTML email vs. plain text. |

### Keycloak SSO (`config.oidc.*`, optional)

| Key | Default | What it does |
|---|---|---|
| `config.oidc.enabled` | `false` | **Leave false to use local accounts only** (see Secrets below). |
| `config.oidc.issuerURL` / `.clientID` / `.redirectURL` | `""` / `"k8s-dashboard"` / `""` | Standard OIDC client fields. |
| `config.oidc.adminGroup` | `""` | Keycloak group → admin role. |
| `config.oidc.superadminGroup` | `""` | Keycloak group → superadmin role (admin + Audit Log access). Kept as a **separate** group from `adminGroup` on purpose — see Architecture above. |
| `config.oidc.tlsSkipVerify` | `false` | Set `true` only for an internal Keycloak with a self-signed/internal-CA certificate. |

### Logs page

| Key | Default | What it does |
|---|---|---|
| `config.logs.enabled` | `true` | Hides the Logs page entirely if `false` (independent of `loki.enabled` below — both need to be true for logs to actually work). |

### Secrets

| Key | Default | What it does |
|---|---|---|
| `secret.create` | `true` | `false` to use an existing, externally-managed Secret instead (recommended beyond a quick local install). |
| `secret.existingSecretName` | `""` | Required when `secret.create: false`. |
| `secret.adminUser` / `.adminPass` / `.viewerUser` / `.viewerPass` | `""` | **Deliberately blank** — see "Secrets on a fresh install" above. |
| `secret.dashboardSecret` / `.embedToken` / `.auditWebhookToken` | `""` | Pure random tokens — leave blank, they auto-generate and stay stable across upgrades. |
| `secret.smtpPassword` | `""` | Required if `config.email.enabled: true`. |
| `secret.oidcClientSecret` | `""` | Required if `config.oidc.enabled: true`. |

### Bundled Loki (logs storage)

| Key | Default | What it does |
|---|---|---|
| `loki.enabled` | `true` | Turn off if you already run Loki elsewhere, or don't want the Logs page. |
| `loki.persistence.storageClassName` | `rook-ceph-block` | **Must support ReadWriteOnce** (single replica, so RWO is enough) — change to whatever StorageClass your cluster actually has. |
| `loki.persistence.size` | `20Gi` | SoftNet's live clusters run `100Gi` after repeatedly filling a smaller PVC (see the app source's Loki incident history) — size up if you expect similar log volume. |
| `loki.retentionPeriod` | `168h` (7 days) | How long logs are kept. |

### Bundled Promtail (log shipping)

| Key | Default | What it does |
|---|---|---|
| `promtail.enabled` | `true` | DaemonSet tailing every node's `/var/log/pods` into Loki. |

### k8s-collector subchart (`k8sCollector.*`)

| Key | Default | What it does |
|---|---|---|
| `k8sCollector.enabled` | `true` | Turn off if you already run your own audit collector, or don't need the Audit Log page. |
| `k8sCollector.image.repository` / `.tag` | SoftNet's real values | **Change for any other cluster.** |
| `k8sCollector.filterHumansOnly` | `true` | Collects only human-user API calls by default; `false` also collects system accounts (`kube-scheduler`, etc.). |
| `k8sCollector.db.create` | `true` | Creates a Secret with a **placeholder** Postgres connection string — you must fill in real values, or point `db.existingSecretName` at a real one instead. |
| `k8sCollector.retention.days` | `90` | How long audit rows are kept before the daily CronJob deletes them. |
| `k8sCollector.retention.schedule` | `"0 2 * * *"` | When the retention CronJob runs (cron syntax, UTC). |

### Audit log local persistence (mostly unused — see below)

| Key | Default | What it does |
|---|---|---|
| `persistence.auditLog.enabled` | `false` | See [Notable design choices](#notable-design-choices--things-to-sign-off-on) — the live Deployment doesn't actually use this. |

---

## Troubleshooting a first install

- **`helm install` fails immediately, complains about a missing chart**:
  you skipped `helm dependency update .` — the subchart has to be linked
  in first.
- **Login works but only `admin`/`admin` and `viewer`/`viewer` succeed,
  and you didn't expect that**: you left `secret.adminUser`/`adminPass`
  blank. This is the intended safe fallback, not a bug — set real values.
- **Audit Log page is empty / errors**: check `k8sCollector.enabled` is
  `true`, that its DaemonSet actually has pods running (it only schedules
  on control-plane nodes — see `controlPlaneAffinity`), and that
  `auditDB.existingSecretName` (or `k8sCollector.db.*`) points at a
  reachable Postgres.
- **Logs page is empty**: confirm both `loki.enabled` and
  `config.logs.enabled` are `true`, and check the `promtail` DaemonSet
  pods are actually running on your nodes.
- **Superadmin group members can't see the Audit Log page**: double-check
  `config.oidc.superadminGroup` is set — it's a *different* setting from
  `config.oidc.adminGroup`, and admins alone don't get audit access by
  design.

## Known live-repo inconsistency (not fixed by this chart)

The `prod` branch of the raw `k8s/01-configmap.yaml` in this repo still
literally says `APP_ENV: "Development Cluster"` and uses `.dev.` hostnames —
it was never actually customized for prod, despite the file's own comments
claiming per-branch values. This chart fixes that by making `config.appEnv`,
`config.oidc.redirectURL`, and `config.email.dashboardURL` real values you
must set per install — but nobody has gone back and corrected the *raw*
`prod` branch file. Worth a look before retiring the raw manifests.

## Notable design choices / things to sign off on

- `k8s-collector` is bundled as a Helm **subchart** (`charts/k8s-collector/`)
  rather than a third top-level chart, since it's a required companion for
  the Audit Log page to work, not a separately versioned product. It's still
  independently disableable (`k8sCollector.enabled: false`) and still has its
  own `argocd/k8s-collector-*.yaml.helm-example` if you'd rather deploy it as
  its own ArgoCD Application pointed at `charts/k8s-collector` directly.
- `rbac.platformAdminGroup` defaults to **empty** (no cluster-admin binding
  created), unlike the live manifests which always create one for
  `k8s-platform-admins`. Set it explicitly to reproduce current SoftNet
  behavior — granting cluster-admin by default felt like the wrong default
  for a chart meant to run on other people's clusters.
- `persistence.auditLog.enabled` defaults to **false**: the live Deployment
  already mounts `audit-log-storage` as an `emptyDir`, not the PVC — the PVC
  in the raw manifests is currently unused dead weight. The template is kept
  for anyone who wants to switch back to persisting the local file.
- Only one `values.yaml` is shipped (no `values-dev/uat/prod.yaml`): a diff
  across all three live branches showed zero differences in `k8s/` or
  `k8s-collector/` today — dev/uat/prod are separate physical clusters each
  running their own ArgoCD off the same file content, not one cluster
  differentiated by values. Add per-cluster values files if/when real
  per-cluster differences emerge.
- `secret.adminUser`/`adminPass`/`viewerUser`/`viewerPass` default to blank
  rather than a placeholder like `"change-me"` — a literal default value
  would silently *become* the real password and suppress the app's own
  "default credentials in use" startup warning (which only fires when these
  env vars are genuinely unset). Blank lets that built-in safety net do its
  job instead of working around it.
