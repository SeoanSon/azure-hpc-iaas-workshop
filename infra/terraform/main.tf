terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}

variable "ssh_source_cidr" {
  type        = string
  description = "Trusted source CIDR allowed to connect to the head node over SSH"
}

variable "vm_size" {
  type    = string
  default = "Standard_D8s_v5"
}

resource "azurerm_resource_group" "workshop" {
  name     = "rg-hpc-workshop"
  location = var.location
}

resource "azurerm_virtual_network" "hpc" {
  name                = "vnet-hpc"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.workshop.location
  resource_group_name = azurerm_resource_group.workshop.name
}

resource "azurerm_subnet" "hpc" {
  name                 = "subnet-hpc"
  resource_group_name  = azurerm_resource_group.workshop.name
  virtual_network_name = azurerm_virtual_network.hpc.name
  address_prefixes     = ["10.0.0.0/24"]
}

resource "azurerm_network_security_group" "hpc" {
  name                = "nsg-hpc"
  location            = azurerm_resource_group.workshop.location
  resource_group_name = azurerm_resource_group.workshop.name

  security_rule {
    name                       = "AllowSSHFromTrustedCIDR"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.ssh_source_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "hpc" {
  subnet_id                 = azurerm_subnet.hpc.id
  network_security_group_id = azurerm_network_security_group.hpc.id
}

resource "azurerm_public_ip" "head" {
  name                = "headnode-pip"
  location            = azurerm_resource_group.workshop.location
  resource_group_name = azurerm_resource_group.workshop.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "head" {
  name                = "headnode-nic"
  location            = azurerm_resource_group.workshop.location
  resource_group_name = azurerm_resource_group.workshop.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.hpc.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.head.id
  }
}

resource "azurerm_linux_virtual_machine" "head" {
  name                = "headnode"
  resource_group_name = azurerm_resource_group.workshop.name
  location            = azurerm_resource_group.workshop.location
  size                = var.vm_size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.head.id
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_linux_virtual_machine_scale_set" "compute" {
  name                = "hpc-compute"
  resource_group_name = azurerm_resource_group.workshop.name
  location            = azurerm_resource_group.workshop.location
  sku                 = var.vm_size
  instances           = 2
  admin_username      = var.admin_username
  upgrade_mode        = "Manual"

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "compute-nic"
    primary = true

    network_security_group_id = azurerm_network_security_group.hpc.id

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.hpc.id
    }
  }
}

output "head_node_public_ip" {
  value = azurerm_public_ip.head.ip_address
}
