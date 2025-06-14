#!/bin/bash
set -eux

# Dominio y Hostname FQDN para el servidor de correo
PRIMARY_DOMAIN="grindavik.xyz"
MAIL_SERVER_HOSTNAME="mail.${PRIMARY_DOMAIN}" # ej. mail.grindavik.xyz

# IPs del DNS Primario (para /etc/resolv.conf)
# Aunque bootstrap.sh ya lo hace, tenerlos aquí para el resolv.conf específico no está mal.
PRIMARY_DNS_IPV4="192.168.56.10" # ns1.grindavik.xyz
PRIMARY_DNS_IPV6="fd00:cafe:beef::10" # ns1.grindavik.xyz
SECONDARY_DNS_IPV4="192.168.56.11" # ns2.grindavik.xyz (para resolv.conf)

echo "--- Configuring SMTP Server (Postfix + Dovecot + OpenDKIM) for ${MAIL_SERVER_HOSTNAME} ---"

# Set debconf selections para evitar prompts interactivos
echo "postfix postfix/main_mailer_type select 'Internet Site'" | sudo debconf-set-selections
echo "postfix postfix/mailname string ${MAIL_SERVER_HOSTNAME}" | sudo debconf-set-selections # Usar el FQDN del servidor de correo
echo "dovecot-core dovecot-core/create-ssl-cert boolean false" | sudo debconf-set-selections
echo "dovecot-core dovecot-core/ssl-cert-name string ${MAIL_SERVER_HOSTNAME}" | sudo debconf-set-selections

sudo apt-get update -y
sudo apt-get install -y postfix postfix-pcre dovecot-core dovecot-imapd dovecot-pop3d opendkim opendkim-tools mailutils certbot

# === Configurar Postfix ===
sudo cp "/vagrant/configs/smtp/postfix/main.cf" /etc/postfix/main.cf
# Actualizar myhostname, mydomain, y myorigin en main.cf usando postconf
sudo postconf -e "myhostname = ${MAIL_SERVER_HOSTNAME}"
sudo postconf -e "mydomain = ${PRIMARY_DOMAIN}"
sudo postconf -e "myorigin = \$mydomain" # Postfix expandirá $mydomain
# Redes que pueden retransmitir correo. La red de Vagrant y las locales.
sudo postconf -e "mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 192.168.56.0/24 [fd00:cafe:beef::]/64"
# Destinos para los que este servidor es el destino final del correo
sudo postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"

