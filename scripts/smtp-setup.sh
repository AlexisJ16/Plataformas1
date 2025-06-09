#!/bin/bash
set -eux

echo "--- Configuring SMTP Server (Postfix + Dovecot + OpenDKIM) ---"
DOMAIN="example.com"
HOSTNAME_FQDN="mail.example.com"
PRIMARY_DNS_IPV4="192.168.56.10"
PRIMARY_DNS_IPV6="fd00:cafe:beef::10"

# Set debconf selections to avoid interactive prompts
echo "postfix postfix/main_mailer_type select 'Internet Site'" | sudo debconf-set-selections
echo "postfix postfix/mailname string ${HOSTNAME_FQDN}" | sudo debconf-set-selections
echo "dovecot-core dovecot-core/create-ssl-cert boolean false" | sudo debconf-set-selections # We'll gen our own or use existing
echo "dovecot-core dovecot-core/ssl-cert-name string ${HOSTNAME_FQDN}" | sudo debconf-set-selections

sudo apt-get update -y
sudo apt-get install -y postfix postfix-pcre dovecot-core dovecot-imapd dovecot-pop3d opendkim opendkim-tools mailutils certbot

# === Configure Postfix ===
sudo cp /vagrant/configs/smtp/postfix/main.cf /etc/postfix/main.cf
# Update myhostname, mydomain in main.cf (or pass via script)
sudo sed -i "s/myhostname = .*/myhostname = ${HOSTNAME_FQDN}/" /etc/postfix/main.cf
sudo sed -i "s/mydomain = .*/mydomain = ${DOMAIN}/" /etc/postfix/main.cf
sudo postconf -e "mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 192.168.56.0/24 [fd00:cafe:beef::]/64"

# === Configure Dovecot ===
# Copy base configs. The specifics are in conf.d
sudo cp /vagrant/configs/smtp/dovecot/dovecot.conf /etc/dovecot/dovecot.conf
sudo cp /vagrant/configs/smtp/dovecot/conf.d/* /etc/dovecot/conf.d/

# Generate self-signed SSL certs for Dovecot/Postfix (for testing)
# For production, use Let's Encrypt (certbot)
SSL_DIR="/etc/dovecot/ssl"
sudo mkdir -p "$SSL_DIR"
sudo openssl req -new -x509 -days 3650 -nodes -out "${SSL_DIR}/dovecot.pem" -keyout "${SSL_DIR}/dovecot.key" \
  -subj "/C=CO/ST=Valle/L=Cali/O=${DOMAIN}/CN=${HOSTNAME_FQDN}"
sudo chmod 0600 "${SSL_DIR}/dovecot.key"

# Update Dovecot SSL paths
sudo sed -i "s|ssl_cert = <.*|ssl_cert = <${SSL_DIR}/dovecot.pem|" /etc/dovecot/conf.d/10-ssl.conf
sudo sed -i "s|ssl_key = <.*|ssl_key = <${SSL_DIR}/dovecot.key|" /etc/dovecot/conf.d/10-ssl.conf

# Postfix TLS settings
sudo postconf -e "smtpd_tls_cert_file=${SSL_DIR}/dovecot.pem"
sudo postconf -e "smtpd_tls_key_file=${SSL_DIR}/dovecot.key"
sudo postconf -e "smtp_tls_CAfile=/etc/ssl/certs/ca-certificates.crt" # For outbound TLS
sudo postconf -e "smtp_tls_security_level=may" # Use TLS if available for outbound
sudo postconf -e "smtpd_tls_security_level=may" # Announce STARTTLS to clients


# === Configure OpenDKIM ===
sudo mkdir -p /etc/opendkim/keys/${DOMAIN}
sudo cp /vagrant/configs/smtp/opendkim/opendkim.conf /etc/opendkim.conf

# Generate DKIM keys
# The public key will be in /etc/opendkim/keys/example.com/default.txt
# This needs to be added to the DNS primary server's zone file.
sudo opendkim-genkey -s default -d ${DOMAIN} -D /etc/opendkim/keys/${DOMAIN}/
sudo chown -R opendkim:opendkim /etc/opendkim/keys/
sudo chmod 600 /etc/opendkim/keys/${DOMAIN}/default.private

# Add opendkim to postfix group and vice-versa to access socket
sudo adduser postfix opendkim
sudo adduser opendkim postfix

# Update opendkim.conf with domain and paths
echo "Domain           ${DOMAIN}" | sudo tee -a /etc/opendkim.conf
echo "KeyFile          /etc/opendkim/keys/${DOMAIN}/default.private" | sudo tee -a /etc/opendkim.conf
echo "Selector         default" | sudo tee -a /etc/opendkim.conf
echo "SOCKET           inet:8891@localhost" | sudo tee -a /etc/default/opendkim # Or /var/run/opendkim/opendkim.sock

# Update Postfix to use OpenDKIM milter
sudo postconf -e "milter_protocol = 6"
sudo postconf -e "milter_default_action = accept"
sudo postconf -e "smtpd_milters = inet:localhost:8891" # Or unix:/var/run/opendkim/opendkim.sock
sudo postconf -e "non_smtpd_milters = inet:localhost:8891"

# === Create mail users ===
# Users for testing. Thunderbird will use these.
MAIL_USERS=("user1" "user2")
for mail_user in "${MAIL_USERS[@]}"; do
    if ! id -u "$mail_user" >/dev/null 2>&1; then
        sudo useradd -m -s /bin/bash "$mail_user"
        echo "${mail_user}:password" | sudo chpasswd # Change 'password' to something secure
        echo "Created mail user: $mail_user with password: password"
        # Create Maildir structure automatically on first login via Dovecot
    else
        echo "User $mail_user already exists."
    fi
done

# Update resolv.conf to use local DNS servers
echo "nameserver ${PRIMARY_DNS_IPV4}" | sudo tee /etc/resolv.conf
echo "nameserver ${PRIMARY_DNS_IPV6}" | sudo tee -a /etc/resolv.conf
echo "nameserver 192.168.56.11" | sudo tee -a /etc/resolv.conf # Secondary DNS
echo "search ${DOMAIN}" | sudo tee -a /etc/resolv.conf

# Firewall rules
sudo ufw allow Postfix # Covers 25/tcp
sudo ufw allow 'Dovecot IMAP' # 143/tcp
sudo ufw allow 'Dovecot POP3' # 110/tcp
sudo ufw allow 'Dovecot Secure IMAP' # 993/tcp (if SSL enabled)
sudo ufw allow 'Dovecot Secure POP3' # 995/tcp (if SSL enabled)
sudo ufw allow Submission # 587/tcp for SMTP submission
sudo ufw reload

# ==============================================================================
# === DKIM PROCESS STEP: Services are NOT started automatically on first run ===
# We must first get the public key, add it to DNS, and then start them manually
# or re-provision this machine.
# ==============================================================================
# sudo systemctl restart postfix
# sudo systemctl restart dovecot
# sudo systemctl restart opendkim
# sudo systemctl enable postfix dovecot opendkim

echo "--- SMTP Server Configured ---"
echo "IMPORTANT: The OpenDKIM public key is in /etc/opendkim/keys/${DOMAIN}/default.txt on this VM."
echo "You MUST add this TXT record to your DNS primary server (dns-primary) for DKIM to work."
echo "Example for default._domainkey.${DOMAIN}:"
sudo cat "/etc/opendkim/keys/${DOMAIN}/default.txt"