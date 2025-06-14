#!/bin/bash
set -eux

# Dominio y Hostname FQDN para el servidor de correo
PRIMARY_DOMAIN="grindavik.xyz"
MAIL_SERVER_HOSTNAME="mail.${PRIMARY_DOMAIN}"

# IPs de los servidores DNS para configurar /etc/resolv.conf
PRIMARY_DNS_IPV4="192.168.56.10"
PRIMARY_DNS_IPV6="fd00:cafe:beef::10"
SECONDARY_DNS_IPV4="192.168.56.11"

echo "--- Configuring SMTP Server (Postfix + Dovecot + OpenDKIM) for ${MAIL_SERVER_HOSTNAME} ---"

# Pre-configuración de Debconf para evitar instalaciones interactivas
echo "postfix postfix/main_mailer_type select 'Internet Site'" | sudo debconf-set-selections
echo "postfix postfix/mailname string ${MAIL_SERVER_HOSTNAME}" | sudo debconf-set-selections
echo "dovecot-core dovecot-core/create-ssl-cert boolean false" | sudo debconf-set-selections
echo "dovecot-core dovecot-core/ssl-cert-name string ${MAIL_SERVER_HOSTNAME}" | sudo debconf-set-selections

# Instalación de paquetes
sudo apt-get update -y
sudo apt-get install -y postfix postfix-pcre dovecot-core dovecot-imapd dovecot-pop3d opendkim opendkim-tools mailutils

# === Configurar Postfix ===
sudo cp "/vagrant/configs/smtp/postfix/main.cf" /etc/postfix/main.cf
sudo postconf -e "myhostname = ${MAIL_SERVER_HOSTNAME}"
sudo postconf -e "mydomain = ${PRIMARY_DOMAIN}"
sudo postconf -e "myorigin = \$mydomain"
sudo postconf -e "mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 192.168.56.0/24 [fd00:cafe:beef::]/64"
sudo postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"

# === Configurar Dovecot ===
sudo cp "/vagrant/configs/smtp/dovecot/dovecot.conf" /etc/dovecot/dovecot.conf
sudo cp /vagrant/configs/smtp/dovecot/conf.d/* /etc/dovecot/conf.d/

# Generar certificados SSL autofirmados
SSL_DIR="/etc/dovecot/ssl"
sudo mkdir -p "$SSL_DIR"
sudo openssl req -new -x509 -days 3650 -nodes \
  -out "${SSL_DIR}/dovecot.pem" \
  -keyout "${SSL_DIR}/dovecot.key" \
  -subj "/C=CO/ST=Valle/L=Cali/O=${PRIMARY_DOMAIN}/CN=${MAIL_SERVER_HOSTNAME}"
sudo chmod 0600 "${SSL_DIR}/dovecot.key"

# Actualizar rutas de certificados en Dovecot y Postfix
sudo sed -i "s|^ssl_cert = <.*|ssl_cert = <${SSL_DIR}/dovecot.pem|" /etc/dovecot/conf.d/10-ssl.conf
sudo sed -i "s|^ssl_key = <.*|ssl_key = <${SSL_DIR}/dovecot.key|" /etc/dovecot/conf.d/10-ssl.conf
sudo postconf -e "smtpd_tls_cert_file=${SSL_DIR}/dovecot.pem"
sudo postconf -e "smtpd_tls_key_file=${SSL_DIR}/dovecot.key"
sudo postconf -e "smtp_tls_CAfile=/etc/ssl/certs/ca-certificates.crt"
sudo postconf -e "smtp_tls_security_level=may"
sudo postconf -e "smtpd_tls_security_level=may"

# === Configurar OpenDKIM (Método Corregido y Final) ===
sudo mkdir -p "/etc/opendkim/keys/${PRIMARY_DOMAIN}"

# 1. Copia el archivo de configuración base al lugar CORRECTO
sudo cp "/vagrant/configs/smtp/opendkim/opendkim.conf" /etc/opendkim.conf

# 2. Limpia las directivas dinámicas antiguas para evitar duplicados
sudo sed -i "/^Domain\s\+.*/d" /etc/opendkim.conf
sudo sed -i "/^KeyFile\s\+.*/d" /etc/opendkim.conf
sudo sed -i "/^Selector\s\+.*/d" /etc/opendkim.conf

# 3. Añade las directivas dinámicas limpiamente
echo "Domain                  ${PRIMARY_DOMAIN}" | sudo tee -a /etc/opendkim.conf
echo "KeyFile                 /etc/opendkim/keys/${PRIMARY_DOMAIN}/default.private" | sudo tee -a /etc/opendkim.conf
echo "Selector                default" | sudo tee -a /etc/opendkim.conf

# 4. Genera las claves DKIM solo si no existen
if [ ! -f "/etc/opendkim/keys/${PRIMARY_DOMAIN}/default.private" ]; then
    echo "Generating DKIM keys for ${PRIMARY_DOMAIN}..."
    sudo opendkim-genkey -s default -d "${PRIMARY_DOMAIN}" -D "/etc/opendkim/keys/${PRIMARY_DOMAIN}/"
    sudo chown -R opendkim:opendkim "/etc/opendkim/keys/"
    sudo chmod 600 "/etc/opendkim/keys/${PRIMARY_DOMAIN}/default.private"
else
    echo "DKIM keys for ${PRIMARY_DOMAIN} already exist. Skipping generation."
fi

# 5. Asegurar permisos y configurar Postfix para usar el Milter
sudo adduser postfix opendkim || true
sudo adduser opendkim postfix || true
sudo postconf -e "milter_protocol = 6"
sudo postconf -e "milter_default_action = accept"
sudo postconf -e "smtpd_milters = inet:8891@localhost"
sudo postconf -e "non_smtpd_milters = inet:8891@localhost"

# === Crear usuarios de correo ===
MAIL_USERS=("user1" "user2")
for mail_user in "${MAIL_USERS[@]}"; do
    if ! id -u "$mail_user" >/dev/null 2>&1; then
        sudo useradd -m -s /bin/bash "$mail_user"
        echo "${mail_user}:password" | sudo chpasswd
        echo "Created mail user: $mail_user with password: password"
    else
        echo "Mail user $mail_user already exists."
    fi
done

# === Configurar /etc/resolv.conf ===
echo "search ${PRIMARY_DOMAIN}" | sudo tee /etc/resolv.conf
echo "nameserver ${PRIMARY_DNS_IPV4}" | sudo tee -a /etc/resolv.conf
echo "nameserver ${PRIMARY_DNS_IPV6}" | sudo tee -a /etc/resolv.conf
echo "nameserver ${SECONDARY_DNS_IPV4}" | sudo tee -a /etc/resolv.conf
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf

# === Configurar Firewall ===
sudo ufw allow Postfix
sudo ufw allow 587/tcp comment 'SMTP Submission MSA'
sudo ufw allow 'Dovecot IMAP'
sudo ufw allow 'Dovecot POP3'
sudo ufw allow 'Dovecot Secure IMAP'
sudo ufw allow 'Dovecot Secure POP3'
sudo ufw reload

# === Reinicio y Habilitación de Servicios ===
echo "Restarting mail services..."
sudo systemctl restart opendkim
sudo systemctl restart postfix
sudo systemctl restart dovecot

echo "Enabling mail services for startup..."
sudo systemctl enable opendkim postfix dovecot

echo "--- SMTP Server (${MAIL_SERVER_HOSTNAME}) provision finished ---"
echo "Check status with: sudo systemctl status opendkim postfix dovecot"