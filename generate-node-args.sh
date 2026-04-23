#!/bin/bash

# ==============================================================================
# generate-node-args.sh
#
# Description: Generates the necessary credentials and a command to bootstrap a
#              new worker node for a non-kubeadm Kubernetes cluster. It now
#              automates the Kubernetes Certificate Signing Request (CSR)
#              creation and approval process, eliminating the need for manual
#              CSR approval on the control plane. This script now also
#              generates and approves certificates for an admin kubeconfig for
#              the node's local kubectl.
#
# Usage: ./generate-node-args.sh --node <new-worker-node-name> --version <kubernetes-version>
#
# Requirements:
#   - kubectl connected to the target cluster with permissions to create and
#     approve CertificateSigningRequests (e.g., cluster-admin).
#   - openssl installed.
#   - Access to the cluster's Certificate Authority (ca.crt).
# ==============================================================================

set -euo pipefail

# --- Sanity Checks ---
# Initialize variables
NODE_NAME=""
K8S_VERSION=""
CONTAINERD_VERSION_ARG="" # New optional argument for containerd version
CNI_PLUGINS_VERSION_ARG="" # New optional argument for CNI plugins version (interpreting "csi" as cni plugins)
PROVIDER="gcp" # Default provider
NODE_LABELS="" # Optional labels

# Parse named arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --node) NODE_NAME="$2"; shift ;;
        --version) K8S_VERSION="$2"; shift ;;
        --containerd-version) CONTAINERD_VERSION_ARG="$2"; shift ;;
        --cni-version) CNI_PLUGINS_VERSION_ARG="$2"; shift ;;
        --provider) PROVIDER="$2"; shift ;;
        --labels) NODE_LABELS="$2"; shift ;;
        --help) echo "Usage: $0 --node <new-worker-node-name> --version <kubernetes-version> [--containerd-version <version>] [--cni-version <version>] [--provider <gcp|aws>] [--labels <labels>]"; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; echo "Usage: $0 --node <new-worker-node-name> --version <kubernetes-version> [--containerd-version <version>] [--cni-version <version>] [--provider <gcp|aws>] [--labels <labels>]"; exit 1 ;;
    esac
    shift
done

if [[ "$PROVIDER" != "gcp" && "$PROVIDER" != "aws" ]]; then
    echo "Error: Invalid provider '$PROVIDER'. Must be 'gcp' or 'aws'."
    exit 1
fi

if [ -z "$NODE_NAME" ] || [ -z "$K8S_VERSION" ]; then
    echo "Usage: $0 --node <new-worker-node-name> --version <kubernetes-version> [--containerd-version <version>] [--cni-version <version>] [--provider <gcp|aws>] [--labels <labels>]"
    echo "Sample: ./generate-node-args.sh --node aws-node-01 --version 1.35.2 --provider aws --labels \"env=prod,team=myteam\""
    exit 1
fi

# Sanitize input versions by removing leading 'v'
K8S_VERSION="${K8S_VERSION#v}"

# Set default versions if not provided
# These defaults correspond to the current versions hardcoded in setup-node.sh
readonly DEFAULT_CONTAINERD_VERSION="1.7.22"
readonly DEFAULT_CNI_PLUGINS_VERSION="1.5.1" # The version part, without 'v'

# Assign final versions for output and sanitize them
CONTAINERD_VERSION=${CONTAINERD_VERSION_ARG:-${DEFAULT_CONTAINERD_VERSION}}
CONTAINERD_VERSION="${CONTAINERD_VERSION#v}" # Sanitize default or provided containerd version

CNI_PLUGINS_VERSION=${CNI_PLUGINS_VERSION_ARG:-${DEFAULT_CNI_PLUGINS_VERSION}}
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION#v}" # Sanitize default or provided cni version

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
# Arguments are already assigned to NODE_NAME and K8S_VERSION from parsing loop

echo "--- Preparing arguments for worker node: ${NODE_NAME} (Provider: ${PROVIDER}, K8s Version: ${K8S_VERSION}, Containerd: ${CONTAINERD_VERSION}, CNI: ${CNI_PLUGINS_VERSION}) ---"

# --- Cluster Information Discovery ---
echo "--> Discovering cluster information..."

# Get Cluster CA certificate from kubectl config
echo "--> Discovering cluster CA certificate from kubectl config..."

# Get the current context and cluster name
readonly CURRENT_CONTEXT=$(kubectl config current-context)
readonly CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${CURRENT_CONTEXT}')].context.cluster}")

if [ -z "${CLUSTER_NAME}" ]; then
    echo "Error: Could not determine cluster name from current context: ${CURRENT_CONTEXT}."
    echo "Please ensure your kubeconfig is correctly set up."
    exit 1
fi

