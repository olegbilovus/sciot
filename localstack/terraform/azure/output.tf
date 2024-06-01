output "public_ips" {
  value = azurerm_linux_virtual_machine.vm.public_ip_addresses[0]
}
