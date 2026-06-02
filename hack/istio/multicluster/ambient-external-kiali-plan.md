# Script: install-ambient-external-kiali.sh

## Context

PR #9785 fixes config handler bugs when Kiali runs on a standalone management cluster with `ignore_home_cluster=true` and ambient mesh lives on remote clusters. There is no existing test script that combines the ambient profile with the external-kiali (management cluster) pattern. We need one to verify the fix end-to-end on kind clusters.

## Approach

Create `hack/istio/multicluster/install-ambient-external-kiali.sh` modeled on `install-external-kiali.sh` but using ambient instead of sidecar Istio. Reuse existing infrastructure:

- `env.sh` for cluster configuration, `switch_cluster`, env vars
- `start-kind.sh` for kind cluster creation
- `setup-ca.sh` for shared CA
- `install-istio-via-istioctl.sh` with `--config-profile ambient` for Istio installation
- `deploy-kiali.sh` with `IGNORE_HOME_CLUSTER=true` for Kiali deployment
- `install-bookinfo-demo.sh` for workload deployment

### Script flow

1. Source `env.sh`, rename clusters to `mgmt` / `mesh`
2. Set `IGNORE_HOME_CLUSTER="true"`
3. Start two kind clusters (reuse `start-kind.sh`)
4. Setup shared CA (reuse `setup-ca.sh`)
5. Install Istio **ambient profile** on `mesh` cluster only (via `install-istio-via-istioctl.sh --config-profile ambient`)
6. Create `istio-system` namespace on `mgmt` (needed for Kiali + remote secrets)
7. Create remote secret from `mesh`, apply on `mgmt`
8. Install Prometheus on `mgmt` with federation from `mesh` (reuse existing prometheus.yaml pattern)
9. Label bookinfo namespace with `istio.io/dataplane-mode=ambient` on `mesh`
10. Deploy bookinfo on `mesh` (reuse `install-bookinfo-demo.sh`)
11. Deploy a waypoint in bookinfo namespace on `mesh` (`istioctl waypoint apply`)
12. Deploy Kiali on `mgmt` (reuse `deploy-kiali.sh`)
13. Print verification commands

### Verification commands printed at end

```bash
# Check config endpoint
kubectl --context kind-mgmt port-forward svc/kiali -n istio-system 20001:80 &
curl -s http://localhost:20001/kiali/api/config | jq '{ambientEnabled, gatewayAPIEnabled, gatewayAPIClasses}'

# Expected: ambientEnabled=true, istio-waypoint in gatewayAPIClasses
```

## File

`hack/istio/multicluster/install-ambient-external-kiali.sh` (new file, executable)

## Verification

```bash
# Run the script
hack/istio/multicluster/install-ambient-external-kiali.sh --manage-kind true

# Then run the printed verification commands
```
