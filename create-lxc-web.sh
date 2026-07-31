#!/usr/bin/env bash
#
# create-lxc-web.sh
#
# Crea (o completa) un contenedor LXC en Proxmox VE, listo para alojar una web:
#   - Debian 12
#   - Nginx (servidor web), con dominio y HTTPS (Certbot) opcionales
#   - PHP-FPM (opcional)
#   - Filebrowser (para subir archivos por navegador al webroot)
#   - Firewall básico (ufw) con los puertos necesarios abiertos
#
# MODO DE USO:
#   bash create-lxc-web.sh
#
#   El script te va preguntando la configuración (CTID, hostname, recursos,
#   credenciales, etc). Pulsa Enter en cualquier pregunta para mantener el
#   valor por defecto que se muestra entre corchetes.
#
#   - Si el CTID que indicas NO existe: se pregunta el resto de la
#     configuración y se crea el contenedor desde cero.
#   - Si el CTID que indicas YA existe: el script detecta qué tiene
#     instalado (Nginx / PHP / Filebrowser) y solo pregunta por lo que
#     falta, para completarlo sin crear un LXC nuevo.
#
#   También puedes evitar las preguntas y usar solo valores por defecto /
#   variables de entorno (por ejemplo para automatizar) exportando
#   NONINTERACTIVE=1, o lanzando el script sin una terminal (p.ej. por cron).
#
#   Atajo heredado (ya no es necesario, pero se mantiene por compatibilidad):
#     bash create-lxc-web.sh --add-php <CTID>
#
# Ejecuta siempre como root en el shell del nodo Proxmox (no dentro de un CT).
# Requisitos: Proxmox VE con acceso a internet y al menos un storage que
# soporte plantillas de contenedor (vztmpl) y discos (rootfs).

set -euo pipefail

# ============================================================
# VALORES POR DEFECTO (se pueden cambiar respondiendo a las preguntas,
# o exportándolos como variables de entorno antes de ejecutar el script)
# ============================================================

CTID="${CTID:-200}"
CT_HOSTNAME="${CT_HOSTNAME:-web01}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
DISK_SIZE="${DISK_SIZE:-8}"
MEMORY="${MEMORY:-1024}"
SWAP="${SWAP:-512}"
CORES="${CORES:-2}"
BRIDGE="${BRIDGE:-vmbr0}"
NET_CONFIG="${NET_CONFIG:-ip=dhcp}"
CT_PASSWORD="${CT_PASSWORD:-CambiaEstaClave123!}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"

WEBROOT="/var/www/html"
FILEBROWSER_PORT="${FILEBROWSER_PORT:-8080}"
FILEBROWSER_USER="${FILEBROWSER_USER:-admin}"
FILEBROWSER_PASSWORD="${FILEBROWSER_PASSWORD:-CambiaEstaClave123!}"
# Filebrowser exige 12 caracteres por defecto; se puede bajar (p.ej. a 8)
# si prefieres contraseñas más cortas para tu uso en LAN.
FILEBROWSER_MIN_PASSWORD_LENGTH="${FILEBROWSER_MIN_PASSWORD_LENGTH:-8}"
# El PATH que usa "pct exec" dentro del contenedor no siempre incluye
# /usr/local/bin (donde el instalador de Filebrowser deja el binario), así
# que lo invocamos siempre por ruta absoluta en lugar de confiar en el PATH.
FILEBROWSER_BIN="/usr/local/bin/filebrowser"

TEMPLATE_PATTERN="debian-12-standard"
INSTALL_PHP="${INSTALL_PHP:-0}"     # 1 = sí, 0 = no (se puede preguntar/añadir después)

DOMAIN="${DOMAIN:-}"                 # vacío = Nginx responde a cualquier host (server_name _)
ENABLE_SSL="${ENABLE_SSL:-0}"        # 1 = pedir certificado HTTPS con Certbot para DOMAIN
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"   # email para el registro en Let's Encrypt (opcional)

# ============================================================
# UTILIDADES
# ============================================================

log()  { echo -e "\e[32m[+]\e[0m $*"; }
warn() { echo -e "\e[33m[!]\e[0m $*"; }
err()  { echo -e "\e[31m[x]\e[0m $*" >&2; }

