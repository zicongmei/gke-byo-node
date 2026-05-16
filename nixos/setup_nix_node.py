#!/usr/bin/env python3

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
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

def safe_b64decode(s):
    import re
    # Remove all non-base64 characters (only keep A-Z, a-z, 0-9, +, /, and =)
    s = re.sub(r'[^A-Za-z0-9+/=]', '', s)
    padding = len(s) % 4
    if padding == 1:
        # This is technically invalid, but let's try to fix it by dropping the last char
        # or adding padding if it was just a missing char. 
        # Usually % 4 == 1 means corruption.
        s = s[:-1]
    elif padding > 1:
        s += "=" * (4 - padding)
    return base64.b64decode(s)

def download_file(url, dest):
    print(f"  --> Downloading from {url}...")
    try:
        urllib.request.urlretrieve(url, dest)
    except Exception as e:
        print(f"Error downloading {url}: {e}")
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Configure NixOS machine as a Kubernetes worker node.")
    parser.add_argument("--json-args")
    parser.add_argument("--name")
    parser.add_argument("--api-url")
    parser.add_argument("--ca-cert-base64")
    parser.add_argument("--node-private-key-base64")
    parser.add_argument("--node-client-cert-base64")
    parser.add_argument("--local-edit-private-key-base64")
    parser.add_argument("--local-edit-client-cert-base64")
    parser.add_argument("--cluster-dns-ip")
    parser.add_argument("--pod-cidr")
    parser.add_argument("--version")
    parser.add_argument("--provider", choices=["gcp", "aws", "azure"], default="gcp")
    parser.add_argument("--labels")
    parser.add_argument("--provider-id")

    args = parser.parse_args()

    if args.json_args and os.path.exists(args.json_args):
        with open(args.json_args, "r") as f:
            jargs = json.load(f)
            for k, v in jargs.items():
                setattr(args, k.replace("-", "_"), v)

    if os.geteuid() != 0:
        print("Error: This script must be run as root (sudo).")
        sys.exit(1)

    node_name = args.name
    provider = args.provider

    print(f"--- Starting NixOS Kubernetes Worker Node Setup for {node_name} ---")

    # Step 1: Place Credentials
    print("--> [1/4] Placing credentials...")
    os.makedirs("/etc/kubernetes/pki", exist_ok=True)
    os.makedirs("/var/lib/kubelet", exist_ok=True)

    with open("/etc/kubernetes/pki/ca.crt", "wb") as f:
        f.write(safe_b64decode(args.ca_cert_base64))
    with open(f"/var/lib/kubelet/node.key", "wb") as f:
        f.write(safe_b64decode(args.node_private_key_base64))
    with open(f"/var/lib/kubelet/node.crt", "wb") as f:
        f.write(safe_b64decode(args.node_client_cert_base64))
    
    with open("/etc/kubernetes/local-edit.key", "wb") as f:
        f.write(safe_b64decode(args.local_edit_private_key_base64))
    with open("/etc/kubernetes/local-edit.crt", "wb") as f:
        f.write(safe_b64decode(args.local_edit_client_cert_base64))
    
    os.chmod("/var/lib/kubelet/node.key", 0o600)
    os.chmod("/etc/kubernetes/local-edit.key", 0o600)

    # Generate local-edit kubeconfig (needed for patching PodCIDR later if required)
    print("--> [2/4] Generating temporary kubeconfig for setup...")
    local_kubeconfig = f"""
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: {args.api_url}
  name: k8s-manual
contexts:
- context:
    cluster: k8s-manual
    user: kubernetes-local-edit
  name: default
current-context: default
users:
- name: kubernetes-local-edit
  user:
    client-certificate: /etc/kubernetes/local-edit.crt
    client-key: /etc/kubernetes/local-edit.key
"""
    with open("/etc/kubernetes/local-edit.conf", "w") as f:
        f.write(local_kubeconfig)

    # Step 3: Generate NixOS Configuration
    print("--> [3/4] Generating NixOS configuration module...")
    
    # Try to capture current SSH keys to avoid lockout
    ssh_keys_list = []
    try:
        if os.path.exists("/root/.ssh/authorized_keys"):
            with open("/root/.ssh/authorized_keys", "r") as f:
                ssh_keys_list = [line.strip() for line in f if line.strip() and not line.startswith("#")]
        elif os.path.exists("/etc/ssh/authorized_keys.d/root"):
             with open("/etc/ssh/authorized_keys.d/root", "r") as f:
                ssh_keys_list = [line.strip() for line in f if line.strip() and not line.startswith("#")]
    except Exception as e:
        print(f"  [!] Warning: Could not read existing SSH keys: {e}")

    ssh_keys_nix = "\n".join([f'      "{key}"' for key in ssh_keys_list])
    
    # Extract masterAddress from api_url
    master_address = args.api_url.replace("https://", "").replace("http://", "").split(":")[0]

    k8s_package_line = ""
    custom_package_nix = ""
    if args.version:
        k8s_version = args.version.lstrip('v')
        machine_arch = os.uname().machine
        arch = "amd64" if machine_arch == "x86_64" else "arm64" if machine_arch == "aarch64" else "amd64"
        
        bin_dir = "/var/lib/kubernetes/binaries"
        os.makedirs(bin_dir, exist_ok=True)
        print(f"--> Downloading Kubernetes v{k8s_version} binaries ({arch})...")
        
        for bin_name in ["kubelet", "kubectl", "kube-proxy"]:
            url = f"https://dl.k8s.io/release/v{k8s_version}/bin/linux/{arch}/{bin_name}"
            dest = os.path.join(bin_dir, bin_name)
            if not os.path.exists(dest):
                download_file(url, dest)
                os.chmod(dest, 0o755)

        v_parts = k8s_version.split('.')
        v_attr = f"kubernetes_{v_parts[0]}_{v_parts[1]}"
        
        custom_package_nix = f"""
  customK8s = (pkgs.stdenv.mkDerivation {{
    name = "kubernetes-custom-{k8s_version}";
    src = {bin_dir};
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    phases = [ "installPhase" "fixupPhase" ];
    installPhase = ''
      mkdir -p $out/bin
      cp $src/kubelet $out/bin/.kubelet-wrapped
      cp $src/kubectl $out/bin/kubectl
      cp $src/kube-proxy $out/bin/kube-proxy
      
      cat <<EOF > $out/bin/kubelet
#!/bin/sh
args=""
for arg in "\\$@"; do
  case "\\$arg" in
    --pod-infra-container-image=*) ;;
    *) args="\\$args \\"\\$arg\\"" ;;
  esac
done
eval exec $out/bin/.kubelet-wrapped \\$args
EOF
      chmod +x $out/bin/kubelet
      chmod +x $out/bin/.kubelet-wrapped $out/bin/kubectl $out/bin/kube-proxy
    '';
  }}) // {{ pause = pkgs.kubernetes.pause; }};
"""
        k8s_package_line = f"\n    package = customK8s;"

    kubelet_labels = "node.kubernetes.io/kube-proxy-ds-ready=true"
    if args.labels:
        kubelet_labels += f",{args.labels}"
    
    provider_id_opt = f'\n      providerId = "{args.provider_id}";' if args.provider_id else ""
    cluster_cidr_opt = f'\n    clusterCidr = "{args.pod_cidr}";' if args.pod_cidr else ""

    # Bridge CNI logic
    pod_cidr = args.pod_cidr
    cni_nix_config = ""
    if pod_cidr:
        cni_nix_config = f"""
  services.kubernetes.kubelet.cni.config = [
    {{
      "cniVersion" = "0.3.1";
      "name" = "bridge";
      "type" = "bridge";
      "bridge" = "cni0";
      "isGateway" = true;
      "ipMasq" = true;
      "ipam" = {{
        "type" = "host-local";
        "ranges" = [
          [ {{ "subnet" = "{pod_cidr}"; }} ]
        ];
        "routes" = [ {{ "dst" = "0.0.0.0/0"; }} ];
      }};
    }}
  ];
"""

    let_block = ""
    if custom_package_nix:
        let_block = f"let\n{custom_package_nix}\nin"

    nix_config = f"""# Auto-generated by setup_node.py
{{ config, lib, pkgs, ... }}:
{let_block}
{{
  boot.kernelModules = [ "overlay" "br_netfilter" ];
  boot.kernel.sysctl = {{
    "net.bridge.bridge-nf-call-iptables" = lib.mkForce 1;
    "net.ipv4.ip_forward" = lib.mkForce 1;
    "net.bridge.bridge-nf-call-ip6tables" = lib.mkForce 1;
  }};

  # Disable firewall as it often interferes with K8s networking
  networking.firewall.enable = lib.mkForce false;
  
  # Preserve SSH keys
  users.users.root.openssh.authorizedKeys.keys = [
{ssh_keys_nix}
  ];

  swapDevices = lib.mkForce [];

  virtualisation.containerd = {{
    enable = true;
    settings = {{
      plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options.SystemdCgroup = true;
    }};
  }};

  services.kubernetes = {{
    roles = [ "node" ];{k8s_package_line}
    masterAddress = "{master_address}";{cluster_cidr_opt}
    easyCerts = false;
    caFile = "/etc/kubernetes/pki/ca.crt";

    # Explicitly disable flannel as we use bridge CNI or GKE manages it
    flannel.enable = lib.mkForce false;

    kubelet = {{
      enable = true;
      hostname = lib.mkForce "{node_name}";
      kubeconfig = {{
        server = "{args.api_url}";
        certFile = "/var/lib/kubelet/node.crt";
        keyFile = "/var/lib/kubelet/node.key";
      }};
      tlsCertFile = "/var/lib/kubelet/node.crt";
      tlsKeyFile = "/var/lib/kubelet/node.key";
      clusterDns = [ "{args.cluster_dns_ip}" ];
      extraOpts = "--node-labels={kubelet_labels} --v=2";{provider_id_opt}
    }};

    proxy = {{
      enable = true;
      hostname = lib.mkForce "{node_name}";
      kubeconfig = {{
        server = "{args.api_url}";
        certFile = "/var/lib/kubelet/node.crt";
        keyFile = "/var/lib/kubelet/node.key";
      }};
    }};
  }};
{cni_nix_config}
  # Ensure kubectl is available for debugging
  environment.systemPackages = [ pkgs.kubectl pkgs.conntrack-tools pkgs.iptables ];
}}
"""
    with open("/etc/nixos/kubernetes-node.nix", "w") as f:
        f.write(nix_config)

    # Ensure it's imported in configuration.nix
    if os.path.exists("/etc/nixos/configuration.nix"):
        with open("/etc/nixos/configuration.nix", "r") as f:
            content = f.read()
        if "./kubernetes-node.nix" not in content:
            print("  [i] Adding import to /etc/nixos/configuration.nix...")
            # Simple insertion before the last closing brace or in imports list
            if "imports = [" in content:
                new_content = content.replace("imports = [", "imports = [\n    ./kubernetes-node.nix")
            else:
                new_content = content.rstrip().rstrip('}') + "\n  imports = [ ./kubernetes-node.nix ];\n}"
            with open("/etc/nixos/configuration.nix", "w") as f:
                f.write(new_content)

    # Step 4: Apply Configuration
    print("--> [4/4] Applying NixOS configuration (nixos-rebuild switch)...")
    run_command(["nixos-rebuild", "switch"])

    print("\n------------------------------------------------------------------------")
    print("  [SUCCESS] NixOS worker node setup is complete.")
    print("------------------------------------------------------------------------")

if __name__ == "__main__":
    main()
