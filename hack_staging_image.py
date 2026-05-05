#!/usr/bin/env python3

import re
import subprocess
import sys

def run_command(command, shell=False, check=True):
    try:
        result = subprocess.run(
            command, shell=shell, check=check, text=True,
            capture_output=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        if check:
            print(f"Error executing command: {command}")
            print(f"Stderr: {e.stderr}")
            sys.exit(1)
        return None

def main():
    print("--- GKE BYO Node Image Hacker (Log-based) ---")
    
    # 1. Search logs for staging images
    print("--> Searching containerd logs for failing staging images...")
    logs = run_command(["sudo", "journalctl", "-u", "containerd", "--no-pager", "-n", "2000"])
    
    # Regex to find image names containing 'gke-release-staging'
    # We clean up backslashes usually found in logs
    staging_images = set(re.findall(r'[^ "\']*gke-release-staging[^ "\']*', logs.replace('\\', '')))
    
    if not staging_images:
        print("  [!] No staging images found in recent logs.")
        print("      If you just started the node, wait a minute for pull attempts to fail and show up in logs.")
        return

    # 2. Fix images
    for staging_image in sorted(list(staging_images)):
        print("-" * 51)
        print(f"Found staging image: {staging_image}")
        
        # Extract suffix (e.g., node_token_broker/init:v1)
        # Note: In bash it was $NF, which is the part after the LAST slash.
        suffix = staging_image.split('/')[-1]
        
        # 2a. Try gcr.io/gke-release
        release_image = f"gcr.io/gke-release/{suffix}"
        print(f"  [+] Pulling equivalent from: {release_image}")
        
        pull_cmd = ["sudo", "ctr", "-n", "k8s.io", "images", "pull", release_image]
        if run_command(pull_cmd, check=False) is not None:
            print("  [✓] Successfully pulled. Tagging as staging name...")
            run_command(["sudo", "ctr", "-n", "k8s.io", "images", "tag", release_image, staging_image])
            print("  [✓] Done.")
        else:
            print(f"  [X] FAILED to pull from {release_image}")
            
            # 2b. Try registry.k8s.io fallback
            k8s_release = f"registry.k8s.io/{suffix}"
            print(f"  [+] Attempting fallback pull from: {k8s_release}")
            if run_command(["sudo", "ctr", "-n", "k8s.io", "images", "pull", k8s_release], check=False) is not None:
                run_command(["sudo", "ctr", "-n", "k8s.io", "images", "tag", k8s_release, staging_image])
                print("  [✓] Successfully pulled from registry.k8s.io and tagged.")
            else:
                print("  [X] Fallback also failed.")

    print("-" * 51)
    print("Image hacking complete. Containerd should now be able to provide these images to Kubelet.")

if __name__ == "__main__":
    main()
