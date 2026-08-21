# Placement reference — Helm chart

Loaded by `refactor-placement-scout` when the orchestrator detects `project type: helm-chart` (presence of `Chart.yaml`).

**Scope:** This reference applies to **locally-authored Helm charts** that ship `Chart.yaml` and `templates/` in-repo. Projects that consume an **external chart** (e.g., `dasmeta/base`) and only supply `values*.yaml` overrides are not `helm-chart` targets — they have no local templates to evaluate. The orchestrator's detection rule (presence of `Chart.yaml`) already filters those out; the scout should not flag missing `Chart.yaml` or `templates/` for values-only directories.

Anchored on [Helm chart best practices](https://helm.sh/docs/chart_best_practices/templates) and [Helm developing-charts docs](https://helm.sh/docs/developing_charts).

---

## Layer placement (where each kind of file lives)

### Chart root

- `Chart.yaml` — chart metadata. **Required.** Distinguish `version` (chart package version, semver-bumped on every change to templates / defaults / dependencies) from `appVersion` (the version of the application this chart deploys). Don't conflate them.
- `values.yaml` — default values; should work out-of-the-box for a dev environment.
- `values-staging.yaml`, `values-production.yaml` — environment-specific overrides. Not a Helm convention, but a widely-used pattern. Apply with `-f values-production.yaml` at install time.
- `values.schema.json` — JSON Schema for `values.yaml`; Helm validates user-supplied values before rendering.
- `README.md` — chart documentation; describes values and provides install/upgrade examples.
- `LICENSE`, `.helmignore`.

### `templates/`

One Kubernetes resource per file. File names are dashed (lowercase-with-dashes), not camelCase:

- `deployment.yaml`, `service.yaml`, `ingress.yaml`, `configmap.yaml`, `secret.yaml`, `serviceaccount.yaml`, `hpa.yaml`, `pdb.yaml`, `networkpolicy.yaml`, `cronjob.yaml`, `job.yaml`, etc.
- `_helpers.tpl` — Go template helpers (the `_`-prefix prevents Helm from rendering it as a manifest). Define reusable templates here (labels, fullname, selectors). Defined templates must be **namespaced** (e.g. `{{ define "mychart.labels" }}`).
- `NOTES.txt` — human-readable post-install notes shown after `helm install`.
- `tests/` — Helm test pods (`helm test`); validate the chart deploys correctly.

### `charts/`

Subchart dependencies (when not declared via `dependencies` in `Chart.yaml`). Subchart `.tgz` files or unpacked subchart directories live here.

### `crds/`

Custom Resource Definitions (Helm 3+). Installed before templates; not templated.

---

## Universal principles applied to Helm

- **One resource per template file** — easier to find, easier to diff.
- **Dashed file names** — convention; tools sort and group by name.
- **Helpers in `_helpers.tpl`** — never repeat label/selector/fullname blocks across templates.
- **`required` template function** for values that must be supplied at install time — fail at render time with a clear message rather than producing a broken manifest.
- **`app.kubernetes.io/*` labels** consistently applied via a helper (Argo CD, Kiali, your-cluster-cli all use them).
- **`values.schema.json`** for any chart consumed by others — catches user errors before render.

---

## Common Helm drift the scout should flag

- **Multiple resources in one `.yaml` file** in `templates/` — Grab-bag File. Verdict: `warning`. Split per resource.
- **CamelCase template file names** (`myAppDeployment.yaml`) — Naming-as-Documentation. Verdict: `warning`. Use dashes.
- **Inline label blocks repeated across templates** — Duplicated Code at the template level. Verdict: `warning`. Promote to `_helpers.tpl`.
- **`appVersion` and `version` updated together as if they're the same** — drift on the `Chart.yaml` semantics. Verdict: `warning`.
- **Hardcoded values in templates** that should be parameterized in `values.yaml` — Magic Numbers / Magic Strings at the chart level. Verdict: `warning`.
- **Environment-specific logic in `values.yaml`** instead of in `values-<env>.yaml` overrides — Misplaced configuration. Verdict: `warning`.
- **`required` checks inside `values.yaml`** rather than in template render via `required` template function — Misplaced validation. Verdict: `warning`.

---

## What "aligned" looks like (target shape)

```
mychart/
├── Chart.yaml                # name, version (semver), appVersion
├── values.yaml               # dev-friendly defaults
├── values-staging.yaml       # staging overrides
├── values-production.yaml    # prod overrides
├── values.schema.json        # JSON Schema validation
├── README.md
├── .helmignore
├── charts/                   # subcharts (deps)
├── crds/                     # CRDs (Helm 3+)
└── templates/
    ├── _helpers.tpl          # reusable defines (labels, fullname)
    ├── deployment.yaml       # one Deployment
    ├── service.yaml          # one Service
    ├── ingress.yaml
    ├── configmap.yaml
    ├── secret.yaml
    ├── serviceaccount.yaml
    ├── hpa.yaml
    ├── NOTES.txt
    └── tests/
        └── test-connection.yaml
```
