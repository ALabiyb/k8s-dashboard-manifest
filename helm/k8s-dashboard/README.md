<!--
---------------------------------------------------------------------------
Author: Labiyb M. Said — DevSecOps Engineer
Contact: saidlabiybm@gmail.com
---------------------------------------------------------------------------
-->
# k8s-dashboard Helm chart

Packages the read-only Kubernetes dashboard, its bundled Loki + Promtail log
stack, and the k8s-audit-collector subchart, replacing the raw manifests
previously kept in `../../k8s/` and `../../k8s-collector/`.

Resource names (ConfigMap `dashboard-config`, Secret `dashboard-secrets`,
Deployment `k8s-dashboard`, `loki`, `promtail`, ClusterRole
`k8s-dashboard-reader`, ...) intentionally match what's already live on the
SoftNet clusters, so installing this chart into the same namespace with
equivalent values is a drop-in replacement, not a migration.

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

## What's parameterized vs. fixed

- **Parameterized**: image repo/tag, replica count/resources, HTTPRoute
  hostname/Gateway (or disable it entirely for Ingress/other routing),
  company name & branding text, SMTP/email alerting, OIDC/Keycloak SSO,
  RBAC creation + optional cluster-admin binding for a platform-admin group,
  Loki/Promtail enable + sizing, k8s-collector enable + DB connection.
- **Fixed by design**: resource *names* (see above — this is what makes it a
  safe drop-in replacement), the probe paths/timings, and the security
  contexts (non-root, dropped capabilities, read-only root filesystem).

## Known live-repo inconsistency (not fixed by this chart)

The `prod` branch of the raw `k8s/01-configmap.yaml` in this repo still
literally says `APP_ENV: "Development Cluster"` and uses `.dev.` hostnames —
it was never actually customized for prod, despite the file's own comments
claiming per-branch values. This chart fixes that by making `config.appEnv`,
`config.oidc.redirectURL`, and `config.email.dashboardURL` real values you
must set per install — but nobody has gone back and corrected the *raw*
`prod` branch file. Worth a look before retiring the raw manifests.

## ArgoCD migration

The live Applications (`../../argocd/k8s-dashboard-*.yaml`,
`k8s-collector-*.yaml`) currently point `source.path` at the raw `k8s` /
`k8s-collector` folders. See `argocd/*.yaml.helm-example` in this directory
for what pointing them at this chart instead would look like — these are
examples only; the real Application files were intentionally left untouched.

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