# === Configurar Dovecot ===
sudo cp "/vagrant/configs/smtp/dovecot/dovecot.conf" /etc/dovecot/dovecot.conf
sudo cp /vagrant/configs/smtp/dovecot/conf.d/* /etc/dovecot/conf.d/ # Copia todos los archivos de conf.d

# Generar certificados SSL autofirmados para Dovecot/Postfix
# Estos se usarán para STARTTLS. El CN debe ser el hostname del servidor de correo.
SSL_DIR="/etc/dovecot/ssl"
sudo mkdir -p "$SSL_DIR"
sudo openssl req -new -x509 -days 3650 -nodes \
  -out "${SSL_DIR}/dovecot.pem" \
  -keyout "${SSL_DIR}/dovecot.key" \
  -subj "/C=CO/ST=Valle/L=Cali/O=${PRIMARY_DOMAIN}/CN=${MAIL_SERVER_HOSTNAME}"
sudo chmod 0600 "${SSL_DIR}/dovecot.key" # Asegurar permisos de la clave privada

# Actualizar rutas SSL en Dovecot (10-ssl.conf)
sudo sed -i "s|^ssl_cert = <.*|ssl_cert = <${SSL_DIR}/dovecot.pem|" /etc/dovecot/conf.d/10-ssl.conf
sudo sed -i "s|^ssl_key = <.*|ssl_key = <${SSL_DIR}/dovecot.key|" /etc/dovecot/conf.d/10-ssl.conf

# Actualizar rutas SSL en Postfix para STARTTLS (smtpd)
sudo postconf -e "smtpd_tls_cert_file=${SSL_DIR}/dovecot.pem"
sudo postconf -e "smtpd_tls_key_file=${SSL_DIR}/dovecot.key"
# Confiar en los CAs del sistema para validar certs en conexiones salientes (smtp)
sudo postconf -e "smtp_tls_CAfile=/etc/ssl/certs/ca-certificates.crt"
sudo postconf -e "smtp_tls_security_level=may" # Usar TLS si el servidor remoto lo ofrece
sudo postconf -e "smtpd_tls_security_level=may" # Anunciar STARTTLS a los clientes

# === Configurar OpenDKIM ===
sudo mkdir -p "/etc/opendkim/keys/${PRIMARY_DOMAIN}" # Directorio de claves para tu dominio
sudo cp "/vagrant/configs/smtp/opendkim/opendkim.conf" /etc/opendkim.conf

# Modificar /etc/default/opendkim para configurar el socket
# Usaremos un socket inet para que sea más fácil de configurar con Postfix
# SOCKET="inet:8891@localhost" (en el archivo /etc/default/opendkim)
# El archivo opendkim.conf debe reflejar esto o usar unix socket, asegurando consistencia.
# Para este script, forzamos inet:8891@localhost
SOCKET_CONFIG_LINE="SOCKET=inet:8891@localhost"
if sudo grep -q '^SOCKET=' /etc/default/opendkim; then
    sudo sed -i "s|^SOCKET=.*|${SOCKET_CONFIG_LINE}|" /etc/default/opendkim
else
    echo "${SOCKET_CONFIG_LINE}" | sudo tee -a /etc/default/opendkim
fi

# Actualizar opendkim.conf con el dominio, el archivo de clave y el selector.
# Asegúrate que opendkim.conf tiene estas líneas o las añades:
sudo sed -i "/^Domain\s\+.*/d" /etc/opendkim.conf # Eliminar antigua entrada de Domain
sudo sed -i "/^KeyFile\s\+.*/d" /etc/opendkim.conf # Eliminar antigua entrada de KeyFile
sudo sed -i "/^Selector\s\+.*/d" /etc/opendkim.conf # Eliminar antigua entrada de Selector
sudo sed -i "/^Socket\s\+.*/d" /etc/opendkim.conf # Eliminar antigua entrada de Socket si está ahí (preferimos /etc/default/opendkim)

echo "Domain             ${PRIMARY_DOMAIN}" | sudo tee -a /etc/opendkim.conf
echo "KeyFile            /etc/opendkim/keys/${PRIMARY_DOMAIN}/default.private" | sudo tee -a /etc/opendkim.conf
echo "Selector           default" | sudo tee -a /etc/opendkim.conf
#echo "Socket             inet:8891@localhost" | sudo tee -a /etc/opendkim.conf # Asegurar que también esté aquí


# Generar claves DKIM (selector 'default' para el dominio)
# La clave pública estará en /etc/opendkim/keys/${PRIMARY_DOMAIN}/default.txt
# Esta DEBE añadirse al DNS primario.
if [ ! -f "/etc/opendkim/keys/${PRIMARY_DOMAIN}/default.private" ]; then
    sudo opendkim-genkey -s default -d "${PRIMARY_DOMAIN}" -D "/etc/opendkim/keys/${PRIMARY_DOMAIN}/"
    sudo chown -R opendkim:opendkim "/etc/opendkim/keys/"
    sudo chmod 600 "/etc/opendkim/keys/${PRIMARY_DOMAIN}/default.private" # Permisos restrictivos para la clave privada
else
    echo "DKIM keys for ${PRIMARY_DOMAIN} seem to exist already. Skipping generation."
fi

# Añadir usuarios a grupos para la comunicación del socket (si se usa socket de Unix)
# Para sockets inet, esto no es tan crítico, pero no hace daño.
sudo adduser postfix opendkim || true # el '|| true' evita error si ya es miembro
sudo adduser opendkim postfix || true

# Actualizar Postfix para usar el milter OpenDKIM
sudo postconf -e "milter_protocol = 6"
sudo postconf -e "milter_default_action = accept" # Aceptar correo si el milter falla, cambiar a 'tempfail' o 'reject' en producción
sudo postconf -e "smtpd_milters = inet:localhost:8891" # Si usas socket inet
sudo postconf -e "non_smtpd_milters = inet:localhost:8891" # Para correos generados localmente

