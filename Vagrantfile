# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"
UBUNTU_BOX = "ubuntu/focal64"
PRIMARY_DOMAIN = "grindavik.xyz" # Nuevo dominio

# IPv6 Prefix
IPV6_PREFIX = "fd00:cafe:beef"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|

  # --- Inicio: Deshabilitar vagrant-vbguest ---
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
    # config.vbguest.no_install = true
  end
  # --- Fin: Deshabilitar vagrant-vbguest ---

  config.vm.provider "virtualbox" do |vb|
    vb.memory = "1024"
    vb.cpus = "1"
  end

  # --- INICIO: Configurar opciones de montaje para carpetas compartidas ---
  config.vm.synced_folder ".", "/vagrant",
    owner: "vagrant",
    group: "vagrant",
    mount_options: ["dmode=755,fmode=755"]
  # --- FIN: Configurar opciones de montaje ---

  # 1. Servidor DNS Primario
  config.vm.define "dns-primary" do |dns_primary|
    dns_primary.vm.box = UBUNTU_BOX
    dns_primary.vm.hostname = "ns1.#{PRIMARY_DOMAIN}" # ns1.grindavik.xyz
    dns_primary.vm.network "private_network", ip: "192.168.56.10"
    dns_primary.vm.provision "shell", inline: <<-SHELL
      echo "Provisioning DNS Primary (ns1.#{PRIMARY_DOMAIN})..."
      /vagrant/scripts/bootstrap.sh #{IPV6_PREFIX}::10 ns1.#{PRIMARY_DOMAIN}
      /vagrant/scripts/dns-primary-setup.sh
    SHELL
  end

  # 2. Servidor DNS Secundario
  config.vm.define "dns-secondary" do |dns_secondary|
    dns_secondary.vm.box = UBUNTU_BOX
    dns_secondary.vm.hostname = "ns2.#{PRIMARY_DOMAIN}" # ns2.grindavik.xyz
    dns_secondary.vm.network "private_network", ip: "192.168.56.11"
    dns_secondary.vm.provision "shell", inline: <<-SHELL
      echo "Provisioning DNS Secondary (ns2.#{PRIMARY_DOMAIN})..."
      /vagrant/scripts/bootstrap.sh #{IPV6_PREFIX}::11 ns2.#{PRIMARY_DOMAIN}
      /vagrant/scripts/dns-secondary-setup.sh
    SHELL
  end

  # 3. Servidor SMTP (Postfix + Dovecot)
  config.vm.define "smtp" do |smtp_server|
    smtp_server.vm.box = UBUNTU_BOX
    smtp_server.vm.hostname = "mail.#{PRIMARY_DOMAIN}" # mail.grindavik.xyz
    smtp_server.vm.network "private_network", ip: "192.168.56.12"
    smtp_server.vm.provision "shell", inline: <<-SHELL
      echo "Provisioning SMTP Server (mail.#{PRIMARY_DOMAIN})..."
      /vagrant/scripts/bootstrap.sh #{IPV6_PREFIX}::12 mail.#{PRIMARY_DOMAIN}
      /vagrant/scripts/smtp-setup.sh # Este script también necesitará conocer el PRIMARY_DOMAIN
    SHELL
  end

  # 4. Servidor DHCP (Kea)
  config.vm.define "dhcp" do |dhcp_server|
    dhcp_server.vm.box = UBUNTU_BOX
    dhcp_server.vm.hostname = "dhcp.#{PRIMARY_DOMAIN}" # dhcp.grindavik.xyz
    dhcp_server.vm.network "private_network", ip: "192.168.56.13"
    dhcp_server.vm.provision "shell", inline: <<-SHELL
      echo "Provisioning DHCP Server (dhcp.#{PRIMARY_DOMAIN})..."
      /vagrant/scripts/bootstrap.sh #{IPV6_PREFIX}::13 dhcp.#{PRIMARY_DOMAIN}
      /vagrant/scripts/dhcp-setup.sh # Este script también necesitará conocer el PRIMARY_DOMAIN
    SHELL
  end
end