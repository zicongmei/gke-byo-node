output "ssh_commands" {
  value = [
    for instance in azurerm_linux_virtual_machine.vm :
    "ssh -i ~/.ssh/id_rsa ubuntu@${instance.public_ip_address}"
  ]
}

output "scp_commands" {
  value = [
    for instance in azurerm_linux_virtual_machine.vm :
    "scp -i ~/.ssh/id_rsa setup_node.py ubuntu@${instance.public_ip_address}:~/"
  ]
}
