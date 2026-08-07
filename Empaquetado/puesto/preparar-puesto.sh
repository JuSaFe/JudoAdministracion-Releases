#!/usr/bin/env bash
#
# Deja un puesto de administración listo para trabajar contra el servidor de la competición, y lo
# devuelve a como estaba al terminar el evento.
#
# La aplicación se instala con su instalador (Documentación/00); lo que hace este guion es lo que
# queda después y no trae el instalador, porque depende de la red y del servidor concretos:
#
#   · instalar el certificado del servidor como raíz de confianza — sin esto la aplicación no conecta
#   · asegurar la línea del archivo hosts que resuelve "judo-server"
#   · la configuración de la aplicación, solo si este equipo se sale de lo normal
#   · comprobar de punta a punta que el puesto llega al servidor
#
#     sudo ./preparar-puesto.sh --certificado judo-server.crt
#     sudo ./preparar-puesto.sh --deshacer
#     ./preparar-puesto.sh --simular --certificado judo-server.crt
#
# La IP fija del puesto NO la pone este guion: eso es Empaquetado/red/configurar-red.sh, que además
# guarda la configuración anterior para poder devolverla.
#
# Para macOS y Linux; el de Windows es preparar-puesto.ps1.
#
set -euo pipefail

# ── Parámetros ────────────────────────────────────────────────────────────────────────────────────

NOMBRE_SERVIDOR="judo-server"
IP_SERVIDOR="192.168.2.3"
PUERTO=8443
CERTIFICADO=""
DIR_APP=""
ANFITRION=0
SIN_HOSTS=0
DESHACER=0
SIMULAR=0
SIN_PREGUNTAS=0

MARCA="# JudoAdministracion"
MARCA_CONFIG="Generado por Empaquetado/puesto/preparar-puesto"
HOSTS="/etc/hosts"
SISTEMA="$(uname)"

ayuda() {
    cat <<'AYUDA'
Prepara un puesto de administración para la competición (y lo deshace al terminar).

  --certificado RUTA   Certificado público del servidor (judo-server.crt)
  --nombre NOMBRE      Nombre del servidor (por defecto judo-server)
  --ip-servidor IP     Su dirección (por defecto 192.168.2.3)
  --puerto N           Puerto de la API (por defecto 8443)
  --dir RUTA           Carpeta de la aplicación (si no, se busca donde suele estar)

  --anfitrion          Este equipo es el que hostea la aplicación: apunta a localhost
                       en vez de al nombre del servidor
  --sin-hosts          No tocar el archivo hosts

  --deshacer           Quitar el certificado y la configuración que puso este guion
  --simular            Decir lo que haría, sin cambiar nada
  --si                 No preguntar
  --ayuda              Esto

La IP fija del puesto se pone con Empaquetado/red/configurar-red.sh, que es también el que la
devuelve a como estaba al acabar la competición.
AYUDA
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --certificado)  CERTIFICADO="$2"; shift 2 ;;
        --nombre)       NOMBRE_SERVIDOR="$2"; shift 2 ;;
        --ip-servidor)  IP_SERVIDOR="$2"; shift 2 ;;
        --puerto)       PUERTO="$2"; shift 2 ;;
        --dir)          DIR_APP="$2"; shift 2 ;;
        --anfitrion)    ANFITRION=1; shift ;;
        --sin-hosts)    SIN_HOSTS=1; shift ;;
        --hosts)        HOSTS="$2"; shift 2 ;;
        --deshacer)     DESHACER=1; shift ;;
        --simular)      SIMULAR=1; shift ;;
        --si)           SIN_PREGUNTAS=1; shift ;;
        --ayuda|-h)     ayuda; exit 0 ;;
        *) echo "Parámetro desconocido: $1"; echo; ayuda; exit 1 ;;
    esac
done

# ── Utilidades ────────────────────────────────────────────────────────────────────────────────────

AZUL=$'\033[1;34m'; VERDE=$'\033[0;32m'; AMARILLO=$'\033[0;33m'; ROJO=$'\033[0;31m'; FIN=$'\033[0m'

