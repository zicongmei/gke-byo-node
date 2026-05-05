# gke-byo-node

This code provision a Linux machine into kubernetes worker node.

## 1. Quick Start

Follow these steps to quickly add a new custom worker node to your Kubernetes cluster:

### Prerequisites:

*   **Workstation/Control Plane**:
    *   `kubectl` installed and configured to connect to your GKE cluster.
    *   `openssl` installed.
*   **New Worker Node (Target)**:
    *   An Linux Linux machine (e.g., Ubuntu, Debian, Centos) with `sudo` access.
        - The `terraform` directory contains the script to create such instances.
    *   `curl` installed (usually pre-installed).
    *   Network connectivity to your Kubernetes API server.

### Steps:

1.  **Configure `kubectl` on your workstation**:
    Ensure your `kubectl` context is set to the target Kubernetes cluster where you want to add the node. You can verify this with `kubectl config current-context`.

2.  **Generate Worker Node Arguments on your workstation**:
    Navigate to the directory containing `generate_node_args.py` and execute it. Provide a unique name for your new worker node and the *exact Kubernetes version* you intend to use. You can also specify optional versions for Containerd and CNI plugins.
    ```bash
    python3 generate_node_args.py --node <your-new-node-name> --version <kubernetes-version> [--containerd-version <version>] [--cni-version <version>] [--provider <provider>] [--labels <labels>] [--provider-id <id>]
    ```
    **Example**:
    ```bash
    python3 generate_node_args.py --node ubuntu-worker-01 --version 1.32.0 --containerd-version 1.7.22 --cni-version 1.5.1
    # For AWS VM (user provisions VM first):
    python3 generate_node_args.py --node aws-worker-01 --version 1.32.0 --provider aws --labels "env=prod,team=infra" --provider-id "aws:///us-west-2a/i-1234567890abcdef0"
    # For Azure VM (user provisions VM first):
    python3 generate_node_args.py --node azure-worker-01 --version 1.32.0 --provider azure
    # Or, defaulting to gcp:
    python3 generate_node_args.py --node ubuntu-worker-01 --version 1.32.0
    ```
    This script will:
    *   Discover cluster details.
    *   Generate a private key and CSR for your node.
    *   **Automatically approve** the CSR in your Kubernetes cluster.
    *   Output a `sudo python3 setup_node.py ...` command. **Copy this entire command.**

3.  **Execute `setup_node.py` on the new worker node**:
    SSH into your new worker node. 
    
    Download the setup_node.py.
    ```
    curl https://raw.githubusercontent.com/zicongmei/gke-byo-node/refs/heads/main/setup_node.py -o setup_node.py
    ```
    Then, paste and execute the full command that was output by `generate_node_args.py` in Step 2. Remember to run it with `sudo`.
    ```bash
    sudo python3 setup_node.py --name "ubuntu-worker-01" --api-url "https://34.123.45.67" --ca-cert-base64 "..." --node-private-key-base64 "..." --node-client-cert-base64 "..." --cluster-dns-ip "10.96.0.10" --version "1.32.0" --containerd-version "1.7.22" --cni-version "1.5.1"
    ```
    This script will install all necessary components, configure them, and start the `kubelet` service. It will automatically remove any existing `kubelet` and `kubectl` binaries if found.

4.  **Verify Node Registration**:
    On your workstation (where `kubectl` is configured), run the following command to check if your new node has successfully joined the cluster:
    ```bash
    kubectl get nodes
    ```
    You should see your new node (`<your-new-node-name>`) listed with a `Ready` status.

## 2. What the Code Does

This repository provides a pair of shell scripts designed to simplify the process of adding custom, "Bring Your Own" (BYO) worker nodes to a Kubernetes cluster that doesn't rely on `kubeadm` for node bootstrapping, such as Google Kubernetes Engine (GKE) clusters configured for custom node pools.

The core problem these scripts solve is the manual complexity of setting up a new Kubernetes worker node, which involves:
*   Generating TLS certificates for the kubelet to authenticate with the Kubernetes API server.
*   Getting these certificates signed by the cluster's Certificate Authority (CA).
*   Installing and configuring the container runtime (e.g., containerd).
*   Installing and configuring CNI plugins.
*   Installing and configuring the `kubelet` and `kubectl` binaries.
*   Setting up the necessary kubeconfig files.

This automation is particularly useful for scenarios where you need to integrate custom virtual machines or bare-metal servers into an existing GKE cluster as worker nodes, providing flexibility beyond standard GKE node pools.

### `generate_node_args.py` (Run on your workstation/control plane)

This script is executed on a machine with `kubectl` configured to access your target Kubernetes cluster. Its primary functions are:
*   **Cluster Information Discovery**: Automatically fetches the Kubernetes API server URL, cluster CA certificate, and (optionally) the cluster DNS IP from your current `kubectl` context.
*   **Credential Generation**: Generates a unique private key and a Certificate Signing Request (CSR) for the new worker node.
*   **Version Parameterization**: Allows specifying optional versions for `containerd` and CNI plugins, defaulting to commonly used "current" versions if not provided.
*   **Provider Selection**: Supports `--provider` flag (default `gcp`). Specify `aws` if targeting an AWS VM. This updates output messages to be provider-aware.
*   **Output Generation**: Prints a `setup_node.py` command complete with all necessary arguments (base64 encoded certificates, keys, API URL, etc.) that can be directly copied and executed on the new worker node.

**Prerequisites**: `kubectl` (configured with cluster-admin like permissions to approve CSRs), `openssl`, and `python3`.

### `setup_node.py` (Run on the new worker node)

This script is executed on the target Ubuntu worker node, using the pre-generated arguments provided by `generate_node_args.py`. It performs the following setup steps:
*   **System Preparation**: Updates package lists, installs essential utilities (curl, gpg, apt-transport-https, dialog), and disables swap (a Kubernetes requirement).
*   **CNI Plugin Installation**: Downloads and installs a standard version of CNI plugins (Container Network Interface) to `/opt/cni/bin`, using the specified or default version.
*   **Containerd Runtime Installation**: Downloads and installs a specific version of `containerd` from its GitHub releases, configures it to use the `systemd` cgroup driver, and enables/starts its service, using the specified or default version.
*   **Kubernetes Component Installation**: Downloads and installs specific versions of `kubelet` and `kubectl` binaries from official Kubernetes releases (`dl.k8s.io`) to `/usr/bin`. It also cleans up any pre-existing binaries to ensure a clean installation.
*   **Credential Placement**: Decodes and places the cluster CA certificate, the node's private key, and its pre-signed client certificate into their respective paths (`/etc/kubernetes/pki/ca.crt`, `/var/lib/kubelet/<node-name>.key`, `/var/lib/kubelet/<node-name>.crt`).
*   **Kubeconfig Generation**: Creates `kubeconfig` files for `kubelet` and `kube-proxy` in `/var/lib/kubelet/kubeconfig` and `/var/lib/kube-proxy/kubeconfig`, embedding the signed certificates and cluster information.
*   **Kubelet Configuration**: Creates the `kubelet` configuration file (`/var/lib/kubelet/config.yaml`) and its systemd service unit file (`/etc/systemd/system/kubelet.service`), ensuring it starts with the correct arguments and points to the right configuration and kubeconfig.
*   **Service Startup**: Reloads systemd daemon and starts the `kubelet` service, registering the node with the Kubernetes cluster.

**Prerequisites**: Linux (tested on Ubuntu, Debian, Centos), `sudo` privileges, `curl`.