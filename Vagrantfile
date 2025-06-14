# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"
UBUNTU_BOX = "ubuntu/focal64"
DESKTOP_BOX = "bento/ubuntu-20.04-desktop" # Caja con entorno gráfico para los clientes
PRIMARY_DOMAIN = "grindavik.xyz"

# Prefijo IPv6
IPV6_PREFIX = "fd00:cafe:beef"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|

  # --- Deshabilitar vagrant-vbguest para evitar problemas con las Guest Additions ---
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end

  # --- Configuración general del proveedor VirtualBox ---
  config.vm.provider "virtualbox" do |vb|
    vb.memory = "1024"
    vb.cpus = "1"
  end

  # --- Opciones de montaje para carpetas compartidas ---
  config.vm.synced_folder ".", "/vagrant",
    owner: "vagrant",
    group: "vagrant",
    mount_options: ["dmode=755", "fmode=644"] # fmode 644 es más seguro para archivos

  # =======================================================
  #                  DEFINICIÓN DE SERVIDORES
  # =======================================================

  # 1. Servidor DNS Primario
  config.vm.define "dns-primary" do |dns_primary|
    dns_primary.vm.box = UBUNTU_BOX
    dns_primary.vm.hostname = "ns1.#{PRIMARY_DOMAIN}"
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
    dns_secondary.vm.hostname = "ns2.#{PRIMARY_DOMAIN}"
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
    smtp_server.vm.hostname = "mail.#{PRIMARY_DOMAIN}"
    smtp_server.vm.network "private_network", ip: "192.168.56.12"
    smtp_server.vm.provision "shell", inline: <<-SHELL
      echo "Provisioning SMTP Server (mail.#{PRIMARY_DOMAIN})..."
      /vagrant/scripts/bootstrap.sh #{IPV6_PREFIX}::12 mail.#{PRIMARY_DOMAIN}
      /vagrant/scripts/smtp-setup.sh
    SHELL
  end

  # 4. Servidor DHCP (Kea)
  config.vm.define "dhcp" do |dhcp_server|
    dhcp_server.vm.box = UBUNTU_BOX
    dhcp_server.vm.hostname = "dhcp.#{PRIMARY_DOMAIN}"
    dhcp_server.vm.network "private_network", ip: "192.168.56.13"
    dhcp_server.vm.provision "shell", inline: <<-SHELL
      echo "Provisioning DHCP Server (dhcp.#{PRIMARY_DOMAIN})..."
      /vagrant/scripts/bootstrap.sh #{IPV6_PREFIX}::13 dhcp.#{PRIMARY_DOMAIN}
      /vagrant/scripts/dhcp-setup.sh
    SHELL
  end

  # =========================================================
  #                  DEFINICIÓN DE CLIENTES
  # =========================================================

  # 5. Cliente 1
  config.vm.define "client1" do |client|
    client.vm.box = DESKTOP_BOX # Usa la caja con entorno de escritorio
    client.vm.hostname = "client1.#{PRIMARY_DOMAIN}"
    
    # Configura la red para usar DHCP y obtener una IP de nuestro servidor Kea
    client.vm.network "private_network", type: "dhcp"

    # Habilita la GUI y asigna más recursos para el entorno de escritorio
    client.vm.provider "virtualbox" do |vb|
      vb.gui = true
      vb.memory = "2048"
      vb.cpus = "2"
    end
    
    # Aprovisiona con el script para clientes (instala Thunderbird, etc.)
    client.vm.provision "shell", path: "scripts/client-setup.sh"
  end

  # 6. Cliente 2
  config.vm.define "client2" do |client|
    client.vm.box = DESKTOP_BOX
    client.vm.hostname = "client2.#{PRIMARY_DOMAIN}"
    client.vm.network "private_network", type: "dhcp"

    client.vm.provider "virtualbox" do |vb|
      vb.gui = true
      vb.memory = "2048"
      vb.cpus = "2"
    end

    client.vm.provision "shell", path: "scripts/client-setup.sh"
  end

end