# Try to get certificate-authority-data first
CLUSTER_CA_CERT_BASE64=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${CLUSTER_NAME}')].cluster.certificate-authority-data}")

if [ -z "${CLUSTER_CA_CERT_BASE64}" ]; then
    # If certificate-authority-data is empty, try to get certificate-authority file path
    CA_FILE_PATH=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${CLUSTER_NAME}')].cluster.certificate-authority}")
    if [ -n "${CA_FILE_PATH}" ]; then
        if [ -f "${CA_FILE_PATH}" ]; then
            echo "  [i] Found certificate-authority file path: ${CA_FILE_PATH} for cluster '${CLUSTER_NAME}'. Reading content..."
            CLUSTER_CA_CERT_BASE64=$(base64 -w 0 "${CA_FILE_PATH}")
        else
            echo "Error: Certificate authority file path '${CA_FILE_PATH}' for cluster '${CLUSTER_NAME}' does not exist or is not a file."
            echo "Please check your kubeconfig."
            exit 1
        fi
    fi
fi

if [ -z "${CLUSTER_CA_CERT_BASE64}" ]; then
    echo "Error: Could not determine Cluster CA certificate for cluster '${CLUSTER_NAME}' from kubectl config."
    echo "Ensure your kubeconfig has 'certificate-authority-data' or 'certificate-authority' (file path) for the current cluster context."
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


# --- Credential Generation and Approval ---
echo "--> Generating credentials for ${NODE_NAME}..."

# Create a temporary directory for generated files
readonly TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

# --- Generate kubelet private key and CSR ---
echo "  --> Generating kubelet private key and CSR..."
openssl genrsa -out "${TMP_DIR}/${NODE_NAME}.key" 2048 &>/dev/null

# Create an OpenSSL config file for the kubelet CSR
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

# Generate the Certificate Signing Request (CSR) for kubelet
openssl req -new -key "${TMP_DIR}/${NODE_NAME}.key" -out "${TMP_DIR}/${NODE_NAME}.csr" -config "${TMP_DIR}/openssl-${NODE_NAME}.cnf" &>/dev/null

readonly NODE_PRIVATE_KEY_BASE64=$(base64 -w 0 "${TMP_DIR}/${NODE_NAME}.key")
readonly NODE_CSR_BASE64=$(base64 -w 0 "${TMP_DIR}/${NODE_NAME}.csr")
echo "  [✓] Generated kubelet private key and CSR."

# --- Kubernetes CSR creation and approval for kubelet ---
echo "--> Creating and approving CSR for kubelet ${NODE_NAME} in Kubernetes..."

# Clean up any existing CSR for this node name to avoid conflicts on re-run
kubectl delete csr "${NODE_NAME}" --ignore-not-found &>/dev/null

