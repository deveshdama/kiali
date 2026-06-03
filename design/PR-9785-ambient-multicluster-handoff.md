# PR #9785 — Ambient multicluster fix: analysis & handoff

> Working notes for [PR #9785](https://github.com/kiali/kiali/pull/9785)
> ("[Ambient] Check all clusters for ambientEnabled, not just home cluster").
>
> This file is intended for another contributor or AI agent to pick up the
> remaining work without needing the originating conversation context.

## 1. Context

**Linked issue:** #9784

**Topology that triggers the bug class:** standalone management cluster
(`ignore_home_cluster=true`). Kiali runs on a management cluster that
has no Istio, no Gateway API CRDs, no ztunnel. All mesh state lives on
remote member clusters.

**Core symptom:** several "global" capability flags returned by
`GET /api/config` are computed from the home cluster only. When the
home cluster is empty (standalone-mgmt), those flags are wrongly
`false`, and the UI degrades accordingly.

## 2. The bug pattern

The repeating anti-pattern across `handlers/config.go` and
`cache/cache.go` is:

> Compute a **mesh-wide capability flag** (or default list) by
> querying only the **home cluster's** k8s client.

Under `ignore_home_cluster=true` the home cluster is not
representative of the mesh, so the flag/list returned to the UI is
wrong.

## 3. Findings inventory

All five findings are instances of the same anti-pattern.

| # | Site | Global thing it computes | Status |
|---|---|---|---|
| 1 | `handlers/config.go:180` calling `IsAmbientEnabled(homeCluster)` | `ambientEnabled` JSON flag | ✅ Fixed in commits already on the PR branch (`a0c8599`, `0877400`, `c852ac7`) |
| 2 | `cache/cache.go:702` inside `GatewayAPIClasses()`: `IsAmbientEnabled(cluster)` | Whether `istio-waypoint` appears in the default Gateway Classes | ✅ Fixed on `fix/ambient-enabled-multicluster-wip` (commit `f2da9d0`) — aggregates across `c.clients` via `IsAmbientEnabledInAnyCluster` |
| 2b | `cache/cache.go:642` inside `GatewayAPIClasses()`: `!userClient.IsGatewayAPI()` early return | The whole `GatewayAPIClasses` list — returns `[]` when home cluster has no Gateway API CRDs | ✅ Fixed on `fix/ambient-enabled-multicluster-wip` (commit `f2da9d0`) — handler now iterates `accessibleClusters`, calls `cache.GatewayAPIClasses(cluster)` per cluster, dedupes by `ClassName` |
| 3 | `handlers/config.go:168` calling `client.IsGatewayAPI()` on home cluster only | `gatewayAPIEnabled` JSON flag | ❌ **Not fixed** |
| 4 | `handlers/config.go:169` calling `client.IsIstioGateway()` on home cluster only | `istioGatewayInstalled` JSON flag | ❌ **Not fixed** |
| 5 | `handlers/config.go:170` calling `client.IsIstioAPI()` on home cluster only | `istioAPIInstalled` JSON flag | ❌ **Not fixed** |

## 4. Frontend impact map

What each flag actually gates in the UI.

### `ambientEnabled` (#1, fixed on PR branch)
| Frontend consumer | What it does |
|---|---|
| `services/GraphDataSource.ts:219` | Adds the `ambient` appender to graph requests |
| Graph toolbar Ambient Traffic dropdown | Shown/hidden |
| `components/MissingSidecar/MissingSidecar.tsx` | Switches "Missing sidecar" → "Out of mesh" wording |
| `components/Ambient/ZtunnelMetrics.tsx`, `pages/Mesh/target/TargetPanelMetrics.tsx` | Adds `includeAmbient` to metrics queries |
| `components/VirtualList/Config.ts` | Toggles workload-list ambient column |
| `components/IstioWizards/ServiceWizardDropdown.tsx:72` | Waypoint wizard option for ambient workloads |

### `GatewayAPIClasses` (#2 + #2b, fixed on wip branch)
| Frontend consumer | What it does |
|---|---|
| `pages/IstioConfigNew/K8sGatewayForm.tsx:29,116,140,147` | Gateway Class dropdown in the "create K8s Gateway" form |
| `components/IstioWizards/K8sGatewaySelector.tsx:61,223,237` | Gateway Class dropdown in the K8s gateway service-wizard |

### `gatewayAPIEnabled` (#3, unfixed)
| Frontend consumer | What it does |
|---|---|
| `components/IstioActions/IstioActionsNamespaceDropdown.tsx:55` | Disables "K8s …" create entries in per-namespace Actions dropdown |
| `components/IstioWizards/ServiceWizardActionsDropdownGroup.tsx:87` | Disables `WIZARD_K8S_REQUEST_ROUTING` and `WIZARD_K8S_GRPC_REQUEST_ROUTING` |

### `istioGatewayInstalled` (#4, unfixed)
| Frontend consumer | What it does |
|---|---|
| `components/IstioActions/IstioActionsNamespaceDropdown.tsx:57` | Disables the "Gateway" create entry |
| `components/IstioWizards/ServiceWizard.tsx:1079` | Hides the entire "Gateways" tab in the Service wizard |

### `istioAPIInstalled` (#5, unfixed)
| Frontend consumer | What it does |
|---|---|
| `components/IstioActions/IstioActionsNamespaceDropdown.tsx:59` | Disables ServiceEntry, Sidecar create entries |
| `components/IstioWizards/ServiceWizardActionsDropdownGroup.tsx:99` | Disables Istio traffic-management wizards (request routing, traffic shifting, fault injection, mirroring, TCP shifting) |

## 5. Net user-visible state on standalone-mgmt with the wip branch state

### Working after #1 + #2 + #2b
- Ambient Traffic dropdown visible, graph defaults to `total`
- Graph edges render real ambient L7 traffic (not all-TCP)
- Ambient metrics load
- Workload list ambient column present
- "Out of mesh" wording instead of "Missing sidecar"
- Waypoint wizard option visible
- K8s Gateway Class dropdown in create form now populated with the
  aggregated set (real classes from any accessible cluster plus
  defaults when nothing is discovered, including `istio-waypoint`)

### Still broken (because of #3, #4, #5)
- Most Istio/K8s create wizards greyed out in IstioActions dropdown
- Service Wizard's "Gateways" tab hidden
- K8s/Istio traffic-management wizards disabled in Service detail
- ServiceEntry / Sidecar create disabled

## 6. Codebase pattern for "per-cluster vs mesh-wide"

The cache and business layers in this repo have a consistent pattern.

### Rule 1: Cache methods are per-cluster
Every public cache method that depends on cluster-specific data takes
a `cluster string` parameter. Examples:
- `IsAmbientEnabled(cluster string) bool`
- `GetZtunnelPods(cluster string) []v1.Pod`
- `GetNamespaces(cluster string, token string) ([]models.Namespace, bool)`
- `GetKubeCache(cluster string) (client.Reader, error)`
- `GatewayAPIClasses(cluster string) []config.GatewayAPIClass`

Results are keyed per cluster (e.g. `ambientChecksPerCluster`).

### Rule 2: Aggregation happens at the business/handler layer
Business services iterate `userClients` to fan out:
```go
// business/workloads.go:236 — GetGateways
for cluster := range in.userClients {
    workloads, _ := in.GetAllWorkloads(ctx, cluster, "")
    ...
}

// business/namespaces.go:97 — GetNamespaces
for cluster, client := range in.userClients {
    cachedNamespaces, _ := in.kialiCache.GetNamespaces(cluster, client.GetToken())
    ...
}
```
Similar in `apps.go:261`, `services.go:71`, `istio_status.go:125`,
`istio_config.go:144`, `workloads.go:2466`.

### Rule 3: Cluster lists are first-class
`NamespaceService` exposes two helpers that name the scopes:
```go
GetClusterList() []string        // current user's accessible clusters
GetKialiSAClusterList() []string // clusters Kiali's SA can reach
```
This is the same distinction as `userClients` (per-request,
auth-scoped) vs `c.clients` in the cache (Kiali's SA, all configured
clusters).

### Exception: `IsAmbientEnabledInAnyCluster`
The original PR added a cache-level aggregator. This is defensible
because per-cluster results are already cached, the aggregation is
logic-free (`||`), and it lets callers reuse the per-cluster cache
cheaply. But it is the only aggregator method in the cache. Future
work should default to following Rule 1/2 unless there's a clear
reason to put aggregation in the cache.

## 7. Recommended fix shape for #3, #4, #5

Smallest, idiomatic fix. In `handlers/config.go`, replace the
home-cluster-only block with:

```go
// gatewayAPIEnabled / istioAPIInstalled / istioGatewayInstalled are
// global UI capability flags; aggregate across all clusters this
// user can access so the standalone-management topology
// (ignore_home_cluster=true) reports capabilities present on remote
// member clusters.
for _, client := range userClients {
    if client == nil {
        continue
    }
    if client.IsGatewayAPI() {
        publicConfig.GatewayAPIEnabled = true
    }
    if client.IsIstioGateway() {
        publicConfig.IstioGatewayInstalled = true
    }
    if client.IsIstioAPI() {
        publicConfig.IstioAPIInstalled = true
    }
}
```

**Risk to weigh with reviewers:** the frontend treats these as
"capability available somewhere → enable the wizard." If a wizard's
write path targets the home cluster specifically, enabling it could
surface latent bugs where the write fails. This is a UI-semantics
change that frontend reviewers should weigh in on.

**Tests to add:** mirror
`TestConfigHandlerAmbientEnabledChecksAllClusters` in
`handlers/config_test.go`. One handler test per flag where the home
cluster lacks the capability and a remote cluster has it, asserting
the flag is `true`.

## 8. Current branch state

### PR branch `fix/ambient-enabled-multicluster` (pushed)
- `a0c8599` [Ambient] Check all clusters for ambientEnabled, not just home cluster
- `0877400` cache: aggregate ambient check via IsAmbientEnabledInAnyCluster
- `c852ac7` rename ambientClusters to accessibleClusters

### WIP branch `fix/ambient-enabled-multicluster-wip` (pushed)
Branches off the PR branch with one extra commit:
- `f2da9d0` WIP: fix GatewayAPIClasses and add ambient external kiali script
  - `cache/cache.go` — line-702 fix (aggregate ambient via
    `IsAmbientEnabledInAnyCluster(allClusters)` from `c.clients` keys)
  - `cache/cache_test.go` — adds
    `TestGatewayAPIClasses/DefaultValuesWithAmbientOnRemoteCluster`
  - `handlers/config.go` — handler now iterates `accessibleClusters`,
    calls `cache.GatewayAPIClasses(cluster)` per cluster, dedupes by
    `ClassName` (fixes #2b)
  - `handlers/config_test.go` — extends
    `TestConfigHandlerAmbientEnabledChecksAllClusters` to assert
    `istio-waypoint` appears in the aggregated
    `confResp.GatewayAPIClasses`
  - `hack/istio/multicluster/install-ambient-external-kiali.sh` — new
    setup script for the ambient + external-kiali topology
  - `hack/istio/multicluster/ambient-external-kiali-plan.md` — design
    plan for the setup script

## 9. Open question to reviewers (drafted, not posted)

The intent is to ask `@josunect` and `@jshaughn` for explicit scope
direction before pushing further commits to the PR branch.

> **Bubbling these up for consensus on PR scope** — I'd appreciate
> your call.
>
> While addressing the line-702 comment, I noticed three sibling
> places with the same home-cluster-only pattern. They affect the
> same standalone-management topology this PR is fixing, but the
> blast radius and review surface differ.
>
> **Sibling flags in `handlers/config.go:167-171`**
> ```go
> if client := userClients[conf.KubernetesConfig.ClusterName]; client != nil {
>     publicConfig.GatewayAPIEnabled     = client.IsGatewayAPI()
>     publicConfig.IstioGatewayInstalled = client.IsIstioGateway()
>     publicConfig.IstioAPIInstalled     = client.IsIstioAPI()
> }
> ```
> The frontend treats these as global capability flags
> (`IstioActionsNamespaceDropdown.tsx`, `ServiceWizard.tsx` Gateways
> tab, `ServiceWizardActionsDropdownGroup.tsx`). Under
> `ignore_home_cluster=true` they all go `false`, disabling most
> Istio/K8s wizards and tabs in the UI. Fix is small (aggregate
> across `userClients`), but it shifts wizard *visibility* semantics
> across the UI — likely deserves frontend reviewer eyes on whether
> the wizards can actually target a remote cluster from the rendered
> form.
>
> **Scope options:**
> 1. Keep this PR ambient-scoped (current state on the PR branch),
>    file follow-up issues for the three sibling flags
> 2. Include the sibling-flags fix here as well
>
> My lean is (1) — keeps the diff focused on what the title and issue
> describe, lets each finding get reviewed on its own merits — but
> happy to expand if you'd rather land it all together.

## 10. What an agent picking this up should do next

1. Read this entire document. Then run:
   ```
   git log fix/ambient-enabled-multicluster..fix/ambient-enabled-multicluster-wip --stat
   ```
   to see exactly what is in the WIP commit.

2. **Do not push or commit anything without explicit user approval.**
   The user has been firm on this throughout the originating session.

3. Post the open question from §9 on
   [PR #9785](https://github.com/kiali/kiali/pull/9785) only after
   confirming wording with the user. Address the reply to
   `@josunect` and `@jshaughn`.

4. Based on reviewer answer:
   - **Option 1 (likely):** open GitHub issues for findings #3-5
     using §3, §4, §7 as the body. Cherry-pick or rebase commit
     `f2da9d0` (and any test cleanup) onto the PR branch so the
     line-702 + #2b fixes land in PR #9785.
   - **Option 2:** also implement the #3-5 handler fix per §7, add
     handler tests mirroring
     `TestConfigHandlerAmbientEnabledChecksAllClusters` for each
     flag, run `make test`, then rebase the combined work onto the
     PR branch.

5. Before cherry-picking `f2da9d0` onto the PR branch:
   - Tidy the commit message (drop the `WIP:` prefix; describe both
     the line-702 cache fix and the handler-side aggregation +
     dedupe).
   - Decide whether the new
     `hack/istio/multicluster/install-ambient-external-kiali.sh` +
     plan markdown belong in this PR or a separate one. The script
     is genuinely useful for repro but adds review surface; the plan
     markdown was a working note and probably should not land on the
     PR branch.
   - Run `make format lint test` from the repo root and confirm
     green before pushing.

6. Drafted reply for `@jshaughn` on the line-702 thread:
   > Good catch, thanks — fixed in [next-commit-sha]. The defaults
   > fallback now aggregates `IsAmbientEnabled` across all clusters
   > in `c.clients` via the new `IsAmbientEnabledInAnyCluster`
   > helper, mirroring the handler-side fix. Added
   > `TestGatewayAPIClasses/DefaultValuesWithAmbientOnRemoteCluster`
   > covering the standalone-management topology (mgmt cluster has
   > Gateway API CRDs, ambient lives on a remote member) — verifies
   > `istio-waypoint` is now included in the default class list. The
   > handler now also aggregates `GatewayAPIClasses` across all
   > accessible clusters with dedupe, so the standalone-mgmt
   > topology actually reaches the defaults path (the function
   > otherwise short-circuits at the home cluster's
   > `!IsGatewayAPI()` check).

## 11. Useful spelunking commands

```bash
# All callers of IsAmbientEnabled — used to audit the anti-pattern
rg '\.IsAmbientEnabled\(' --type go

# All callers of GatewayAPIClasses
rg '\.GatewayAPIClasses\(' --type go

# Frontend usage of each flag (substitute the JSON field name)
rg 'serverConfig\.(ambientEnabled|gatewayAPIEnabled|istioAPIInstalled|istioGatewayInstalled|gatewayAPIClasses)' frontend/src

# Aggregation pattern across business/
rg 'for cluster.*range.*userClients' --type go

# Run just the affected tests
go test ./cache/... -run 'TestGatewayAPIClasses|TestIsAmbient' -count=1
go test ./handlers/... -run 'TestConfigHandler' -count=1
```
