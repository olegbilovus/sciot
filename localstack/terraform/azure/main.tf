terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.97.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.0.5"
    }
  }
  required_version = ">= 1.8.1"
}

provider "azurerm" {
  features {}
}

locals {
  name     = "localstack"
  location = "germanywestcentral"
}

# RG
resource "azurerm_resource_group" "localstack" {
  name     = local.name
  location = local.location
}

# Network
resource "azurerm_virtual_network" "localstack" {
  name                = local.name
  address_space       = ["10.0.0.0/16"]
  location            = local.location
  resource_group_name = azurerm_resource_group.localstack.name
}

# subnet
resource "azurerm_subnet" "vm" {
  name                 = "vm"
  resource_group_name  = azurerm_resource_group.localstack.name
  virtual_network_name = azurerm_virtual_network.localstack.name
  address_prefixes     = ["10.0.2.0/24"]
}

# NSG
resource "azurerm_network_security_group" "nsg" {
  name                = local.name
  location            = local.location
  resource_group_name = azurerm_resource_group.localstack.name
}

# NSG SSH
resource "azurerm_network_security_rule" "ssh" {
  name                        = "allow-ssh"
  priority                    = 1000
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.localstack.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

# Connect the security group to the internal subnet
resource "azurerm_subnet_network_security_group_association" "nsg-vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

########### SSH Key #########
# ssh key
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = "4096"
}

# save ssh private key
resource "local_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "azure_localstack.pem"
  file_permission = "0600"
}

# cloud-init
# run "cloud-init status --wait" in the SSH to check when it is done
# run "tail -f /var/log/cloud-init-output.log" to see what it is doing
data "cloudinit_config" "conf" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content      = file("./cloud-init.yaml")
    filename     = "conf.yaml"
  }
}

# public ip
resource "azurerm_public_ip" "vm" {
  name                = local.name
  resource_group_name = azurerm_resource_group.localstack.name
  location            = local.location
  allocation_method   = "Dynamic"
}

# network interface
resource "azurerm_network_interface" "vm" {
  name                = local.name
  location            = local.location
  resource_group_name = azurerm_resource_group.localstack.name

  ip_configuration {
    name                          = local.name
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

# Connect the security group to the network interface
resource "azurerm_network_interface_security_group_association" "ni_nsg" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# The VM
resource "azurerm_linux_virtual_machine" "vm" {
  name                = local.name
  resource_group_name = azurerm_resource_group.localstack.name
  location            = local.location
  size                = "Standard_B2s" #B1s has not enough memory
  admin_username      = "azureuser"
  network_interface_ids = [
    azurerm_network_interface.vm.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = chomp(tls_private_key.ssh.public_key_openssh)
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "None"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = data.cloudinit_config.conf.rendered
}
