output "ssh_commands" {
  value = [
    for instance in aws_instance.vm :
    "ssh -i ~/.ssh/id_rsa ubuntu@${instance.public_ip}"
  ]
}

output "scp_commands" {
  value = [
    for instance in aws_instance.vm :
    "scp -i ~/.ssh/id_rsa setup-node.sh ubuntu@${instance.public_ip}:~/setup-node.sh"
  ]
}
