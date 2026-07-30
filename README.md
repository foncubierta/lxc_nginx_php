# lxc_nginx_php

Script para Proxmox VE que crea (o completa) un contenedor LXC Debian 12 listo para alojar una web:

- **Nginx** como servidor web
- **PHP-FPM** (opcional, se puede instalar en el momento de crear el LXC o más tarde)
- **Filebrowser** para subir archivos al webroot desde el navegador
- **Dominio y HTTPS** (Certbot / Let's Encrypt) opcionales
- **Firewall básico** (ufw) con los puertos necesarios abiertos

## Uso

Copia `create-lxc-web.sh` al nodo Proxmox y ejecútalo como root:

```bash
bash create-lxc-web.sh
```

El script pregunta la configuración de forma interactiva (CTID, hostname, recursos, red, dominio, credenciales, etc.). Pulsa Enter en cualquier pregunta para mantener el valor por defecto que se muestra entre corchetes.

- Si el **CTID no existe todavía**, se pregunta el resto de la configuración y se crea el contenedor desde cero.
- Si el **CTID ya existe**, el script detecta qué tiene instalado (Nginx / PHP / Filebrowser) y solo pregunta por lo que falta, para completarlo sin crear un LXC nuevo.

También se puede automatizar sin preguntas exportando `NONINTERACTIVE=1` (o lanzando el script sin terminal, p. ej. desde cron), usando variables de entorno para fijar los valores: `CTID`, `CT_HOSTNAME`, `STORAGE`, `TEMPLATE_STORAGE`, `DISK_SIZE`, `MEMORY`, `SWAP`, `CORES`, `BRIDGE`, `NET_CONFIG`, `CT_PASSWORD`, `UNPRIVILEGED`, `FILEBROWSER_PORT`, `FILEBROWSER_USER`, `FILEBROWSER_PASSWORD`, `INSTALL_PHP`, `DOMAIN`, `ENABLE_SSL`, `CERTBOT_EMAIL`.

## Requisitos

- Proxmox VE con acceso a internet.
- Al menos un storage que soporte plantillas de contenedor (`vztmpl`) y discos (`rootfs`).
- Ejecutar el script como root en el shell del propio nodo Proxmox (no dentro de un contenedor).

## Qué configura

1. Descarga la plantilla de Debian 12 si no está disponible y crea el contenedor LXC con los recursos indicados.
2. Instala Nginx y publica una página de bienvenida en `/var/www/html`.
3. Si se pide, instala PHP-FPM con extensiones comunes y lo conecta con Nginx.
4. Si se indica un dominio, configura `server_name` en Nginx; si además se pide HTTPS, instala Certbot y solicita el certificado (con redirección automática a HTTPS).
5. Instala Filebrowser como servicio systemd apuntando al mismo webroot, para poder subir archivos por navegador.
6. Abre en el firewall (ufw) los puertos necesarios: SSH, 80, 443 y el puerto de Filebrowser.

Al terminar, muestra un resumen con las URLs y credenciales generadas.

## Licencia

MIT
