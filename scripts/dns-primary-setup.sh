#!/bin/bash
set -eux

echo "--- Configuring DNS Primary ---"
PRIMARY_DOMAIN="grindavik.xyz"
PRIMARY_DNS_IPV4="192.168.56.10"
PRIMARY_DNS_IPV6="fd00:cafe:beef::10"
# La variable TSIG_KEY_NAME ya no es necesaria en el script si la clave está solo en named.conf.local
TSIG_KEY_SECRET="vPhK2lMEVBEwGfdeI8too1rFH1LU7M2y11MnTXGo8oU=" # Se mantiene solo para el mensaje informativo final

sudo apt-get update -y
sudo apt-get install -y bind9 bind9utils bind9-doc acl # 'acl' para setfacl, aunque no lo usemos aún

# === Directorios y Permisos para BIND ===
# BIND usará /var/cache/bind/ como su directorio principal (definido en named.conf.options)
# Crear subdirectorios necesarios dentro de /var/cache/bind/
echo "Creating BIND working directories in /var/cache/bind/..."
sudo mkdir -p "/var/cache/bind/master_zones" # Donde copiaremos los archivos fuente para que BIND los lea
sudo mkdir -p "/var/cache/bind/keys/${PRIMARY_DOMAIN}"
sudo mkdir -p "/var/cache/bind/keys/56.168.192.in-addr.arpa"
sudo mkdir -p "/var/cache/bind/keys/f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa"
sudo mkdir -p "/var/cache/bind/dynamic"     # Para managed-keys (trust anchors)
sudo mkdir -p "/var/cache/bind/journals"    # Para los archivos .jnl

# Asegurar que 'bind' sea el propietario de todo bajo /var/cache/bind/
# La instalación de BIND generalmente crea /var/cache/bind con propietario bind:bind.
# Este chown reafirma la propiedad para nuestros subdirectorios.
sudo chown -R bind:bind "/var/cache/bind/"

# Dar permisos rwx al usuario 'bind' (propietario) y rx al grupo 'bind' para TODO /var/cache/bind/
# 'o-rwx' quita todos los permisos para "otros"
sudo chmod -R u=rwx,g=rx,o-rwx "/var/cache/bind/"
echo "Permissions set for /var/cache/bind/ and subdirectories."

# === Copia de Archivos de Configuración y Zona ===
# Archivos de config principales van a /etc/bind/ (BIND los lee de aquí para su config inicial)
echo "Copying BIND configuration files to /etc/bind/..."
sudo cp "/vagrant/configs/dns-primary/named.conf.options" /etc/bind/
sudo cp "/vagrant/configs/dns-primary/named.conf.local" /etc/bind/ # Este archivo ahora apunta a zonas en /var/cache/bind/master_zones

# Archivos de zona fuente (no firmados) se copian a /var/cache/bind/master_zones/
# BIND (usuario bind) debe poder leerlos desde aquí.
echo "Copying zone source files to /var/cache/bind/master_zones/..."
sudo cp "/vagrant/configs/dns-primary/db.${PRIMARY_DOMAIN}" "/var/cache/bind/master_zones/db.${PRIMARY_DOMAIN}"
sudo cp "/vagrant/configs/dns-primary/db.168.192.in-addr.arpa" "/var/cache/bind/master_zones/db.168.192.in-addr.arpa"
sudo cp "/vagrant/configs/dns-primary/db.f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa" "/var/cache/bind/master_zones/db.f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa"

# Asegurar que los archivos de zona en master_zones sean legibles por BIND.
# El chown/chmod anterior de /var/cache/bind/ debería ser suficiente,
# pero es bueno ser explícito si 'root' los copia. Haremos que bind:bind sea el dueño.
sudo chown bind:bind /var/cache/bind/master_zones/db.*
sudo chmod 644 /var/cache/bind/master_zones/db.* # rw-r--r--. El usuario bind podrá leerlos.

# Update resolv.conf
echo "Configuring /etc/resolv.conf..."
echo "search ${PRIMARY_DOMAIN}" | sudo tee /etc/resolv.conf
echo "nameserver 127.0.0.1" | sudo tee -a /etc/resolv.conf
echo "nameserver ${PRIMARY_DNS_IPV6}" | sudo tee -a /etc/resolv.conf
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf

# Check configuration
echo "Running named-checkconf..."
sudo named-checkconf # El script fallará aquí si hay un error (gracias a set -e)
echo "named-checkconf passed. Checking zones..."
# IMPORTANTE: named-checkzone debe referenciar las rutas absolutas TAL COMO BIND las verá
# ya que la opción 'directory' en named.conf.options es /var/cache/bind.
sudo named-checkzone "${PRIMARY_DOMAIN}" "/var/cache/bind/master_zones/db.${PRIMARY_DOMAIN}"
sudo named-checkzone "56.168.192.in-addr.arpa" "/var/cache/bind/master_zones/db.168.192.in-addr.arpa"
sudo named-checkzone "f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa." "/var/cache/bind/master_zones/db.f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa"
echo "Zone checks passed."

# Firewall
echo "Configuring UFW firewall..."
sudo ufw allow 53/tcp comment 'DNS TCP'
sudo ufw allow 53/udp comment 'DNS UDP'
sudo ufw reload

# Reiniciar y Habilitar BIND
echo "Restarting and enabling BIND (named.service)..."
sudo systemctl restart named.service
sudo systemctl enable named.service
sudo systemctl status named.service # Muestra el estado, no detiene el script si falla.

echo "--- DNS Primary Configured for ${PRIMARY_DOMAIN} ---"
echo "IMPORTANT: The TSIG key named 'transfer-key' with secret '${TSIG_KEY_SECRET}' must be used on the secondary DNS." # TSIG_KEY_NAME se quitó.
echo "--- DNSSEC Key Information ---"
echo "BIND will auto-generate DNSSEC keys and signed zone files."
echo "Keys for ${PRIMARY_DOMAIN} will be in /var/cache/bind/keys/${PRIMARY_DOMAIN}/"
echo "Journal files for inline-signing will be in /var/cache/bind/journals/"
echo "Signed zone files (if not purely in-memory/journaled) might appear in /var/cache/bind/ (or subdirs)."
echo "To get the DS record for GoDaddy (use the KSK with flags: 257):"
KSK_DIR="/var/cache/bind/keys/${PRIMARY_DOMAIN}"
if [ -d "${KSK_DIR}" ]; then
    echo "  1. Wait ~1 minute, then list keys: sudo ls -l ${KSK_DIR}"
    echo "  2. Identify KSK (e.g., K${PRIMARY_DOMAIN}.+ALG+TAG.key, check for flags: 257 inside)"
    echo "  3. Generate DS: sudo dnssec-dsfromkey -f ${KSK_DIR}/<KSK_FILENAME.key> -a SHA-256"
    echo "Attempting to find KSKs and suggest DS generation commands (may take a moment for keys to appear)..."
    sleep 25 # Espera un poco más para la generación de claves
    FOUND_KSK=0
    # Bucle mejorado para manejar espacios en nombres de archivo y evitar errores si find no devuelve nada
    if sudo find "${KSK_DIR}" -maxdepth 1 -type f -name "K${PRIMARY_DOMAIN}*.key" -print0 | xargs -0 -I {} sudo grep -q "flags: 257" {}; then
        sudo find "${KSK_DIR}" -maxdepth 1 -type f -name "K${PRIMARY_DOMAIN}*.key" -print0 | while IFS= read -r -d $'\0' keyfile_path; do
            if sudo grep -q "flags: 257" "$keyfile_path"; then
                FOUND_KSK=1
                key_alg_num=$(basename "$keyfile_path" | cut -d+ -f2)
                key_filename=$(basename "$keyfile_path")
                DIGEST_ALG="SHA-256"
                if [[ "$key_alg_num" == "014" ]]; then DIGEST_ALG="SHA-384"; fi
                echo "  Possible DS for key ${key_filename} (Algorithm Num ${key_alg_num}):"
                echo "    sudo dnssec-dsfromkey -f \"${KSK_DIR}/\" -a ${DIGEST_ALG} \"${key_filename}\""
            fi
        done
    fi
    if [ "$FOUND_KSK" -eq 0 ]; then
        echo "No KSK files found yet (or grep failed). Check ${KSK_DIR} manually after BIND has run for a few minutes."
    fi
else
    echo "Warning: Key directory ${KSK_DIR} not found or not accessible immediately after BIND start. Check BIND logs."
fi