# Create CSR object in Kubernetes
CSR_YAML=$(cat <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${NODE_NAME}
spec:
  groups:
  - system:nodes
  request: ${NODE_CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client-kubelet
  usages:
  - client auth
EOF
)

echo "${CSR_YAML}" | kubectl apply -f - >/dev/null

# Approve the CSR
kubectl certificate approve "${NODE_NAME}" >/dev/null
echo "  [✓] Kubelet CSR created and approved in Kubernetes."

# Wait for certificate to be signed and fetch it
echo "  --> Waiting for signed kubelet client certificate (up to 10 seconds)..."
NODE_CLIENT_CERT_BASE64=""
for i in $(seq 1 10); do
    NODE_CLIENT_CERT_BASE64=$(kubectl get csr "${NODE_NAME}" -o jsonpath='{.status.certificate}' 2>/dev/null)
    if [ -n "${NODE_CLIENT_CERT_BASE64}" ]; then
        echo "  [✓] Signed kubelet client certificate fetched."
        break
    fi
    sleep 1
done

if [ -z "${NODE_CLIENT_CERT_BASE64}" ]; then
    echo "Error: Failed to fetch signed kubelet client certificate for ${NODE_NAME} after multiple attempts."
    echo "Please check 'kubectl get csr ${NODE_NAME}' and 'kubectl describe csr ${NODE_NAME}' on the control plane."
    exit 1
fi

# --- Generate kubernetes-local-edit private key and CSR ---
echo "  --> Generating kubernetes-local-edit private key and CSR..."
openssl genrsa -out "${TMP_DIR}/kubernetes-local-edit.key" 2048 &>/dev/null

# Create an OpenSSL config file for the kubernetes-local-edit CSR
cat > "${TMP_DIR}/openssl-kubernetes-local-edit.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
# CN = kubernetes-local-edit
# O = kubernetes:edit-users
CN = cluster-admin
O = cluster-admin
[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = clientAuth
EOF

# Generate the Certificate Signing Request (CSR) for kubernetes-local-edit
openssl req -new -key "${TMP_DIR}/kubernetes-local-edit.key" -out "${TMP_DIR}/kubernetes-local-edit.csr" -config "${TMP_DIR}/openssl-kubernetes-local-edit.cnf" &>/dev/null

readonly LOCAL_EDIT_PRIVATE_KEY_BASE64=$(base64 -w 0 "${TMP_DIR}/kubernetes-local-edit.key")
readonly LOCAL_EDIT_CSR_BASE64=$(base64 -w 0 "${TMP_DIR}/kubernetes-local-edit.csr")
echo "  [✓] Generated kubernetes-local-edit private key and CSR."

# --- Kubernetes CSR creation and approval for kubernetes-local-edit ---
echo "--> Creating and approving CSR for kubernetes-local-edit-${NODE_NAME} in Kubernetes..."

# Clean up any existing CSR for this user name to avoid conflicts on re-run
kubectl delete csr "kubernetes-local-edit-${NODE_NAME}" --ignore-not-found &>/dev/null

# Create CSR object in Kubernetes for kubernetes-local-edit
LOCAL_EDIT_CSR_YAML=$(cat <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: kubernetes-local-edit-${NODE_NAME}
spec:
  groups:
  - kubernetes:edit-users
  - system:authenticated
  request: ${LOCAL_EDIT_CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  usages:
  - client auth
EOF
)

echo "${LOCAL_EDIT_CSR_YAML}" | kubectl apply -f - >/dev/null

# Approve the kubernetes-local-edit CSR
kubectl certificate approve "kubernetes-local-edit-${NODE_NAME}" >/dev/null
echo "  [✓] Kubernetes-local-edit CSR created and approved in Kubernetes."

# Wait for certificate to be signed and fetch it
echo "  --> Waiting for signed kubernetes-local-edit client certificate (up to 10 seconds)..."
LOCAL_EDIT_CLIENT_CERT_BASE64=""
for i in $(seq 1 10); do
    LOCAL_EDIT_CLIENT_CERT_BASE64=$(kubectl get csr "kubernetes-local-edit-${NODE_NAME}" -o jsonpath='{.status.certificate}' 2>/dev/null)
    if [ -n "${LOCAL_EDIT_CLIENT_CERT_BASE64}" ]; then
        echo "  [✓] Signed kubernetes-local-edit client certificate fetched."
        break
    fi
    sleep 1
done

if [ -z "${LOCAL_EDIT_CLIENT_CERT_BASE64}" ]; then
    echo "Error: Failed to fetch signed kubernetes-local-edit client certificate for kubernetes-local-edit-${NODE_NAME} after multiple attempts."
    echo "Please check 'kubectl get csr kubernetes-local-edit-${NODE_NAME}' and 'kubectl describe csr kubernetes-local-edit-${NODE_NAME}' on the control plane."
    exit 1
fi

# --- Final Output ---
echo
echo "------------------------------------------------------------------------"
echo "  [SUCCESS] All arguments generated and client certificates approved."
echo "------------------------------------------------------------------------"
echo
echo "1. Copy the 'setup-node.sh' script to the new ${PROVIDER} worker node."
echo
echo "2. Run the following command on the new ${PROVIDER} worker node to join it to the cluster:"
echo

SETUP_COMMAND="sudo ./setup-node.sh --name \"${NODE_NAME}\" --api-url \"${API_SERVER_URL}\" --ca-cert-base64 \"${CLUSTER_CA_CERT_BASE64}\" --node-private-key-base64 \"${NODE_PRIVATE_KEY_BASE64}\" --node-client-cert-base64 \"${NODE_CLIENT_CERT_BASE64}\" --local-edit-private-key-base64 \"${LOCAL_EDIT_PRIVATE_KEY_BASE64}\" --local-edit-client-cert-base64 \"${LOCAL_EDIT_CLIENT_CERT_BASE64}\" --cluster-dns-ip \"${CLUSTER_DNS_IP}\" --version \"${K8S_VERSION}\" --containerd-version \"${CONTAINERD_VERSION}\" --cni-version \"${CNI_PLUGINS_VERSION}\" --provider \"${PROVIDER}\""

if [ -n "$NODE_LABELS" ]; then
    SETUP_COMMAND="${SETUP_COMMAND} --labels \"${NODE_LABELS}\""
fi

echo "${SETUP_COMMAND}"
echo
echo "3. Verify the node has joined:"
echo "   kubectl get nodes"
echo "4. On the node, to use kubectl with edit permissions, you can run:"
echo "   export KUBECONFIG=/etc/kubernetes/local-edit.conf"
echo "   kubectl get nodes"
echo "5. To grant 'edit' ClusterRole permissions to this user, run the following on your control plane:"
echo "   kubectl create clusterrolebinding kubernetes-local-edit-binding --clusterrole=edit --group=kubernetes:edit-users"
echo
echo "------------------------------------------------------------------------"