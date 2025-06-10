# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"
UBUNTU_BOX = "ubuntu/focal64"

# IPv6 Prefix
IPV6_PREFIX = "fd00:cafe:beef"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|

  # --- Inicio: Deshabilitar vagrant-vbguest ---
  # Esto es para evitar problemas si el plugin vbguest causa errores al intentar
  # actualizar las Guest Additions de VirtualBox.
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
    # Podrías también añadir config.vbguest.no_install = true
    # si auto_update = false no es suficiente para detener su acción.
    # config.vbguest.no_install = true
  end
  # --- Fin: Deshabilitar vagrant-vbguest ---

  config.vm.provider "virtualbox" do |vb|
    vb.memory = "1024"
    vb.cpus = "1"
    # Añadido: Podría ayudar si hay problemas de rendimiento con I/O en Windows. Opcional.
    # vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    # vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
  end

  # 1. Servidor DNS Primario
  config.vm.define "dns-primary" do |dns_primary|
    dns_primary.vm.box = UBUNTU_BOX
    dns_primary.vm.hostname = "dns-primary.example.com"
    dns_primary.vm.network "private_network", ip: "192.168.56.10"
    dns_primary.vm.provision "shell", inline: <<-SHELL
      echo "Provisioning DNS Primary..."
      # Asegura que los scripts son ejecutables dentro de la VM
      chmod +x /vagrant/scripts/bootstrap.sh
      chmod +x /vagrant/scripts/dns-primary-setup.sh
      # Ejecuta los scripts
      /vagrant/scripts/bootstrap.sh #{IPV6_PREFIX}::10 eth1 dns-primary.example.com
      /vagrant/scripts/dns-primary-setup.sh
    SHELL
  end

  # 2. Servidor DNS Secundario
  config.vm.define "dns-secondary" do |dns_secondary|
    dns_secondary.vm.box = UBUNTU_BOX
    dns_secondary.vm.hostname = "dns-secondary.example.com"
    dns_secondary.vm.network "private_network", ip: "192.168.56.11"
    dns_secondary.vm.provision "shell", inline: <<-SHELL
      echo "Provisioning DNS Secondary..."
      chmod +x /vagrant/scripts/bootstrap.sh
      chmod +x /vagrant/scripts/dns-secondary-setup.sh
      /vagrant/scripts/bootstrap.sh #{IPV6_PREFIX}::11 eth1 dns-secondary.example.com
      /vagrant/scripts/dns-secondary-setup.sh
    SHELL
  end

  # 3. Servidor SMTP (Postfix + Dovecot)
  config.vm.define "smtp" do |smtp_server|
    smtp_server.vm.box = UBUNTU_BOX
    smtp_server.vm.hostname = "mail.example.com"
    smtp_server.vm.network "private_network", ip: "192.168.56.12"
    smtp_server.vm.provision "shell", inline: <<-SHELL
      echo "Provisioning SMTP Server..."
      chmod +x /vagrant/scripts/bootstrap.sh
      chmod +x /vagrant/scripts/smtp-setup.sh
      /vagrant/scripts/bootstrap.sh #{IPV6_PREFIX}::12 eth1 mail.example.com
      /vagrant/scripts/smtp-setup.sh
    SHELL
  end

  # 4. Servidor DHCP (Kea)
  config.vm.define "dhcp" do |dhcp_server|
    dhcp_server.vm.box = UBUNTU_BOX
    dhcp_server.vm.hostname = "dhcp.example.com"
    dhcp_server.vm.network "private_network", ip: "192.168.56.13"
    dhcp_server.vm.provision "shell", inline: <<-SHELL
      echo "Provisioning DHCP Server..."
      chmod +x /vagrant/scripts/bootstrap.sh
      chmod +x /vagrant/scripts/dhcp-setup.sh
      /vagrant/scripts/bootstrap.sh #{IPV6_PREFIX}::13 eth1 dhcp.example.com
      /vagrant/scripts/dhcp-setup.sh
    SHELL
  end
end