paso()  { echo; echo "${AZUL}── $*${FIN}"; }
bien()  { echo "   ${VERDE}✓${FIN} $*"; }
aviso() { echo "   ${AMARILLO}!${FIN} $*"; }
fallo() { echo "   ${ROJO}✗${FIN} $*" >&2; exit 1; }
igual() { echo "   ${VERDE}=${FIN} $*"; }

ejecutar() {
    if [[ $SIMULAR -eq 1 ]]; then echo "   ${AMARILLO}[simulado]${FIN} $*"; else "$@"; fi
}

confirmar() {
    [[ $SIN_PREGUNTAS -eq 1 ]] && return 0
    local respuesta
    read -r -p "   $1 [s/N] " respuesta
    [[ "$respuesta" =~ ^[sSyY]$ ]]
}

if [[ $SIMULAR -eq 0 && $EUID -ne 0 ]]; then
    fallo "Instalar un certificado en el almacén del sistema necesita administrador:
       sudo $0 $*"
fi

# ── Dónde está la aplicación ──────────────────────────────────────────────────────────────────────

buscar_app() {
    [[ -n "$DIR_APP" ]] && return 0
    local candidatas
    if [[ "$SISTEMA" == "Darwin" ]]; then
        candidatas="/Applications/JudoAdministracion.app/Contents/MacOS"
    else
        candidatas="/opt/judoadministracion"
    fi
    local c
    for c in $candidatas; do
        if [[ -x "$c/JudoAdministracion" ]]; then DIR_APP="$c"; return 0; fi
    done
    return 1
}

# ── Certificado en el almacén del sistema ─────────────────────────────────────────────────────────

instalar_certificado() {
    if [[ "$SISTEMA" == "Darwin" ]]; then
        # En el llavero del SISTEMA y no en el del usuario: la aplicación puede acabar ejecutándose
        # con otra cuenta, y .NET consulta el del sistema.
        ejecutar security add-trusted-cert -d -r trustRoot \
                 -k /Library/Keychains/System.keychain "$CERTIFICADO"
    elif [[ -d /usr/local/share/ca-certificates ]]; then
        ejecutar cp "$CERTIFICADO" "/usr/local/share/ca-certificates/$NOMBRE_SERVIDOR.crt"
        ejecutar update-ca-certificates
    elif [[ -d /etc/pki/ca-trust/source/anchors ]]; then
        ejecutar cp "$CERTIFICADO" "/etc/pki/ca-trust/source/anchors/$NOMBRE_SERVIDOR.crt"
        ejecutar update-ca-trust
    else
        fallo "No sé dónde instalar certificados en este sistema. Hazlo a mano: guía 01, §4.2."
    fi
}

quitar_certificado() {
    if [[ "$SISTEMA" == "Darwin" ]]; then
        # Por nombre común, que es lo único seguro cuando ya no tenemos el archivo delante. Las dos
        # órdenes pueden fallar si no estaba instalado, y eso no es un error.
        if [[ -n "$CERTIFICADO" && -f "$CERTIFICADO" ]]; then
            ejecutar security remove-trusted-cert -d "$CERTIFICADO" || true
        fi
        ejecutar security delete-certificate -c "$NOMBRE_SERVIDOR" -t \
                 /Library/Keychains/System.keychain || true
    else
        local instalado=""
        [[ -f "/usr/local/share/ca-certificates/$NOMBRE_SERVIDOR.crt" ]] \
            && instalado="/usr/local/share/ca-certificates/$NOMBRE_SERVIDOR.crt"
        [[ -f "/etc/pki/ca-trust/source/anchors/$NOMBRE_SERVIDOR.crt" ]] \
            && instalado="/etc/pki/ca-trust/source/anchors/$NOMBRE_SERVIDOR.crt"

        if [[ -z "$instalado" ]]; then
            igual "el certificado no estaba en el almacén del sistema"
            return
        fi
        ejecutar rm -f "$instalado"
        if command -v update-ca-certificates >/dev/null; then
            ejecutar update-ca-certificates --fresh
        else
            ejecutar update-ca-trust
        fi
    fi
}

# ── Archivo hosts ─────────────────────────────────────────────────────────────────────────────────
# La misma lógica y la misma marca que configurar-red.sh, a propósito: cada guion se puede usar por
# separado, y quitar la línea con cualquiera de los dos deja el archivo igual.

