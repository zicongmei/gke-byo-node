#!/usr/bin/env python3

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request

def run_command(command, shell=False, check=True, text=True, capture_output=True):
    try:
        result = subprocess.run(
            command, shell=shell, check=check, text=text,
            capture_output=capture_output
        )
        return result.stdout.strip() if result.stdout else ""
    except subprocess.CalledProcessError as e:
        print(f"Error executing command: {command}")
        print(f"Stdout: {e.stdout}")
        print(f"Stderr: {e.stderr}")
        if check:
            sys.exit(1)
        return None

def download_file(url, dest):
    print(f"  --> Downloading from {url}...")
    try:
        urllib.request.urlretrieve(url, dest)
    except Exception as e:
        print(f"Error downloading {url}: {e}")
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Configure machine as a Kubernetes worker node.")
    parser.add_argument("--name", required=True)
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--ca-cert-base64", required=True)
    parser.add_argument("--node-private-key-base64", required=True)
    parser.add_argument("--node-client-cert-base64", required=True)
    parser.add_argument("--local-edit-private-key-base64", required=True)
    parser.add_argument("--local-edit-client-cert-base64", required=True)
    parser.add_argument("--cluster-dns-ip", required=True)
    parser.add_argument("--pod-cidr")
    parser.add_argument("--version", required=True)
    parser.add_argument("--containerd-version", default="1.7.22")
    parser.add_argument("--cni-version", default="1.5.1")
    parser.add_argument("--provider", choices=["gcp", "aws", "azure"], default="gcp")
    parser.add_argument("--labels")
    parser.add_argument("--provider-id")

    args = parser.parse_args()

    node_name = args.name
    k8s_version = args.version.lstrip('v')
    containerd_version = args.containerd_version.lstrip('v')
    cni_version = args.cni_version.lstrip('v')
    provider = args.provider

    aws_region = ""
    aws_zone = ""
    azure_location = ""
    azure_zone = ""

    if provider == "aws":
        print("--> Detecting AWS region and availability zone...")
        try:
            req = urllib.request.Request("http://169.254.169.254/latest/api/token", method="PUT")
            req.add_header("X-aws-ec2-metadata-token-ttl-seconds", "21600")
            with urllib.request.urlopen(req) as response:
                token = response.read().decode('utf-8')
            
            req_zone = urllib.request.Request("http://169.254.169.254/latest/meta-data/placement/availability-zone")
            req_zone.add_header("X-aws-ec2-metadata-token", token)
            with urllib.request.urlopen(req_zone) as response:
                aws_zone = response.read().decode('utf-8')
        except:
            print("    [i] Failed to get IMDSv2 token. Trying IMDSv1...")
            try:
                with urllib.request.urlopen("http://169.254.169.254/latest/meta-data/placement/availability-zone") as response:
                    aws_zone = response.read().decode('utf-8')
            except:
                print("Error: Failed to detect AWS availability zone.")
                sys.exit(1)
        
        aws_region = aws_zone[:-1]
        print(f"  [✓] Detected AWS Region: {aws_region}, Zone: {aws_zone}")

    elif provider == "azure":
        print("--> Detecting Azure location and availability zone...")
        try:
            req = urllib.request.Request("http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01")
            req.add_header("Metadata", "true")
            with urllib.request.urlopen(req) as response:
                metadata = json.loads(response.read().decode('utf-8'))
                azure_location = metadata["location"]
                azure_zone = metadata.get("zone", "none")
        except:
            print("Error: Failed to fetch Azure metadata.")
            sys.exit(1)
        print(f"  [✓] Detected Azure Location: {azure_location}, Zone: {azure_zone}")

    print(f"--- Starting Kubernetes Worker Node Setup for {node_name} (K8s Version: {k8s_version}, Containerd: {containerd_version}, CNI: {cni_version}) ---")

    # Architecture
    print("  --> Determining architecture...")
    machine_arch = os.uname().machine
    arch = "amd64" if machine_arch == "x86_64" else "arm64" if machine_arch == "aarch64" else None
    if not arch:
        print(f"Error: Unsupported machine architecture: {machine_arch}")
        sys.exit(1)
    print(f"  [✓] Detected architecture: {arch}")

    # Step 1: System Preparation
    print("--> [1/7] Preparing system: disabling swap, loading kernel modules, and configuring sysctl parameters...")
    run_command(["swapoff", "-a"])
    run_command(["sed", "-i", "/ swap / s/^\\(.*\\)$/#\\1/g", "/etc/fstab"])
    
    run_command(["modprobe", "overlay"], check=False)
    run_command(["modprobe", "br_netfilter"], check=False)
    
    os.makedirs("/etc/sysctl.d/", exist_ok=True)
    with open("/etc/sysctl.d/kubernetes.conf", "w") as f:
        f.write("net.bridge.bridge-nf-call-iptables=1\nnet.ipv4.ip_forward=1\nnet.bridge.bridge-nf-call-ip6tables=1\n")
    run_command(["sysctl", "--system"])
    print("  [✓] System prepared.")

    # Step 2: Install CNI Plugins
    print("--> [2/7] Installing CNI plugins...")
    os.makedirs("/opt/cni/bin", exist_ok=True)
    cni_url = f"https://github.com/containernetworking/plugins/releases/download/v{cni_version}/cni-plugins-linux-{arch}-v{cni_version}.tgz"
    download_file(cni_url, "cni-plugins.tgz")
    with tarfile.open("cni-plugins.tgz", "r:gz") as tar:
        tar.extractall("/opt/cni/bin")
    os.remove("cni-plugins.tgz")
    print("  [✓] CNI plugins installed.")

    # Step 3: Install containerd
    print("--> [3/7] Installing containerd runtime...")
    run_command(["systemctl", "stop", "containerd"], check=False)
    
    containerd_url = f"https://github.com/containerd/containerd/releases/download/v{containerd_version}/cri-containerd-{containerd_version}-linux-{arch}.tar.gz"
    download_file(containerd_url, "containerd.tar.gz")
    
    # Use shell tar as it handles overwriting busy binaries better than Python's tarfile
    run_command(["tar", "-xvf", "containerd.tar.gz", "-C", "/"])
    os.remove("containerd.tar.gz")
    
    os.makedirs("/etc/containerd", exist_ok=True)
    if not os.path.exists("/etc/containerd/config.toml"):
        print("  [W] /etc/containerd/config.toml not found. Generating default...")
        run_command(["/usr/local/bin/containerd", "config", "default"], capture_output=False, shell=False)
        # Re-capture to write to file
        default_config = run_command(["/usr/local/bin/containerd", "config", "default"])
        with open("/etc/containerd/config.toml", "w") as f:
            f.write(default_config)
            
    run_command(["sed", "-i", "s/SystemdCgroup = false/SystemdCgroup = true/", "/etc/containerd/config.toml"])
    run_command(["systemctl", "daemon-reload"])
    run_command(["systemctl", "enable", "containerd"])
    run_command(["systemctl", "restart", "containerd"])
    print("  [✓] Containerd installed and started.")

    # Step 4: Install K8s Components
    print("--> [4/7] Installing kubelet and kubectl...")
    for bin_path in ["/usr/bin/kubelet", "/usr/bin/kubectl"]:
        if os.path.exists(bin_path):
            os.remove(bin_path)
            
    kubelet_url = f"https://dl.k8s.io/release/v{k8s_version}/bin/linux/{arch}/kubelet"
    kubectl_url = f"https://dl.k8s.io/release/v{k8s_version}/bin/linux/{arch}/kubectl"
    
    download_file(kubelet_url, "/usr/bin/kubelet")
    download_file(kubectl_url, "/usr/bin/kubectl")
    os.chmod("/usr/bin/kubelet", 0o755)
    os.chmod("/usr/bin/kubectl", 0o755)
    print("  [✓] Kubernetes components installed.")

    # Step 5: Credentials and Kubeconfig
    print("--> [5/7] Placing credentials and kubeconfig files...")
    os.makedirs("/var/lib/kubelet", exist_ok=True)
    os.makedirs("/etc/kubernetes/pki", exist_ok=True)
    
    with open("/etc/kubernetes/pki/ca.crt", "wb") as f:
        f.write(base64.b64decode(args.ca_cert_base64))
    with open(f"/var/lib/kubelet/{node_name}.key", "wb") as f:
        f.write(base64.b64decode(args.node_private_key_base64))
    with open(f"/var/lib/kubelet/{node_name}.crt", "wb") as f:
        f.write(base64.b64decode(args.node_client_cert_base64))
    os.chmod(f"/var/lib/kubelet/{node_name}.key", 0o600)

    with open("/etc/kubernetes/local-edit.key", "wb") as f:
        f.write(base64.b64decode(args.local_edit_private_key_base64))
    with open("/etc/kubernetes/local-edit.crt", "wb") as f:
        f.write(base64.b64decode(args.local_edit_client_cert_base64))
    os.chmod("/etc/kubernetes/local-edit.key", 0o600)

    # Kubelet kubeconfig
    run_command(["kubectl", "config", "set-cluster", "k8s-manual", "--server", args.api_url, "--certificate-authority", "/etc/kubernetes/pki/ca.crt", "--kubeconfig", "/var/lib/kubelet/kubeconfig", "--embed-certs=true"])
    run_command(["kubectl", "config", "set-credentials", f"system:node:{node_name}", "--client-certificate", f"/var/lib/kubelet/{node_name}.crt", "--client-key", f"/var/lib/kubelet/{node_name}.key", "--kubeconfig", "/var/lib/kubelet/kubeconfig", "--embed-certs=true"])
    run_command(["kubectl", "config", "set-context", "default", "--cluster", "k8s-manual", "--user", f"system:node:{node_name}", "--kubeconfig", "/var/lib/kubelet/kubeconfig"])
    run_command(["kubectl", "config", "use-context", "default", "--kubeconfig", "/var/lib/kubelet/kubeconfig"])
    shutil.copy("/var/lib/kubelet/kubeconfig", "/etc/kubernetes/bootstrap-kubelet.conf")

    # Local-edit kubeconfig
    run_command(["kubectl", "config", "set-cluster", "k8s-manual", "--server", args.api_url, "--certificate-authority", "/etc/kubernetes/pki/ca.crt", "--kubeconfig", "/etc/kubernetes/local-edit.conf", "--embed-certs=true"])
    run_command(["kubectl", "config", "set-credentials", "kubernetes-local-edit", "--client-certificate", "/etc/kubernetes/local-edit.crt", "--client-key", "/etc/kubernetes/local-edit.key", "--kubeconfig", "/etc/kubernetes/local-edit.conf", "--embed-certs=true"])
    run_command(["kubectl", "config", "set-context", "default", "--cluster", "k8s-manual", "--user", "kubernetes-local-edit", "--kubeconfig", "/etc/kubernetes/local-edit.conf"])
    run_command(["kubectl", "config", "use-context", "default", "--kubeconfig", "/etc/kubernetes/local-edit.conf"])
    print("  [✓] Credentials and kubeconfigs created.")

    # Step 6: Configure Kubelet
    print("--> [6/7] Creating kubelet configuration and systemd service...")
    if os.path.exists("/etc/systemd/system/kubelet.service.d"):
        shutil.rmtree("/etc/systemd/system/kubelet.service.d")
        os.makedirs("/etc/systemd/system/kubelet.service.d")

    if provider == "aws":
        print("  --> [AWS] Configuring local bridge CNI...")
        kubeconfig_path = "/etc/kubernetes/local-edit.conf"
        pod_cidr = args.pod_cidr
        
        if not pod_cidr:
            print("    [i] PodCIDR not provided via argument. Fetching from node object...")
            pod_cidr = run_command(["/usr/bin/kubectl", "get", "node", node_name, "--kubeconfig", kubeconfig_path, "-o", "jsonpath={.spec.podCIDR}"], check=False)
        
        if pod_cidr:
            print(f"    [i] Using PodCIDR: {pod_cidr}. Patching node to ensure consistency...")
            patch_payload = json.dumps({"spec": {"podCIDR": pod_cidr, "podCIDRs": [pod_cidr]}})
            run_command(["/usr/bin/kubectl", "patch", "node", node_name, "--kubeconfig", kubeconfig_path, "-p", patch_payload], check=False)
            
            os.makedirs("/etc/cni/net.d", exist_ok=True)
            with open("/etc/cni/net.d/10-bridge.conf", "w") as f:
                f.write(f"""{{
  "cniVersion": "0.3.1",
  "name": "bridge",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {{
    "type": "host-local",
    "ranges": [
      [
        {{
          "subnet": "{pod_cidr}"
        }}
      ]
    ],
    "routes": [
      {{
        "dst": "0.0.0.0/0"
      }}
    ]
  }}
}}
""")
        else:
            print("    [!] PodCIDR not provided and not assigned to node. CNI configuration skipped.")

    kubelet_config = f"""apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/etc/kubernetes/pki/ca.crt"
authorization:
  mode: Webhook
clusterDNS:
  - "{args.cluster_dns_ip}"
clusterDomain: "cluster.local"
rotateCertificates: true
tlsCertFile: "/var/lib/kubelet/{node_name}.crt"
tlsPrivateKeyFile: "/var/lib/kubelet/{node_name}.key"
"""
    with open("/var/lib/kubelet/config.yaml", "w") as f:
        f.write(kubelet_config)

    kubelet_labels = "node.kubernetes.io/kube-proxy-ds-ready=true"
    if provider == "aws":
        kubelet_labels += f",topology.kubernetes.io/region={aws_region},topology.kubernetes.io/zone={aws_zone}"
    elif provider == "azure":
        kubelet_labels += f",topology.kubernetes.io/region={azure_location}"
        if azure_zone != "none":
            kubelet_labels += f",topology.kubernetes.io/zone={azure_location}-{azure_zone}"
    
    if args.labels:
        kubelet_labels += f",{args.labels}"

    exec_start = f"/usr/bin/kubelet --config=/var/lib/kubelet/config.yaml --kubeconfig=/var/lib/kubelet/kubeconfig --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock --register-node=true --hostname-override={node_name} --node-labels={kubelet_labels} --v=2"
    if args.provider_id:
        exec_start += f" --provider-id={args.provider_id}"

    with open("/etc/systemd/system/kubelet.service", "w") as f:
        f.write(f"""[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart={exec_start}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
""")
    print("  [✓] Kubelet service configured.")

    # Step 7: Start Services
    print("--> [7/7] Enabling and starting kubelet services...")
    run_command(["systemctl", "daemon-reload"])
    run_command(["systemctl", "enable", "kubelet"])
    run_command(["systemctl", "restart", "kubelet"])
    print("  [✓] Kubelet service started.")
    print("\n------------------------------------------------------------------------")
    print("  [SUCCESS] Worker node setup is complete.")
    print("------------------------------------------------------------------------")

if __name__ == "__main__":
    main()