# gen_password [longitud]  ->  cadena alfanumérica aleatoria (sin pipes:
# con "set -o pipefail" activo, un patrón tipo "tr ... < /dev/urandom |
# head -c N" puede matar el script por SIGPIPE en cuanto head corta el flujo)
gen_password() {
  local length="${1:-16}"
  local chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  local pass="" i
  for ((i = 0; i < length; i++)); do
    pass+="${chars:RANDOM % ${#chars}:1}"
  done
  printf '%s' "$pass"
}

usage() {
  cat <<USAGE
Uso:
  $0                     Modo interactivo: pregunta configuración y detecta
                          si el CTID ya existe para crear o completar el LXC.
  $0 --add-php <CTID>    Atajo heredado, ya no hace falta: equivale a indicar
                          ese CTID en el modo interactivo.
  $0 -h | --help         Muestra esta ayuda

Variables de entorno: puedes predefinir cualquier valor (CTID, CT_HOSTNAME,
STORAGE, DISK_SIZE, MEMORY, SWAP, CORES, BRIDGE, NET_CONFIG, CT_PASSWORD,
UNPRIVILEGED, FILEBROWSER_PORT, FILEBROWSER_USER, FILEBROWSER_PASSWORD,
FILEBROWSER_MIN_PASSWORD_LENGTH, INSTALL_PHP, DOMAIN, ENABLE_SSL,
CERTBOT_EMAIL) para que se usen como valor
por defecto en las preguntas, o exporta NONINTERACTIVE=1 para saltarte
todas las preguntas.
USAGE
}

# ¿Preguntamos o no? Si no hay terminal (p.ej. cron, pipe) o si se pide
# explícitamente, no se pregunta nada y se usan los valores por defecto.
INTERACTIVE=1
if [[ ! -t 0 ]] || [[ "${NONINTERACTIVE:-0}" -eq 1 ]]; then
  INTERACTIVE=0
fi

# ask "Pregunta" NOMBRE_VARIABLE
# Muestra el valor actual como default; si el usuario no escribe nada,
# se mantiene tal cual.
ask() {
  local prompt="$1" varname="$2" current input
  current="${!varname}"
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    read -rp "$prompt [$current]: " input || true
    if [[ -n "${input:-}" ]]; then
      printf -v "$varname" '%s' "$input"
    fi
  fi
}

# ask_secret "Pregunta" NOMBRE_VARIABLE   (no muestra lo que se escribe)
ask_secret() {
  local prompt="$1" varname="$2" input
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    read -rsp "$prompt [Enter para mantener el valor actual]: " input || true
    echo
    if [[ -n "${input:-}" ]]; then
      printf -v "$varname" '%s' "$input"
    fi
  fi
}

# ask_yes_no "Pregunta" "s"|"n"  -> exit code 0 = sí, 1 = no
ask_yes_no() {
  local prompt="$1" default="$2" answer hint
  if [[ "$default" == "s" ]]; then hint="S/n"; else hint="s/N"; fi
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    read -rp "$prompt [$hint]: " answer || true
    answer="${answer:-$default}"
  else
    answer="$default"
  fi
  [[ "$answer" =~ ^[sSyY] ]]
}

# ============================================================
# ARGUMENTOS
# ============================================================

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--add-php" ]]; then
  if [[ -z "${2:-}" ]]; then
    err "Falta el CTID. Uso: $0 --add-php <CTID>"
    exit 1
  fi
  CTID="$2"
fi

if [[ $EUID -ne 0 ]]; then
  err "Este script debe ejecutarse como root en el host Proxmox."
  exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
  err "No se encontró el comando 'pct'. ¿Estás en un nodo Proxmox VE?"
  exit 1
fi

NGINX_PRESENT=1   # por defecto (modo creación siempre instala Nginx)
PHP_ENABLED=0
PHP_SOCK=""
SSL_ENABLED=0

# ============================================================
# FUNCIONES DE APROVISIONAMIENTO (se usan tanto al crear un LXC
# nuevo como al completar uno ya existente)
# ============================================================

detect_installed() {
  HAS_NGINX=0; HAS_PHP=0; HAS_FILEBROWSER=0
  pct exec "$CTID" -- bash -c "command -v nginx" >/dev/null 2>&1 && HAS_NGINX=1
  pct exec "$CTID" -- bash -c "command -v php" >/dev/null 2>&1 && HAS_PHP=1
  pct exec "$CTID" -- test -x "$FILEBROWSER_BIN" >/dev/null 2>&1 && HAS_FILEBROWSER=1
  return 0   # el resultado de las comprobaciones no debe hacer fallar al script (set -e)
}

