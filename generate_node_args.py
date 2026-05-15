#!/usr/bin/env python3

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time

def run_command(command, shell=False, check=True, text=True, capture_output=True):
    try:
        result = subprocess.run(
            command, shell=shell, check=check, text=text,
            capture_output=capture_output
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"Error executing command: {command}")
        print(f"Stdout: {e.stdout}")
        print(f"Stderr: {e.stderr}")
        if check:
            sys.exit(1)
        return None

def get_kubectl_config(jsonpath):
    return run_command(["kubectl", "config", "view", "--minify", "-o", f"jsonpath={jsonpath}"])

def main():
    parser = argparse.ArgumentParser(
        description="Generate worker node setup arguments.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic usage for GCP:
  python3 generate_node_args.py --node ubuntu-worker-01 --version 1.35.2 --labels 'components.gke.io/gke-unmanaged-node=true,team=myteam' --containerd-version 1.7.22 --cni-version 1.5.1

  # For AWS node with provider-id and custom labels:
  python3 generate_node_args.py --node aws-node-01 --version 1.35.2 --provider aws --labels 'components.gke.io/gke-unmanaged-node=true,team=myteam' --provider-id='aws:///us-west-2a/aws-node-01'

  # For Azure node:
  python3 generate_node_args.py --node azure-worker-01 --version 1.35.2 --provider azure --labels 'components.gke.io/gke-unmanaged-node=true,team=myteam'

  # For NixOS node:
  python3 generate_node_args.py --node nix-worker-01 --version 1.35.2 --os nixos --labels 'components.gke.io/gke-unmanaged-node=true'

"""
    )
    parser.add_argument("--node", required=True, help="Worker node name")
    parser.add_argument("--version", required=True, help="Kubernetes version")
    parser.add_argument("--containerd-version", default="1.7.22", help="Containerd version")
    parser.add_argument("--cni-version", default="1.5.1", help="CNI plugins version")
    parser.add_argument("--provider", choices=["gcp", "aws", "azure"], default="gcp", help="Cloud provider")
    parser.add_argument("--labels", help="Optional node labels")
    parser.add_argument("--provider-id", help="Optional provider ID")
    parser.add_argument("--os", choices=["linux", "nixos"], default="linux", help="Target operating system")

    args = parser.parse_args()

    node_name = args.node
    k8s_version = args.version.lstrip('v')
    containerd_version = args.containerd_version.lstrip('v')
    cni_version = args.cni_version.lstrip('v')
    provider = args.provider
    target_os = args.os

    print(f"--- Preparing arguments for worker node: {node_name} (Provider: {provider}, K8s Version: {k8s_version}, Containerd: {containerd_version}, CNI: {cni_version}) ---")

    # Discover Cluster Info
    print("--> Discovering cluster information...")
    current_context = run_command(["kubectl", "config", "current-context"])
    cluster_name = get_kubectl_config(f"{{.contexts[?(@.name=='{current_context}')].context.cluster}}")

    if not cluster_name:
        print(f"Error: Could not determine cluster name from context {current_context}")
        sys.exit(1)

    ca_data = run_command(["kubectl", "config", "view", "--raw", "-o", f"jsonpath={{.clusters[?(@.name=='{cluster_name}')].cluster.certificate-authority-data}}"])
    
    if not ca_data:
        ca_path = run_command(["kubectl", "config", "view", "--raw", "-o", f"jsonpath={{.clusters[?(@.name=='{cluster_name}')].cluster.certificate-authority}}"])
        if ca_path and os.path.exists(ca_path):
            with open(ca_path, "rb") as f:
                ca_data = base64.b64encode(f.read()).decode('utf-8')
        else:
            print(f"Error: Could not determine Cluster CA for {cluster_name}")
            sys.exit(1)
    
    print("  [✓] Found Cluster CA certificate.")

    api_server_url = get_kubectl_config("{.clusters[0].cluster.server}")
    print(f"  [✓] API Server URL: {api_server_url}")

    cluster_dns_ip = run_command(["kubectl", "get", "service", "kube-dns", "-n", "kube-system", "-o", "jsonpath={.spec.clusterIP}"], check=False)
    if not cluster_dns_ip:
        print("Error: Could not determine kube-dns service IP. This cluster might use a different DNS service name or it is not available.")
        sys.exit(1)
    else:
        print(f"  [✓] Cluster DNS IP: {cluster_dns_ip}")

    # Discover PodCIDR for all providers
    pod_cidr = ""
    print(f"--> Discovering available PodCIDR for {provider} via kubectl...")
    nodes_output = run_command(["kubectl", "get", "nodes", "-o", "json"], check=False)
    if nodes_output:
        try:
            nodes_data = json.loads(nodes_output)
            items = nodes_data.get("items", [])
            existing_cidrs = [n.get("spec", {}).get("podCIDR") for n in items if n.get("spec", {}).get("podCIDR")]
            
            if existing_cidrs:
                # Use the first valid CIDR to determine the prefix
                sample = existing_cidrs[0]
                parts = sample.split('.')
                prefix = ".".join(parts[:2])
                
                # Find the highest third octet to pick the next available subnet
                max_x = 0
                for cidr in existing_cidrs:
                    try:
                        x = int(cidr.split('.')[2])
                        if x > max_x: max_x = x
                    except: continue
                
                pod_cidr = f"{prefix}.{max_x + 1}.0/24"
                print(f"  [✓] Assigned node PodCIDR: {pod_cidr} (derived from existing nodes)")
            else:
                print("Warning: No existing nodes have a PodCIDR assigned. If this is a GKE cluster with alias IP, this might be expected. Continuing without explicit PodCIDR.")
        except Exception as e:
            print(f"Error parsing node data: {e}")
    else:
        print("Error: Could not retrieve node information to discover PodCIDR.")

    # Generate Credentials
    print(f"--> Generating credentials for {node_name}...")
    with tempfile.TemporaryDirectory() as tmp_dir:
        # Kubelet Key/CSR
        print("  --> Generating kubelet private key and CSR...")
        key_path = os.path.join(tmp_dir, f"{node_name}.key")
        csr_path = os.path.join(tmp_dir, f"{node_name}.csr")
        cnf_path = os.path.join(tmp_dir, f"openssl-{node_name}.cnf")

        run_command(["openssl", "genrsa", "-out", key_path, "2048"])
        
        with open(cnf_path, "w") as f:
            f.write(f"""[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
string_mask = utf8only
[req_distinguished_name]
CN = system:node:{node_name}
O = system:nodes
[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
""")
        run_command(["openssl", "req", "-new", "-key", key_path, "-out", csr_path, "-config", cnf_path, "-utf8"])
        
        with open(key_path, "rb") as f:
            node_key_b64 = base64.b64encode(f.read()).decode('utf-8')
        with open(csr_path, "rb") as f:
            node_csr_b64 = base64.b64encode(f.read()).decode('utf-8')

        # Create/Approve Kubelet CSR
        print(f"--> Creating and approving CSR for kubelet {node_name} in Kubernetes...")
        run_command(["kubectl", "delete", "node", node_name, "--ignore-not-found"])
        run_command(["kubectl", "delete", "csr", node_name, "--ignore-not-found"])

        csr_obj = {
            "apiVersion": "certificates.k8s.io/v1",
            "kind": "CertificateSigningRequest",
            "metadata": {"name": node_name},
            "spec": {
                "groups": ["system:nodes"],
                "request": node_csr_b64,
                "signerName": "kubernetes.io/kube-apiserver-client-kubelet",
                "usages": ["client auth"]
            }
        }
        subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(csr_obj), text=True, check=True)
        run_command(["kubectl", "certificate", "approve", node_name])

        print("  --> Waiting for signed kubelet client certificate...")
        node_cert_b64 = ""
        for _ in range(10):
            node_cert_b64 = run_command(["kubectl", "get", "csr", node_name, "-o", "jsonpath={.status.certificate}"])
            if node_cert_b64:
                break
            time.sleep(1)
        
        if not node_cert_b64:
            print("Error: Failed to fetch signed kubelet cert.")
            sys.exit(1)

        # Local-Edit Key/CSR
        print("  --> Generating kubernetes-local-edit private key and CSR...")
        le_key_path = os.path.join(tmp_dir, "local-edit.key")
        le_csr_path = os.path.join(tmp_dir, "local-edit.csr")
        le_cnf_path = os.path.join(tmp_dir, "openssl-local-edit.cnf")

        run_command(["openssl", "genrsa", "-out", le_key_path, "2048"])
        with open(le_cnf_path, "w") as f:
            f.write("""[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
string_mask = utf8only
[req_distinguished_name]
CN = cluster-admin
O = cluster-admin
[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = clientAuth
""")
        run_command(["openssl", "req", "-new", "-key", le_key_path, "-out", le_csr_path, "-config", le_cnf_path, "-utf8"])

        with open(le_key_path, "rb") as f:
            le_key_b64 = base64.b64encode(f.read()).decode('utf-8')
        with open(le_csr_path, "rb") as f:
            le_csr_b64 = base64.b64encode(f.read()).decode('utf-8')

        # Create/Approve Local-Edit CSR
        le_csr_name = f"kubernetes-local-edit-{node_name}"
        print(f"--> Creating and approving CSR for {le_csr_name} in Kubernetes...")
        run_command(["kubectl", "delete", "csr", le_csr_name, "--ignore-not-found"])

        le_csr_obj = {
            "apiVersion": "certificates.k8s.io/v1",
            "kind": "CertificateSigningRequest",
            "metadata": {"name": le_csr_name},
            "spec": {
                "groups": ["kubernetes:edit-users", "system:authenticated"],
                "request": le_csr_b64,
                "signerName": "kubernetes.io/kube-apiserver-client",
                "usages": ["client auth"]
            }
        }
        subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(le_csr_obj), text=True, check=True)
        run_command(["kubectl", "certificate", "approve", le_csr_name])

        print("  --> Waiting for signed local-edit certificate...")
        le_cert_b64 = ""
        for _ in range(10):
            le_cert_b64 = run_command(["kubectl", "get", "csr", le_csr_name, "-o", "jsonpath={.status.certificate}"])
            if le_cert_b64:
                break
            time.sleep(1)

        if not le_cert_b64:
            print("Error: Failed to fetch signed local-edit cert.")
            sys.exit(1)

    # Final Output
    print("\n------------------------------------------------------------------------")
    print("  [SUCCESS] All arguments generated and client certificates approved.")
    print("------------------------------------------------------------------------\n")
    
    script_name = "setup_nix_node.py" if target_os == "nixos" else "setup_node.py"
    script_path = f"nixos/{script_name}" if target_os == "nixos" else script_name

    print(f"1. Copy the '{script_path}' script to the new {provider} worker node.\n")
    print(f"2. Run the following command on the new {provider} worker node to join it to the cluster:\n")

    def clean_b64(s):
        return s.replace("\n", "").replace("\r", "")

    setup_cmd = [
        "sudo", "python3", script_name,
        "--name", f'"{node_name}"',
        "--api-url", f'"{api_server_url}"',
        "--ca-cert-base64", f'"{clean_b64(ca_data)}"',
        "--node-private-key-base64", f'"{clean_b64(node_key_b64)}"',
        "--node-client-cert-base64", f'"{clean_b64(node_cert_b64)}"',
        "--local-edit-private-key-base64", f'"{clean_b64(le_key_b64)}"',
        "--local-edit-client-cert-base64", f'"{clean_b64(le_cert_b64)}"',
        "--cluster-dns-ip", f'"{cluster_dns_ip}"',
        "--version", f'"{k8s_version}"',
    ]

    if target_os != "nixos":
        setup_cmd.extend([
            "--containerd-version", f'"{containerd_version}"',
            "--cni-version", f'"{cni_version}"',
        ])

    setup_cmd.append("--provider")
    setup_cmd.append(f'"{provider}"')

    if pod_cidr:
        setup_cmd.extend(["--pod-cidr", f'"{pod_cidr}"'])

    if args.labels:
        setup_cmd.extend(["--labels", f'"{args.labels}"'])
    if args.provider_id:
        setup_cmd.extend(["--provider-id", f'"{args.provider_id}"'])

    print(" ".join(setup_cmd))
    print("\n3. Verify the node has joined:\n   kubectl get nodes")
    print("4. On the node, to use kubectl with edit permissions, you can run:\n   export KUBECONFIG=/etc/kubernetes/local-edit.conf\n   kubectl get nodes")
    print("5. To grant 'edit' ClusterRole permissions to this user, run the following on your control plane:\n   kubectl create clusterrolebinding kubernetes-local-edit-binding --clusterrole=edit --group=kubernetes:edit-users")
    print("\n------------------------------------------------------------------------")

if __name__ == "__main__":
    main()