poner_hosts() {
    if grep -q "$MARCA" "$HOSTS" 2>/dev/null; then
        igual "la línea de $NOMBRE_SERVIDOR ya está en $HOSTS"
        return
    fi
    if [[ $SIMULAR -eq 1 ]]; then
        echo "   ${AMARILLO}[simulado]${FIN} añadiría a $HOSTS:  $IP_SERVIDOR  $NOMBRE_SERVIDOR  $MARCA"
        return
    fi
    printf '%s\t%s\t%s\n' "$IP_SERVIDOR" "$NOMBRE_SERVIDOR" "$MARCA" >> "$HOSTS"
    bien "$NOMBRE_SERVIDOR → $IP_SERVIDOR en $HOSTS"
}

quitar_hosts() {
    if ! grep -q "$MARCA" "$HOSTS" 2>/dev/null; then
        igual "no había ninguna línea de JudoAdministración en $HOSTS"
        return
    fi
    if [[ $SIMULAR -eq 1 ]]; then
        echo "   ${AMARILLO}[simulado]${FIN} quitaría de $HOSTS las líneas marcadas con $MARCA"
        return
    fi
    local temporal; temporal="$(mktemp)"
    grep -v "$MARCA" "$HOSTS" > "$temporal"
    cat "$temporal" > "$HOSTS"          # cat y no mv, para conservar permisos y dueño de /etc/hosts
    rm -f "$temporal"
    bien "línea de $NOMBRE_SERVIDOR quitada de $HOSTS"
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
#  DESHACER
# ══════════════════════════════════════════════════════════════════════════════════════════════════

if [[ $DESHACER -eq 1 ]]; then
    echo
    echo "${AZUL}Devolver este puesto a como estaba${FIN}"
    [[ $SIMULAR -eq 1 ]] && aviso "modo simulación: no se cambia nada"

    confirmar "¿Quito el certificado de $NOMBRE_SERVIDOR y su configuración?" \
        || { echo "   Cancelado."; exit 0; }

    paso "1/3  Certificado"
    quitar_certificado
    bien "certificado de $NOMBRE_SERVIDOR retirado del almacén del sistema"

    paso "2/3  Configuración de la aplicación"
    if buscar_app && [[ -f "$DIR_APP/appsettings.Local.json" ]]; then
        if grep -q "$MARCA_CONFIG" "$DIR_APP/appsettings.Local.json" 2>/dev/null; then
            ejecutar rm -f "$DIR_APP/appsettings.Local.json"
            bien "appsettings.Local.json (el que puso este guion) eliminado"
        else
            aviso "hay un appsettings.Local.json que NO escribió este guion: no lo toco"
            aviso "  $DIR_APP/appsettings.Local.json"
        fi
    else
        igual "no hay configuración local que quitar"
    fi

    paso "3/3  Archivo hosts"
    if [[ $SIN_HOSTS -eq 0 ]]; then quitar_hosts; else igual "sin tocar (--sin-hosts)"; fi

    echo
    echo "${VERDE}Puesto limpio.${FIN}"
    echo
    echo "   La aplicación sigue instalada; se desinstala como cualquier otro programa."
    echo
    echo "   ${AMARILLO}Falta devolver la red, que es lo que le importa a quien use este equipo:${FIN}"
    echo "     sudo Empaquetado/red/configurar-red.sh --deshacer"
    echo
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
#  PREPARAR
# ══════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "${AZUL}Preparación de un puesto de administración${FIN}"
echo "   servidor $NOMBRE_SERVIDOR ($IP_SERVIDOR), puerto $PUERTO"
[[ $ANFITRION -eq 1 ]] && echo "   este equipo es el ANFITRIÓN"
[[ $SIMULAR -eq 1 ]] && aviso "modo simulación: no se cambia nada"

# ── 1. Comprobaciones previas ─────────────────────────────────────────────────────────────────────

paso "1/5  Comprobaciones previas"

if [[ -z "$CERTIFICADO" ]]; then
    # Lo normal es traerlo en un USB y ejecutar el guion desde esa carpeta.
    for candidato in "./$NOMBRE_SERVIDOR.crt" "$NOMBRE_SERVIDOR.crt" "./judo-server.crt"; do
        [[ -f "$candidato" ]] && { CERTIFICADO="$candidato"; break; }
    done
fi

[[ -n "$CERTIFICADO" && -f "$CERTIFICADO" ]] || fallo "No encuentro el certificado del servidor.
     Cópialo desde el servidor ($NOMBRE_SERVIDOR.crt, NO el .pfx) e indícalo con
     --certificado <ruta>. Se genera en la guía 01, §3.4."

# Que sea un certificado de verdad y que sirva para este nombre: si se emitió sin él, la aplicación
# lo rechazará y el error aparecerá mucho más tarde, al abrir la aplicación.
command -v openssl >/dev/null || fallo "Falta openssl para comprobar el certificado."
if ! openssl x509 -in "$CERTIFICADO" -noout >/dev/null 2>&1; then
    fallo "$CERTIFICADO no es un certificado en formato PEM.
     Si lo exportaste en Windows, tiene que ser el .crt en base 64, no en DER."
fi
bien "certificado legible: $CERTIFICADO"

nombres="$(openssl x509 -in "$CERTIFICADO" -noout -ext subjectAltName 2>/dev/null || true)"
if grep -q "DNS:$NOMBRE_SERVIDOR" <<<"$nombres"; then
    bien "sirve para el nombre $NOMBRE_SERVIDOR"
else
    aviso "el certificado NO incluye DNS:$NOMBRE_SERVIDOR entre sus nombres"
    aviso "la aplicación rechazará la conexión; hay que reemitirlo (guía 01, §3.4)"
    confirmar "¿Seguir de todas formas?" || { echo "   Cancelado."; exit 0; }
fi

caduca="$(openssl x509 -in "$CERTIFICADO" -noout -enddate | cut -d= -f2)"
bien "válido hasta $caduca"

if buscar_app; then
    bien "aplicación instalada en $DIR_APP"
else
    aviso "no encuentro la aplicación instalada"
    aviso "el certificado se puede instalar igual; la aplicación, después (guía 01, §4.1)"
fi

# ── 2. Certificado ────────────────────────────────────────────────────────────────────────────────

paso "2/5  Certificado en el almacén del sistema"

instalar_certificado
bien "instalado como raíz de confianza de este equipo"

# ── 3. Archivo hosts ──────────────────────────────────────────────────────────────────────────────

paso "3/5  Nombre del servidor"

if [[ $SIN_HOSTS -eq 1 ]]; then
    igual "archivo hosts sin tocar (--sin-hosts)"
elif [[ $ANFITRION -eq 1 ]]; then
    igual "el anfitrión conecta por localhost: no necesita la línea de hosts"
else
    poner_hosts
fi

# ── 4. Configuración de la aplicación ─────────────────────────────────────────────────────────────

paso "4/5  Configuración de la aplicación"

# Un puesto normal NO necesita archivo de configuración: el appsettings.json que trae el paquete ya
# apunta a https://judo-server:8443 y sin credenciales de base de datos, que es exactamente lo que
# tiene que ser. Solo se escribe cuando este equipo se sale de eso.
URL_API="https://$NOMBRE_SERVIDOR:$PUERTO"
[[ $ANFITRION -eq 1 ]] && URL_API="https://localhost:$PUERTO"

HACE_FALTA=0
[[ $ANFITRION -eq 1 ]] && HACE_FALTA=1
[[ "$NOMBRE_SERVIDOR" != "judo-server" || "$PUERTO" != "8443" ]] && HACE_FALTA=1

if [[ $HACE_FALTA -eq 0 ]]; then
    igual "no hace falta: el paquete ya viene apuntando a $URL_API"
elif ! buscar_app; then
    aviso "haría falta escribir appsettings.Local.json con ApiBaseUrl=$URL_API,"
    aviso "pero la aplicación no está instalada. Vuelve a ejecutar el guion después."
elif [[ -f "$DIR_APP/appsettings.Local.json" ]] \
     && ! grep -q "$MARCA_CONFIG" "$DIR_APP/appsettings.Local.json" 2>/dev/null; then
    aviso "ya hay un appsettings.Local.json que no escribió este guion: no lo toco"
    aviso "comprueba a mano que ApiBaseUrl sea $URL_API"
elif [[ $SIMULAR -eq 1 ]]; then
    echo "   ${AMARILLO}[simulado]${FIN} escribiría $DIR_APP/appsettings.Local.json con ApiBaseUrl=$URL_API"
else
    cat > "$DIR_APP/appsettings.Local.json" <<JSON
{
    "//": [
        "$MARCA_CONFIG.sh",
        "ApiBaseUrl: dónde escucha el servidor de la competición.",
        "ConnectionString vacía: un puesto de la red NO habla con PostgreSQL.",
        "Ver Documentación/01-Guía-de-Instalación.md, §4.4."
    ],
    "ApiBaseUrl": "$URL_API",
    "ConnectionString": ""
}
JSON
    chmod 644 "$DIR_APP/appsettings.Local.json"
    bien "escrita con ApiBaseUrl=$URL_API"
    [[ $ANFITRION -eq 1 ]] && aviso "el anfitrión necesita además ConnectionString mientras queden
     pantallas sin migrar; ponla a mano (guía 01, §5)"
fi

# ── 5. Comprobación de punta a punta ──────────────────────────────────────────────────────────────

paso "5/5  ¿Llega este puesto al servidor?"

# Estas comprobaciones se hacen también en simulación: no cambian nada, y son lo más útil del guion
# —sirven para diagnosticar un puesto que ya estaba montado sin tocarle nada—.
[[ $SIMULAR -eq 1 ]] && aviso "en simulación el certificado no está instalado todavía: es normal
     que la comprobación 4 diga que no es de confianza"

if true; then
    destino="$NOMBRE_SERVIDOR"
    [[ $ANFITRION -eq 1 ]] && destino="localhost"

    # En este orden a propósito: cada comprobación que falla dice en qué capa está el problema, en
    # lugar de dejar un "no conecta" genérico. Es la lista de la guía 01, §6.
    if [[ $ANFITRION -eq 0 ]]; then
        if ping -c 1 -W 1000 "$IP_SERVIDOR" >/dev/null 2>&1 \
        || ping -c 1 -W 1    "$IP_SERVIDOR" >/dev/null 2>&1; then
            bien "1. llego al servidor $IP_SERVIDOR"
        else
            aviso "1. no llego a $IP_SERVIDOR: revisa la red (configurar-red.sh) y el cable"
        fi

        if ping -c 1 -W 1000 "$NOMBRE_SERVIDOR" >/dev/null 2>&1 \
        || ping -c 1 -W 1    "$NOMBRE_SERVIDOR" >/dev/null 2>&1; then
            bien "2. el nombre $NOMBRE_SERVIDOR resuelve"
        else
            aviso "2. $NOMBRE_SERVIDOR no resuelve: falta la línea de $HOSTS"
        fi
    fi

    if command -v nc >/dev/null && nc -z -w 3 "$destino" "$PUERTO" 2>/dev/null; then
        bien "3. el puerto $PUERTO está abierto"
    else
        aviso "3. el puerto $PUERTO no responde: el servicio no está arrancado, o lo cierra el"
        aviso "   cortafuegos del servidor (doc 02, §3.3)"
    fi

    # La prueba de fuego: HTTPS SIN --cacert. Si responde, el certificado del paso 2 está bien
    # instalado y la aplicación va a poder conectar.
    if respuesta="$(curl -sf --max-time 8 "https://$destino:$PUERTO/api/estado" 2>/dev/null)"; then
        bien "4. HTTPS de confianza: el servidor responde $respuesta"
        echo
        echo "   ${VERDE}Este puesto está listo.${FIN}"
    else
        aviso "4. la conexión HTTPS falla"
        if curl -sfk --max-time 8 "https://$destino:$PUERTO/api/estado" >/dev/null 2>&1; then
            aviso "   el servidor responde, pero su certificado no es de confianza aquí:"
            aviso "   revisa el paso 2 y que el certificado sea el de ESTE servidor"
        else
            aviso "   el servidor no responde en https://$destino:$PUERTO"
        fi
    fi
fi

echo
echo "   Al acabar la competición, este puesto se limpia con:"
echo "     sudo $0 --deshacer"
echo "     sudo Empaquetado/red/configurar-red.sh --deshacer"
echo