ensure_ufw() {
  if ! pct exec "$CTID" -- bash -c "command -v ufw" >/dev/null 2>&1; then
    pct exec "$CTID" -- bash -c "
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y ufw
    "
  fi
}

setup_webroot() {
  pct exec "$CTID" -- mkdir -p "${WEBROOT}"
  if ! pct exec "$CTID" -- test -e "${WEBROOT}/index.html" 2>/dev/null \
     && ! pct exec "$CTID" -- test -e "${WEBROOT}/index.php" 2>/dev/null; then
    local index_file
    index_file=$(mktemp)
    cat > "$index_file" <<'HTML'
<!DOCTYPE html>
<html lang="es">
<head><meta charset="utf-8"><title>Sitio en construcción</title></head>
<body style="font-family: sans-serif; text-align:center; margin-top:10%;">
  <h1>¡El contenedor está listo!</h1>
  <p>Sube tus archivos con Filebrowser para reemplazar esta página.</p>
</body>
</html>
HTML
    pct push "$CTID" "$index_file" "${WEBROOT}/index.html"
    rm -f "$index_file"
  fi
  pct exec "$CTID" -- chown -R www-data:www-data "${WEBROOT}"
}

install_nginx() {
  log "Instalando Nginx..."
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y nginx curl wget ca-certificates sudo
  "
  setup_webroot
  NGINX_PRESENT=1
  configure_nginx
}

# Reescribe el vhost por defecto de Nginx según PHP_ENABLED/PHP_SOCK actuales
configure_nginx() {
  log "Configurando Nginx en el contenedor $CTID (PHP: $([[ "$PHP_ENABLED" -eq 1 ]] && echo activado || echo desactivado))..."

  local conf_file
  conf_file=$(mktemp)
  {
    echo "server {"
    echo "    listen 80 default_server;"
    echo "    listen [::]:80 default_server;"
    echo "    root ${WEBROOT};"
    echo "    index index.php index.html index.htm;"
    echo "    server_name ${DOMAIN:-_};"
    echo
    echo "    location / {"
    echo "        try_files \$uri \$uri/ =404;"
    echo "    }"
    if [[ "$PHP_ENABLED" -eq 1 ]]; then
      echo
      echo "    location ~ \.php\$ {"
      echo "        include snippets/fastcgi-php.conf;"
      echo "        fastcgi_pass unix:${PHP_SOCK};"
      echo "    }"
    fi
    echo "}"
  } > "$conf_file"

  pct push "$CTID" "$conf_file" /etc/nginx/sites-available/default
  rm -f "$conf_file"
  pct exec "$CTID" -- bash -c "nginx -t && systemctl reload nginx"
}

# Si el contenedor ya tenía un certificado de Let's Encrypt, lo detecta y
# fija DOMAIN/ENABLE_SSL para que se conserve al volver a generar el vhost
# (por ejemplo, al añadir PHP más tarde con este mismo script).
detect_existing_ssl() {
  local found
  found=$(pct exec "$CTID" -- bash -c "ls /etc/letsencrypt/live 2>/dev/null | grep -v '^README$'" 2>/dev/null | head -n1 || true)
  if [[ -n "$found" ]]; then
    [[ -z "$DOMAIN" ]] && DOMAIN="$found"
    ENABLE_SSL=1
    log "Se detectó un certificado HTTPS existente para ${found}; se mantendrá tras los cambios."
  fi
}

# Instala Certbot y solicita/renueva el certificado para $DOMAIN.
# Es seguro volver a llamarla (Certbot reutiliza el certificado si ya existe
# y solo reconfigura Nginx), así que también sirve para reaplicar HTTPS
# después de que este script regenere el vhost por otro motivo.
enable_ssl() {
  if [[ -z "$DOMAIN" ]]; then
    warn "No hay dominio configurado; no se puede activar HTTPS."
    return 0
  fi
  log "Instalando Certbot y configurando HTTPS para ${DOMAIN}..."
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y certbot python3-certbot-nginx
  "

  local cmd="certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --redirect"
  if [[ -n "$CERTBOT_EMAIL" ]]; then
    cmd="$cmd -m ${CERTBOT_EMAIL}"
  else
    cmd="$cmd --register-unsafely-without-email"
  fi

  if pct exec "$CTID" -- bash -c "$cmd"; then
    SSL_ENABLED=1
    log "HTTPS configurado: https://${DOMAIN}/"
  else
    SSL_ENABLED=0
    warn "No se pudo configurar HTTPS automáticamente para ${DOMAIN}."
    warn "Comprueba que el dominio ya resuelve a la IP pública de este contenedor y que el puerto 80 es accesible desde internet (revisa NAT/port-forwarding si estás detrás de un router)."
    warn "Puedes reintentarlo más tarde con: pct exec ${CTID} -- certbot --nginx -d ${DOMAIN}"
  fi
  return 0
}

install_php() {
  log "Instalando PHP-FPM y extensiones comunes en el contenedor $CTID..."
  pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y php-fpm php-cli php-mysql php-curl php-gd php-mbstring php-xml php-zip
  "

  local php_ver
  php_ver=$(pct exec "$CTID" -- php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
  log "PHP ${php_ver} instalado. Habilitando php${php_ver}-fpm..."
  pct exec "$CTID" -- bash -c "systemctl enable php${php_ver}-fpm && systemctl restart php${php_ver}-fpm"

  PHP_ENABLED=1
  PHP_SOCK="/run/php/php${php_ver}-fpm.sock"

  if [[ "$NGINX_PRESENT" -eq 1 ]]; then
    local info_file
    info_file=$(mktemp)
    echo '<?php phpinfo();' > "$info_file"
    pct push "$CTID" "$info_file" "${WEBROOT}/info.php"
    rm -f "$info_file"
    pct exec "$CTID" -- chown www-data:www-data "${WEBROOT}/info.php" 2>/dev/null || true
    configure_nginx
  else
    warn "No hay Nginx en este contenedor: PHP-FPM queda instalado pero sin ningún vhost configurado."
  fi
}

install_filebrowser() {
  log "Instalando Filebrowser..."
  # El propio instalador a veces dice "not in your path" aunque copie bien
  # el binario, porque su comprobación final usa el PATH del proceso y este
  # entorno no siempre incluye /usr/local/bin ahí. No dejamos que ese código
  # de salida tumbe el script (set -e); comprobamos nosotros con ruta absoluta.
  pct exec "$CTID" -- bash -c "curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash" || true

  if ! pct exec "$CTID" -- test -x "$FILEBROWSER_BIN"; then
    err "No se encontró ${FILEBROWSER_BIN} tras instalar Filebrowser. Revisa la conexión a internet del contenedor y si https://github.com/filebrowser/get sigue siendo la fuente correcta."
    exit 1
  fi

  local service_file
  service_file=$(mktemp)
  cat > "$service_file" <<'SERVICE'
[Unit]
Description=Filebrowser
After=network.target

[Service]
ExecStart=/usr/local/bin/filebrowser -d /etc/filebrowser/filebrowser.db
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
SERVICE

  # Si la contraseña configurada no llega al mínimo que vamos a exigir,
  # generamos una nueva en vez de dejar que "users add" falle a medias.
  if [[ ${#FILEBROWSER_PASSWORD} -lt $FILEBROWSER_MIN_PASSWORD_LENGTH ]]; then
    warn "La contraseña de Filebrowser tiene menos de ${FILEBROWSER_MIN_PASSWORD_LENGTH} caracteres (mínimo exigido). Generando una nueva automáticamente..."
    FILEBROWSER_PASSWORD="$(gen_password 16)"
  fi

  pct exec "$CTID" -- mkdir -p /etc/filebrowser
  pct exec "$CTID" -- "$FILEBROWSER_BIN" config init --database /etc/filebrowser/filebrowser.db --root "${WEBROOT}" --port "${FILEBROWSER_PORT}" --address 0.0.0.0 --minimumPasswordLength "${FILEBROWSER_MIN_PASSWORD_LENGTH}"
  pct exec "$CTID" -- "$FILEBROWSER_BIN" users add "${FILEBROWSER_USER}" "${FILEBROWSER_PASSWORD}" --database /etc/filebrowser/filebrowser.db --perm.admin
  pct push "$CTID" "$service_file" /etc/systemd/system/filebrowser.service
  rm -f "$service_file"
  pct exec "$CTID" -- bash -c "systemctl daemon-reload && systemctl enable filebrowser && systemctl restart filebrowser"
}

# configure_firewall <abrir_80_443:1|0> <abrir_puerto_filebrowser:1|0>
configure_firewall() {
  local open_web="$1" open_fb="$2"
  log "Configurando firewall (ufw)..."
  pct exec "$CTID" -- bash -c "ufw allow OpenSSH" >/dev/null 2>&1 || true
  if [[ "$open_web" -eq 1 ]]; then
    pct exec "$CTID" -- ufw allow 80/tcp
    pct exec "$CTID" -- ufw allow 443/tcp
  fi
  if [[ "$open_fb" -eq 1 ]]; then
    pct exec "$CTID" -- ufw allow "${FILEBROWSER_PORT}/tcp"
  fi
  pct exec "$CTID" -- bash -c "ufw --force enable"
}

print_summary() {
  local ct_ip site_url
  ct_ip=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

  if [[ -n "$DOMAIN" ]]; then
    if [[ "$SSL_ENABLED" -eq 1 ]]; then
      site_url="https://${DOMAIN}/"
    else
      site_url="http://${DOMAIN}/  (también por IP: http://${ct_ip}/)"
    fi
  else
    site_url="http://${ct_ip}/"
  fi

  echo
  log "¡Listo! Contenedor CTID=$CTID."
  [[ "$NGINX_PRESENT" -eq 1 ]] && echo "  - Web (Nginx):          ${site_url}"
  if [[ "$PHP_ENABLED" -eq 1 && "$NGINX_PRESENT" -eq 1 ]]; then
    local proto="http" phphost="${DOMAIN:-$ct_ip}"
    [[ "$SSL_ENABLED" -eq 1 ]] && proto="https"
    echo "  - Prueba PHP:            ${proto}://${phphost}/info.php  (bórrala cuando termines de comprobarla)"
  fi
  if pct exec "$CTID" -- test -x "$FILEBROWSER_BIN" >/dev/null 2>&1; then
    echo "  - Filebrowser:           http://${ct_ip}:${FILEBROWSER_PORT}/"
    echo "  - Usuario Filebrowser:   ${FILEBROWSER_USER}"
    echo "  - Contraseña Filebrowser: ${FILEBROWSER_PASSWORD}"
  fi
  echo "  - Webroot dentro del CT: ${WEBROOT}"
  echo
  warn "Recuerda cambiar las contraseñas por defecto si no las personalizaste al preguntar."
  if [[ -z "$DOMAIN" ]]; then
    warn "No configuraste un dominio: Nginx responde a cualquier host (server_name _), solo por IP."
    warn "Si más adelante quieres un dominio y/o HTTPS, vuelve a ejecutar este script indicando este mismo CTID."
  elif [[ "$SSL_ENABLED" -eq 0 ]]; then
    warn "El sitio usa el dominio ${DOMAIN} pero todavía sin HTTPS. Para activarlo:"
    echo "   pct exec ${CTID} -- apt-get install -y certbot python3-certbot-nginx"
    echo "   pct exec ${CTID} -- certbot --nginx -d ${DOMAIN}"
  fi
}

# ============================================================
# FLUJO: contenedor YA EXISTENTE -> preguntar solo lo que falta
# ============================================================
manage_existing_container() {
  log "El contenedor $CTID ya existe. Comprobando qué tiene instalado..."

  if [[ "$(pct status "$CTID")" != "status: running" ]]; then
    warn "El contenedor está detenido, arrancándolo..."
    pct start "$CTID"
    sleep 5
  fi

  detect_installed

  echo
  echo "Estado actual del contenedor $CTID:"
  echo "  - Nginx:       $([[ $HAS_NGINX -eq 1 ]] && echo 'instalado' || echo 'no instalado')"
  echo "  - PHP-FPM:     $([[ $HAS_PHP -eq 1 ]] && echo 'instalado' || echo 'no instalado')"
  echo "  - Filebrowser: $([[ $HAS_FILEBROWSER -eq 1 ]] && echo 'instalado' || echo 'no instalado')"
  echo

  DO_NGINX=0; DO_PHP=0; DO_FILEBROWSER=0

  if [[ $HAS_NGINX -eq 0 ]] && ask_yes_no "¿Instalar Nginx?" "s"; then
    DO_NGINX=1
  fi
  if [[ $HAS_PHP -eq 0 ]] && ask_yes_no "¿Instalar PHP-FPM?" "s"; then
    DO_PHP=1
  fi
  if [[ $HAS_FILEBROWSER -eq 0 ]] && ask_yes_no "¿Instalar Filebrowser?" "s"; then
    DO_FILEBROWSER=1
    ask "Puerto para Filebrowser" FILEBROWSER_PORT
    ask "Usuario admin de Filebrowser" FILEBROWSER_USER
    ask "Longitud mínima de contraseña para Filebrowser" FILEBROWSER_MIN_PASSWORD_LENGTH
    ask_secret "Contraseña de Filebrowser (mínimo ${FILEBROWSER_MIN_PASSWORD_LENGTH} caracteres)" FILEBROWSER_PASSWORD
  fi

  NGINX_PRESENT=0
  [[ $HAS_NGINX -eq 1 || $DO_NGINX -eq 1 ]] && NGINX_PRESENT=1
  PHP_ENABLED="$HAS_PHP"

  # --- Dominio / HTTPS (solo tiene sentido si hay o habrá Nginx) ---
  if [[ $NGINX_PRESENT -eq 1 ]]; then
    detect_existing_ssl   # si ya había un certificado, fija DOMAIN y ENABLE_SSL

    if [[ -z "$DOMAIN" ]] && ask_yes_no "¿Quieres configurar un dominio para este sitio? (recomendado si vas a usar HTTPS)" "n"; then
      ask "Dominio (ej: midominio.com)" DOMAIN
    fi

    if [[ -n "$DOMAIN" && "$ENABLE_SSL" -eq 0 ]] && ask_yes_no "¿Configurar HTTPS automáticamente con Certbot para $DOMAIN? (el dominio debe apuntar ya a la IP pública de este contenedor)" "n"; then
      ENABLE_SSL=1
      ask "Email para el registro de Let's Encrypt (opcional)" CERTBOT_EMAIL
    fi
  fi

  if [[ $DO_NGINX -eq 0 && $DO_PHP -eq 0 && $DO_FILEBROWSER -eq 0 && -z "$DOMAIN" && $ENABLE_SSL -eq 0 ]]; then
    log "No se ha seleccionado nada nuevo para instalar ni configurar. Saliendo."
    exit 0
  fi

  [[ $DO_NGINX -eq 1 ]] && install_nginx
  [[ $DO_PHP -eq 1 ]] && install_php
  [[ $DO_FILEBROWSER -eq 1 ]] && install_filebrowser

  # Si hay dominio pero nada de lo anterior ha regenerado ya el vhost
  # (install_nginx/install_php lo hacen internamente), aplicarlo ahora.
  if [[ $NGINX_PRESENT -eq 1 && $DO_NGINX -eq 0 && $DO_PHP -eq 0 && -n "$DOMAIN" ]]; then
    configure_nginx
  fi

  [[ "$ENABLE_SSL" -eq 1 ]] && enable_ssl

  ensure_ufw
  local open_web=0 open_fb=0
  [[ $NGINX_PRESENT -eq 1 ]] && open_web=1
  [[ $DO_FILEBROWSER -eq 1 || $HAS_FILEBROWSER -eq 1 ]] && open_fb=1
  configure_firewall "$open_web" "$open_fb"

  print_summary
}

# ============================================================
# FLUJO: contenedor NUEVO -> preguntar toda la configuración
# ============================================================
create_new_container() {
  log "El contenedor $CTID no existe todavía. Vamos a configurarlo."
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    echo "(Pulsa Enter en cualquier pregunta para mantener el valor por defecto que se muestra)"
  fi
  echo

  ask "Nombre de host del contenedor" CT_HOSTNAME
  ask "Storage para el disco del CT" STORAGE
  ask "Storage para las plantillas" TEMPLATE_STORAGE
  ask "Tamaño de disco (GB)" DISK_SIZE
  ask "Memoria RAM (MB)" MEMORY
  ask "Swap (MB)" SWAP
  ask "Núcleos de CPU" CORES
  ask "Bridge de red" BRIDGE
  ask "Configuración de red (ip=dhcp o ip=IP/CIDR,gw=GATEWAY)" NET_CONFIG
  ask_secret "Contraseña root del contenedor" CT_PASSWORD
  ask "¿Contenedor unprivileged? (1=sí, 0=no)" UNPRIVILEGED
  ask "Dominio para este sitio (opcional; déjalo vacío para acceder solo por IP)" DOMAIN
  if [[ -n "$DOMAIN" ]] && ask_yes_no "¿Configurar HTTPS automáticamente con Certbot para $DOMAIN? (el dominio debe apuntar ya a la IP pública de este contenedor)" "n"; then
    ENABLE_SSL=1
    ask "Email para el registro de Let's Encrypt (opcional, recomendado)" CERTBOT_EMAIL
  fi
  ask "Puerto de Filebrowser" FILEBROWSER_PORT
  ask "Usuario admin de Filebrowser" FILEBROWSER_USER
  ask "Longitud mínima de contraseña para Filebrowser" FILEBROWSER_MIN_PASSWORD_LENGTH
  ask_secret "Contraseña de Filebrowser (mínimo ${FILEBROWSER_MIN_PASSWORD_LENGTH} caracteres)" FILEBROWSER_PASSWORD
  if ask_yes_no "¿Instalar PHP-FPM ahora? (si dices que no, podrás añadirlo luego ejecutando este mismo script con este CTID)" "n"; then
    INSTALL_PHP=1
  else
    INSTALL_PHP=0
  fi

  if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
    err "El CTID debe ser numérico."
    exit 1
  fi

  echo
  log "Creando CTID=$CTID host=$CT_HOSTNAME storage=$STORAGE disco=${DISK_SIZE}G ram=${MEMORY}M swap=${SWAP}M cores=$CORES red=$NET_CONFIG dominio=${DOMAIN:-ninguno} https=$([[ $ENABLE_SSL -eq 1 ]] && echo sí || echo no) php=$([[ $INSTALL_PHP -eq 1 ]] && echo sí || echo no)"
  echo

  # --- 1. Buscar/descargar la plantilla de Debian 12 ---
  log "Actualizando índice de plantillas disponibles..."
  pveam update >/dev/null

  TEMPLATE_FILE=$(pveam available --section system | awk '{print $2}' | grep "$TEMPLATE_PATTERN" | sort -V | tail -n1 || true)
  if [[ -z "$TEMPLATE_FILE" ]]; then
    err "No se encontró ninguna plantilla que coincida con '$TEMPLATE_PATTERN'."
    exit 1
  fi

  if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE_FILE"; then
    log "Descargando plantilla $TEMPLATE_FILE..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE"
  else
    log "La plantilla $TEMPLATE_FILE ya está descargada."
  fi

  # --- 2. Crear el contenedor ---
  log "Creando contenedor CTID=$CTID ($CT_HOSTNAME)..."
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --net0 "name=eth0,bridge=${BRIDGE},${NET_CONFIG}" \
    --unprivileged "$UNPRIVILEGED" \
    --features nesting=1 \
    --password "$CT_PASSWORD" \
    --onboot 1

  log "Iniciando contenedor..."
  pct start "$CTID"

  log "Esperando a que arranque la red dentro del contenedor..."
  for i in $(seq 1 30); do
    if pct exec "$CTID" -- ping -c1 -W1 deb.debian.org >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  # --- 3. Aprovisionar ---
  install_nginx
  [[ "$INSTALL_PHP" -eq 1 ]] && install_php
  install_filebrowser
  [[ "$ENABLE_SSL" -eq 1 ]] && enable_ssl
  ensure_ufw
  configure_firewall 1 1

  print_summary
  if [[ "$INSTALL_PHP" -eq 0 ]]; then
    echo "  - PHP:                   no instalado. Para añadirlo luego, vuelve a ejecutar:"
    echo "                           bash $0   (e indica CTID=${CTID} cuando te lo pregunte)"
  fi
}

# ============================================================
# PUNTO DE ENTRADA
# ============================================================

ask "ID del contenedor LXC (existente o nuevo)" CTID

if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
  err "El CTID debe ser numérico."
  exit 1
fi

if pct status "$CTID" >/dev/null 2>&1; then
  manage_existing_container
else
  create_new_container
fi
