#!/bin/bash
# shellcheck disable=SC2155

##############################################################################
# install-ambient-external-kiali.sh
#
# Installs two kind clusters:
#   cluster-1 ("mgmt"): Only Kiali, no Istio. ignore_home_cluster=true.
#   cluster-2 ("mesh"): Istio ambient profile with bookinfo and waypoints.
#
# This reproduces the management cluster pattern where Kiali runs on a
# separate cluster that has no mesh components. Useful for testing
# ambient-specific config handler fixes (e.g., ambientEnabled,
# GatewayAPIClasses with istio-waypoint).
#
# Usage:
#   hack/istio/multicluster/install-ambient-external-kiali.sh --manage-kind true
#
# See --help (inherited from env.sh) for more options.
#
##############################################################################

infomsg() {
  echo "[INFO] ${1}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source ${SCRIPT_DIR}/env.sh "$@"

# The names of each cluster
if [ "${CLUSTER1_NAME}" == "east" ]; then
  CLUSTER1_NAME="mgmt"
fi
if [ "${CLUSTER2_NAME}" == "west" ]; then
  CLUSTER2_NAME="mesh"
fi

if [ "${MANAGE_KIND}" == "true" ]; then
  CLUSTER1_CONTEXT="kind-${CLUSTER1_NAME}"
  CLUSTER2_CONTEXT="kind-${CLUSTER2_NAME}"
else
  CLUSTER1_CONTEXT="${CLUSTER1_NAME}"
  CLUSTER2_CONTEXT="${CLUSTER2_NAME}"
fi

# Only install Kiali on cluster-1
# shellcheck disable=SC2034
IGNORE_HOME_CLUSTER="true"

create_remote_secret() {
  local clustername="${1}"
  local secretcount="$(${CLIENT_EXE} get sa -n ${ISTIO_NAMESPACE} istio-reader-service-account --no-headers 2>/dev/null | tr -s ' ' | cut -d ' ' -f 2)"
  local secretname=""
  if [ -n "${secretcount}" ] && [ "${secretcount}" -gt 1 ] 2>/dev/null; then
    secretname="--secret-name $(${CLIENT_EXE} get sa -n ${ISTIO_NAMESPACE} istio-reader-service-account -o jsonpath='{.secrets[0].name}')"
    if ! echo ${secretname} | grep -q "token"; then
      secretname="--secret-name $(${CLIENT_EXE} get sa -n ${ISTIO_NAMESPACE} istio-reader-service-account -o jsonpath='{.secrets[1].name}')"
      if ! echo ${secretname} | grep -q "token"; then
        echo "Failed to find the sa token secret"
        exit 1
      fi
    fi
    echo "Choosing to use: [${secretname}]"
  fi
  REMOTE_SECRET="$("${ISTIOCTL}" create-remote-secret --name "${clustername}" ${secretname})"
  if [ "$?" != "0" ]; then
    echo "Failed to generate remote secret for cluster [${clustername}]"
    exit 1
  fi

  # if kind, then we have to make sure the remote secret has the external IP to the API server
  if [ "${MANAGE_KIND}" == "true" ]; then
    local kind_ip=$(${DORP} inspect ${clustername}-control-plane --format "{{ .NetworkSettings.Networks.kind.IPAddress }}")
    REMOTE_SECRET="$(printf '%s' "${REMOTE_SECRET}" | sed -E 's!server:.*!server: https://'"${kind_ip}"':6443!')"
    echo "Updating remote secret for kind cluster [${clustername}] to use API IP [${kind_ip}]"
  fi
}

# Istio mesh configuration for the mesh cluster
MC_MESH_YAML=$(mktemp)
cat <<EOF > "$MC_MESH_YAML"
spec:
  values:
    global:
      meshID: ${MESH_ID}
      multiCluster:
        clusterName: ${CLUSTER2_NAME}
      network: ${NETWORK2_ID}
EOF

# Start up two kind instances if requested
if [ "${MANAGE_KIND}" == "true" ]; then
  echo "Starting kind instances"

  echo "==== START KIND FOR CLUSTER #1 [${CLUSTER1_NAME}] - ${CLUSTER1_CONTEXT}"
  "${SCRIPT_DIR}"/../../start-kind.sh \
    --name "${CLUSTER1_NAME}" \
    --load-balancer-range "255.70-255.84" \
    --image "${KIND_NODE_IMAGE}"

  echo "==== START KIND FOR CLUSTER #2 [${CLUSTER2_NAME}] - ${CLUSTER2_CONTEXT}"
  "${SCRIPT_DIR}"/../../start-kind.sh \
    --name "${CLUSTER2_NAME}" \
    --load-balancer-range "255.85-255.98" \
    --image "${KIND_NODE_IMAGE}"
fi

# Setup the certificates
source ${SCRIPT_DIR}/setup-ca.sh

# Install Istio with ambient profile on mesh cluster only
echo "==== INSTALL ISTIO AMBIENT ON CLUSTER #2 [${CLUSTER2_NAME}] - ${CLUSTER2_CONTEXT}"
switch_cluster "${CLUSTER2_CONTEXT}" "${CLUSTER2_USER}" "${CLUSTER2_PASS}"
install_istio --config-profile ambient --patch-file "${MC_MESH_YAML}" -a "prometheus"

# Ensure Gateway API CRDs are installed on the mesh cluster
echo "==== ENSURE GATEWAY API CRDS ON CLUSTER #2 [${CLUSTER2_NAME}]"
source ${SCRIPT_DIR}/../functions.sh
ensure_gateway_api_crds

# Create istio-system namespace on mgmt cluster (needed for remote secrets and Kiali)
echo "==== CREATE ISTIO-SYSTEM NAMESPACE ON CLUSTER #1 [${CLUSTER1_NAME}] - ${CLUSTER1_CONTEXT}"
${CLIENT_EXE} --context="${CLUSTER1_CONTEXT}" create namespace ${ISTIO_NAMESPACE} 2>/dev/null || true

# Create remote secret from mesh cluster and apply on mgmt cluster
echo "==== CREATE REMOTE SECRET FROM CLUSTER #2 [${CLUSTER2_NAME}]"
switch_cluster "${CLUSTER2_CONTEXT}" "${CLUSTER2_USER}" "${CLUSTER2_PASS}"
create_remote_secret "${CLUSTER2_NAME}"
echo "Applying remote secret on mgmt cluster [${CLUSTER1_CONTEXT}]"
printf '%s' "${REMOTE_SECRET}" | ${CLIENT_EXE} apply --context="${CLUSTER1_CONTEXT}" -n ${ISTIO_NAMESPACE} -f -

# Install Prometheus on mgmt cluster with federation from mesh cluster
echo "==== INSTALL PROMETHEUS ON CLUSTER #1 [${CLUSTER1_NAME}] - ${CLUSTER1_CONTEXT}"
ADDONS="prometheus"
for addon in ${ADDONS}; do
  while ! (cat ${ISTIO_DIR}/samples/addons/${addon}.yaml | ${CLIENT_EXE} apply --context="${CLUSTER1_CONTEXT}" -n ${ISTIO_NAMESPACE} -f -)
  do
    echo "Failed to install addon [${addon}] - will retry in 10 seconds..."
    sleep 10
  done
done

# Configure Prometheus federation
echo "==== CONFIGURE PROMETHEUS FEDERATION"
${CLIENT_EXE} patch svc prometheus -n ${ISTIO_NAMESPACE} --context ${CLUSTER2_CONTEXT} -p "{\"spec\": {\"type\": \"LoadBalancer\"}}"

# Wait for load balancer IP
echo "Waiting for prometheus load balancer IP on mesh cluster..."
for i in $(seq 1 30); do
  MESH_PROMETHEUS_ADDRESS=$(${CLIENT_EXE} --context=${CLUSTER2_CONTEXT} -n ${ISTIO_NAMESPACE} get svc prometheus -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [ -n "${MESH_PROMETHEUS_ADDRESS}" ]; then
    break
  fi
  sleep 2
done

if [ -z "${MESH_PROMETHEUS_ADDRESS}" ]; then
  echo "WARNING! Prometheus not updated - cannot determine the mesh prometheus load balancer ingress IP"
else
  echo "Mesh Prometheus address: ${MESH_PROMETHEUS_ADDRESS}"
  cat ${SCRIPT_DIR}/prometheus.yaml | \
    sed -e "s/WEST_PROMETHEUS_ADDRESS/${MESH_PROMETHEUS_ADDRESS}/g" \
        -e "s/CLUSTER_NAME/${CLUSTER2_NAME}/g" | \
    ${CLIENT_EXE} apply -n ${ISTIO_NAMESPACE} --context ${CLUSTER1_CONTEXT} -f -
fi

# Deploy bookinfo on mesh cluster with ambient mode
if [ "${BOOKINFO_ENABLED}" == "true" ]; then
  echo "==== DEPLOY BOOKINFO ON CLUSTER #2 [${CLUSTER2_NAME}] - ${CLUSTER2_CONTEXT}"
  switch_cluster "${CLUSTER2_CONTEXT}" "${CLUSTER2_USER}" "${CLUSTER2_PASS}"

  # Label bookinfo namespace for ambient
  ${CLIENT_EXE} --context="${CLUSTER2_CONTEXT}" create namespace ${BOOKINFO_NAMESPACE} 2>/dev/null || true
  ${CLIENT_EXE} --context="${CLUSTER2_CONTEXT}" label namespace ${BOOKINFO_NAMESPACE} istio.io/dataplane-mode=ambient --overwrite

  # Install bookinfo (without sidecar injection flags)
  source ${SCRIPT_DIR}/../install-bookinfo-demo.sh \
    --client-exe "${CLIENT_EXE}" \
    --istio-dir "${ISTIO_DIR}" \
    --istio-namespace "${ISTIO_NAMESPACE}" \
    --namespace "${BOOKINFO_NAMESPACE}" \
    --kube-context "${CLUSTER2_CONTEXT}" \
    -tg

  # Deploy a waypoint proxy in the bookinfo namespace
  echo "==== DEPLOY WAYPOINT PROXY IN [${BOOKINFO_NAMESPACE}]"
  ${ISTIOCTL} --context="${CLUSTER2_CONTEXT}" waypoint apply -n ${BOOKINFO_NAMESPACE} --enroll-namespace
  echo "Waiting for waypoint to be ready..."
  ${CLIENT_EXE} --context="${CLUSTER2_CONTEXT}" wait --for=condition=Programmed \
    gateway/waypoint -n ${BOOKINFO_NAMESPACE} --timeout=120s 2>/dev/null || true
fi

# Install Kiali on mgmt cluster
if [ "${KIALI_ENABLED}" == "true" ]; then
  echo "==== INSTALL KIALI ON CLUSTER #1 [${CLUSTER1_NAME}] - ${CLUSTER1_CONTEXT}"
  switch_cluster "${CLUSTER1_CONTEXT}" "${CLUSTER1_USER}" "${CLUSTER1_PASS}"
  source ${SCRIPT_DIR}/deploy-kiali.sh
fi

# Print verification commands
cat <<VERIFY

==============================================================================
  AMBIENT EXTERNAL KIALI SETUP COMPLETE
==============================================================================

Clusters:
  mgmt (${CLUSTER1_CONTEXT}): Kiali only, ignore_home_cluster=true
  mesh (${CLUSTER2_CONTEXT}): Istio ambient + bookinfo + waypoint

Verification:

  # 1. Port-forward Kiali
  kubectl --context ${CLUSTER1_CONTEXT} port-forward svc/kiali -n ${ISTIO_NAMESPACE} 20001:80 &

  # 2. Check config endpoint
  curl -s http://localhost:20001/kiali/api/config | jq '{
    ambientEnabled,
    gatewayAPIEnabled,
    istioAPIInstalled,
    istioGatewayInstalled,
    gatewayAPIClasses
  }'

  # Expected (with fix):
  #   ambientEnabled: true
  #   gatewayAPIClasses: [..., {name: "istio-waypoint", className: "istio-waypoint"}]

  # Expected (without fix):
  #   ambientEnabled: false
  #   gatewayAPIClasses: [...] (no istio-waypoint)

  # 3. Check graph (with fix applied)
  curl -s 'http://localhost:20001/kiali/api/namespaces/graph?namespaces=${BOOKINFO_NAMESPACE}&graphType=workload&ambientTraffic=total' | jq '.elements.edges | length'

  # 4. Open Kiali UI
  open http://localhost:20001/kiali/console/overview

Cleanup:
  kind delete cluster --name ${CLUSTER1_NAME}
  kind delete cluster --name ${CLUSTER2_NAME}
==============================================================================
VERIFY