# === Crear usuarios de correo para pruebas ===
MAIL_USERS=("user1" "user2")
for mail_user in "${MAIL_USERS[@]}"; do
    if ! id -u "$mail_user" >/dev/null 2>&1; then
        sudo useradd -m -s /bin/bash "$mail_user" # -m crea home dir
        echo "${mail_user}:password" | sudo chpasswd # Cambia 'password' a una segura para pruebas
        echo "Created mail user: $mail_user with password: password"
    else
        echo "Mail user $mail_user already exists."
    fi
done

# Configurar /etc/resolv.conf para que esta VM use los DNS locales
echo "search ${PRIMARY_DOMAIN}" | sudo tee /etc/resolv.conf
echo "nameserver ${PRIMARY_DNS_IPV4}" | sudo tee -a /etc/resolv.conf  # ns1 IPv4
echo "nameserver ${PRIMARY_DNS_IPV6}" | sudo tee -a /etc/resolv.conf  # ns1 IPv6
echo "nameserver ${SECONDARY_DNS_IPV4}" | sudo tee -a /etc/resolv.conf # ns2 IPv4
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf # Fallback global

# Reglas de Firewall para Postfix (SMTP, Submission) y Dovecot (IMAP, POP3)
sudo ufw allow Postfix # Cubre puerto 25
sudo ufw allow 587/tcp comment 'SMTP Submission MSA' # Para clientes de correo
sudo ufw allow 'Dovecot IMAP' # Puerto 143
sudo ufw allow 'Dovecot POP3' # Puerto 110
sudo ufw allow 'Dovecot Secure IMAP' # Puerto 993 (IMAPS)
sudo ufw allow 'Dovecot Secure POP3' # Puerto 995 (POP3S)
sudo ufw reload

# --- Paso DKIM y Reinicio de Servicios ---
# Como se mencionó antes, la primera vez que aprovisionas, necesitas la clave pública DKIM.
# Luego, añades esa clave al DNS primario, incrementas serial, reprovisionas el primario.
# DESPUÉS de eso, puedes descomentar estas líneas de reinicio aquí,
# o reiniciar los servicios manualmente en la VM smtp, o reprovisionar la VM smtp.

# Para esta ejecución, dejaremos los servicios sin iniciar para que puedas obtener la clave.
# En ejecuciones posteriores, una vez que la clave DKIM esté en DNS, descomenta esto:
echo "Restarting mail services..."
sudo systemctl restart opendkim
sudo systemctl restart postfix
sudo systemctl restart dovecot
sudo systemctl enable opendkim postfix dovecot

echo "--- SMTP Server (${MAIL_SERVER_HOSTNAME}) Configuration Attempted ---"
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!!! ACCIÓN REQUERIDA PARA DKIM:                                          !!!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "La clave pública DKIM ha sido generada (o ya existía)."
echo "Necesitas obtenerla de este servidor SMTP (mail.${PRIMARY_DOMAIN}) y"
echo "añadirla como un registro TXT en tu servidor DNS primario (ns1.${PRIMARY_DOMAIN})."
echo ""
echo "1. Conéctate a esta VM SMTP: vagrant ssh smtp"
echo "2. Ejecuta: sudo cat /etc/opendkim/keys/${PRIMARY_DOMAIN}/default.txt"
echo "3. Copia la parte entre comillas del registro TXT (el valor p=...)."
echo "4. En tu máquina anfitriona, edita tu archivo de zona fuente:"
echo "   configs/dns-primary/db.${PRIMARY_DOMAIN}"
echo "   Y añade/actualiza el registro TXT para default._domainkey.${PRIMARY_DOMAIN}"
echo "   Ejemplo: default._domainkey IN TXT \"v=DKIM1; k=rsa; p=TU_CLAVE_PUBLICA_AQUI\""
echo "5. ¡MUY IMPORTANTE! Incrementa el número de serial en configs/dns-primary/db.${PRIMARY_DOMAIN}."
echo "6. Reprovisiona el DNS primario: vagrant provision dns-primary"
echo "7. Reprovisiona el DNS secundario: vagrant provision dns-secondary"
echo "8. DESPUÉS DE QUE EL DNS ESTÉ ACTUALIZADO, descomenta las líneas de reinicio/habilitación de"
echo "   servicios en este script (smtp-setup.sh) y reprovisiona esta VM SMTP:"
echo "   vagrant provision smtp"
echo "   O reinicia manualmente los servicios en la VM smtp:"
echo "   sudo systemctl restart opendkim postfix dovecot && sudo systemctl enable opendkim postfix dovecot"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ""