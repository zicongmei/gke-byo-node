#!/bin/bash

# ==============================================================================
# generate-worker-args.sh
#
# Description: Generates the necessary credentials and a command to bootstrap a
#              new worker node for a non-kubeadm Kubernetes cluster.
#
# Usage: ./generate-worker-args.sh <new-worker-node-name>
#
# Requirements:
#   - kubectl connected to the target cluster.
#   - openssl installed.
#   - Access to the cluster's Certificate Authority (ca.crt).
# ==============================================================================

set -euo pipefail

# --- Sanity Checks ---
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <new-worker-node-name>"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl command not found. Please install it and configure it."
    exit 1
fi

if ! command -v openssl &> /dev/null; then
    echo "Error: openssl command not found. Please install it."
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo "Error: kubectl is not connected to a Kubernetes cluster."
    echo "Please check your kubeconfig."
    exit 1
fi


# --- Configuration ---
readonly NODE_NAME="$1"

echo "--- Preparing arguments for worker node: ${NODE_NAME} ---"

# --- Cluster Information Discovery ---
echo "--> Discovering cluster information..."

# Get Cluster CA certificate from kubectl config
echo "--> Discovering cluster CA certificate from kubectl config..."
readonly CLUSTER_CA_CERT_BASE64=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
if [ -z "${CLUSTER_CA_CERT_BASE64}" ]; then
    echo "Error: Could not determine Cluster CA certificate from kubectl config."
    echo "Ensure your kubeconfig has 'certificate-authority-data' for the current cluster context."
    exit 1
fi
echo "  [✓] Found Cluster CA certificate."


# Get API Server URL
readonly API_SERVER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
if [ -z "${API_SERVER_URL}" ]; then
    echo "Error: Could not determine API Server URL from kubectl config."
    exit 1
fi
echo "  [✓] API Server URL: ${API_SERVER_URL}"

# Get Cluster DNS IP
readonly CLUSTER_DNS_IP=$(kubectl get service kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -z "${CLUSTER_DNS_IP}" ]; then
    echo "Warning: Could not determine kube-dns service IP. Using default 10.96.0.10."
    echo "         You may need to edit /var/lib/kubelet/kubelet-config.yaml on the worker node if this is incorrect."
    readonly CLUSTER_DNS_IP="10.96.0.10"
else
    echo "  [✓] Cluster DNS IP: ${CLUSTER_DNS_IP}"
fi


# --- Credential Generation ---
echo "--> Generating credentials for ${NODE_NAME}..."

# Create a temporary directory for generated files
readonly TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

# Generate a private key for the node
openssl genrsa -out "${TMP_DIR}/${NODE_NAME}.key" 2048 &>/dev/null

# Create an OpenSSL config file for the CSR
cat > "${TMP_DIR}/openssl-${NODE_NAME}.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = system:node:${NODE_NAME}
O = system:nodes
[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
EOF

# Generate the Certificate Signing Request (CSR)
openssl req -new -key "${TMP_DIR}/${NODE_NAME}.key" -out "${TMP_DIR}/${NODE_NAME}.csr" -config "${TMP_DIR}/openssl-${NODE_NAME}.cnf" &>/dev/null

readonly NODE_PRIVATE_KEY_BASE64=$(base64 -w 0 "${TMP_DIR}/${NODE_NAME}.key")
echo "  [✓] Generated private key and CSR."


# --- Final Output ---
echo
echo "------------------------------------------------------------------------"
echo "  [SUCCESS] All arguments generated."
echo "------------------------------------------------------------------------"
echo
echo "1. Copy the 'setup-worker.sh' script to the new worker node."
echo
echo "2. Run the following command on the new worker node to join it to the cluster:"
echo
echo "sudo ./setup-worker.sh --name \"${NODE_NAME}\" --api-url \"${API_SERVER_URL}\" --ca-cert-base64 \"${CLUSTER_CA_CERT_BASE64}\" --node-key-base64 \"${NODE_PRIVATE_KEY_BASE64}\" --cluster-dns-ip \"${CLUSTER_DNS_IP}\""
echo
echo "3. After running the command on the worker, approve its certificate from this machine:"
echo "   kubectl get csr"
echo "   # Find the CSR for ${NODE_NAME} and then run:"
echo "   kubectl certificate approve <csr-name-from-previous-command>"
echo
echo "4. Verify the node has joined:"
echo "   kubectl get nodes"
echo "------------------------------------------------------------------------"