#!/bin/bash
set -e

NODE_NAME="zicong-aws-vm-0"
K8S_VERSION="1.35.3"
REMOTE_IP="100.23.209.171"
SSH_KEY="$HOME/.ssh/id_rsa"

echo "--> Generating join command locally..."
JOIN_CMD=$(./generate-node-args.sh --node "$NODE_NAME" --version "$K8S_VERSION" --provider aws | grep "sudo ./setup-node.sh")

if [ -z "$JOIN_CMD" ]; then
    echo "Error: Failed to capture join command from generate-node-args.sh"
    exit 1
fi

echo "--> Creating remote execution script..."
cat > to_run.sh <<EOF
#!/bin/bash
$JOIN_CMD
EOF
chmod +x to_run.sh

echo "--> Copying scripts to remote VM ($REMOTE_IP)..."
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" setup-node.sh ubuntu@$REMOTE_IP:~/setup-node.sh
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" to_run.sh ubuntu@$REMOTE_IP:~/to_run.sh

echo "--> Executing setup on remote VM..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" ubuntu@$REMOTE_IP './to_run.sh'

echo "--> Node join process completed."
