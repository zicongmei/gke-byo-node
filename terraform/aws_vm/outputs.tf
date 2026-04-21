output "ssh_commands" {
  value = [
    for instance in aws_instance.vm :
    "ssh -i ~/.ssh/id_rsa ubuntu@${instance.public_ip}"
  ]
}
