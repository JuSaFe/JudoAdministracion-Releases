#!/usr/bin/env bash
#
# Deja el servidor de competición funcionando de una sola vez: PostgreSQL, base de datos, roles,
# extensiones, certificado HTTPS, la configuración del servicio, el esquema con sus datos básicos,
# la configuración de la aplicación de escritorio de este mismo equipo, el nombre en el archivo
# hosts, el cortafuegos y el arranque automático.
#
#     sudo ./preparar-servidor.sh
#
# Sin ningún parámetro. Ésa es la idea: en un servidor recién formateado, esta línea es toda la
# instalación. Todo lo que hace falta lo hace, y lo que no se puede decidir por nadie —la contraseña
# del administrador y el alta de los usuarios— queda listado al final.
#
# Es el equivalente ejecutable de la Documentación/01-Guía-de-Instalación.md, §3. Para macOS y
# Linux; el de Windows es preparar-servidor.ps1.
#
# Antes de ejecutarlo hay que haber descomprimido el paquete del servicio en /opt/judoadministracion-api
# (el api-<sistema> de la Documentación/00). El guion, el SQL de roles y el ejecutable vienen todos
# dentro de ese paquete, así que lo normal es lanzarlo desde ahí.
#
# Es idempotente: se puede volver a ejecutar sobre un servidor ya preparado. Lo que ya existe se
# respeta —en particular la configuración y el certificado, que no se regeneran salvo que se pida
# expresamente— y lo que falta se crea.
#
set -euo pipefail

# ── Parámetros ────────────────────────────────────────────────────────────────────────────────────
#
# Todas las opciones son para NO hacer algo. Por defecto se hace todo: un servidor de competición
# necesita las diez cosas, y tener que acordarse de pedirlas una a una era la principal fuente de
# instalaciones a medias.

BD="JudoAdministracion"
NOMBRE_SERVIDOR="judo-server"
IP_SERVIDOR="192.168.2.3"
DIR_SERVICIO="/opt/judoadministracion-api"
DIR_APP=""
SUPERUSUARIO="postgres"
PUERTO=8443

CLAVE_OWNER=""
CLAVE_API=""
CLAVE_PFX=""
CLAVE_TOKENS=""

SIN_POSTGRESQL=0
SIN_SERVICIO=0
SIN_APLICACION=0
SIN_CONFIANZA=0
SIN_HOSTS=0
SIN_CORTAFUEGOS=0
SIN_ESQUEMA=0

REGENERAR_CERTIFICADO=0
FORZAR_CONFIGURACION=0
SIN_PREGUNTAS=0

DESHACER=0
SIMULAR=0
SIN_BASE_DATOS=0

ayuda() {
    cat <<'AYUDA'
Prepara el servidor de competición de JudoAdministración. Sin parámetros hace TODO lo que hace
falta; las opciones sirven para quitar partes.

  sudo ./preparar-servidor.sh

Qué se puede NO hacer:

  --sin-postgresql         No instalar PostgreSQL aunque falte (falla si no está)
  --sin-servicio           No dejar la API arrancando sola al encender el equipo
  --sin-aplicacion         No configurar la aplicación de escritorio de este equipo
  --sin-confianza          No instalar el certificado como raíz de confianza de este equipo
  --sin-hosts              No tocar el archivo hosts
  --sin-cortafuegos        No tocar el cortafuegos
  --sin-esquema            No inicializar el esquema (solo prepara la base de datos)

Qué se puede cambiar:

  --dir RUTA               Carpeta del servicio (por defecto /opt/judoadministracion-api)
  --dir-aplicacion RUTA    Carpeta de la aplicación de escritorio (si no, se busca)
  --bd NOMBRE              Base de datos (por defecto JudoAdministracion)
  --nombre NOMBRE          Nombre de red del servidor (por defecto judo-server)
  --ip DIRECCIÓN           IP del servidor (por defecto 192.168.2.3)
  --puerto N               Puerto de la API (por defecto 8443)
  --superusuario USUARIO   Superusuario de PostgreSQL (por defecto postgres)

  --clave-owner CLAVE      Contraseña de judo_owner (por defecto, se genera)
  --clave-api CLAVE        Contraseña de judo_api   (por defecto, se genera)
  --clave-pfx CLAVE        Contraseña del certificado (por defecto, se genera)

  --regenerar-certificado  Rehacer el certificado aunque ya exista
  --forzar-configuracion   Reescribir appsettings.Local.json aunque ya exista
  --si                     No preguntar nada
  --ayuda                  Esto

Desinstalar:

  --deshacer               Quitar de este equipo TODO lo que puso este guion, incluidas la
                           base de datos, los roles y PostgreSQL. Ver abajo.
  --simular                Con --deshacer: enseñar lo que haría, sin tocar nada
  --sin-base-datos         Con --deshacer: conservar la base de datos, los roles y PostgreSQL

--deshacer BORRA LA BASE DE DATOS. Se lleva, por este orden: el servicio del sistema, la base de
datos y sus roles, PostgreSQL, el certificado del almacén de confianza, la línea del hosts, las
reglas del cortafuegos y la carpeta del servicio con sus copias. Antes de borrar la base de datos
saca un volcado al home, que es lo único que queda al terminar. Pruébalo con --simular primero.

PostgreSQL solo se desinstala si en el clúster NO hay más bases de datos que las de esta
aplicación: en un equipo que ya lo tenía puesto de antes, desinstalarlo se llevaría datos que no
son de aquí. Si las hay, se dice y se deja el gestor donde está.

Al terminar deja las contraseñas en ~/judo-credenciales-servidor.txt y, en ~/judo-puestos/, todo
lo que hay que llevarse a los puestos: el certificado público y los guiones de preparación.
AYUDA
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)                    DIR_SERVICIO="$2"; shift 2 ;;
        --dir-aplicacion)         DIR_APP="$2"; shift 2 ;;
        --bd)                     BD="$2"; shift 2 ;;
        --nombre)                 NOMBRE_SERVIDOR="$2"; shift 2 ;;
        --ip)                     IP_SERVIDOR="$2"; shift 2 ;;
        --puerto)                 PUERTO="$2"; shift 2 ;;
        --superusuario)           SUPERUSUARIO="$2"; shift 2 ;;
        --clave-owner)            CLAVE_OWNER="$2"; shift 2 ;;
        --clave-api)              CLAVE_API="$2"; shift 2 ;;
        --clave-pfx)              CLAVE_PFX="$2"; shift 2 ;;
        --sin-postgresql)         SIN_POSTGRESQL=1; shift ;;
        --sin-servicio)           SIN_SERVICIO=1; shift ;;
        --sin-aplicacion)         SIN_APLICACION=1; shift ;;
        --sin-confianza)          SIN_CONFIANZA=1; shift ;;
        --sin-hosts)              SIN_HOSTS=1; shift ;;
        --sin-cortafuegos)        SIN_CORTAFUEGOS=1; shift ;;
        --sin-esquema)            SIN_ESQUEMA=1; shift ;;
        --regenerar-certificado)  REGENERAR_CERTIFICADO=1; shift ;;
        --forzar-configuracion)   FORZAR_CONFIGURACION=1; shift ;;
        --si)                     SIN_PREGUNTAS=1; shift ;;
        --deshacer)               DESHACER=1; shift ;;
        --simular)                SIMULAR=1; shift ;;
        --sin-base-datos)         SIN_BASE_DATOS=1; shift ;;
        --ayuda|-h)               ayuda; exit 0 ;;

        # Nombres de la versión anterior, cuando había que pedir cada cosa. Ahora son el
        # comportamiento por defecto; se aceptan para no romper notas ni guiones de nadie.
        --instalar-postgresql|--instalar-servicio|--confiar-certificado) shift ;;

        *) echo "Parámetro desconocido: $1"; echo; ayuda; exit 1 ;;
    esac
done

AQUI="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"

# Este guion se ejecuta en dos sitios distintos y las rutas no son las mismas en uno y en otro:
# desde el paquete descomprimido en el servidor —donde el guion, el binario y Despliegue/ están en
# la misma carpeta— y desde el repositorio, donde el SQL vive en JudoAdministracion.Api/Despliegue/.
# Si no se ha indicado --dir y al lado del guion está el binario, la carpeta del servicio es ésa.
if [[ "$DIR_SERVICIO" == "/opt/judoadministracion-api" && -x "$AQUI/JudoAdministracion.Api" ]]; then
    DIR_SERVICIO="$AQUI"
fi

SQL_ROLES=""
for candidato in \
    "$AQUI/Despliegue/01_roles.sql" \
    "$DIR_SERVICIO/Despliegue/01_roles.sql" \
    "$RAIZ/JudoAdministracion.Api/Despliegue/01_roles.sql"
do
    [[ -f "$candidato" ]] && { SQL_ROLES="$candidato"; break; }
done

BINARIO="$DIR_SERVICIO/JudoAdministracion.Api"
CONFIG="$DIR_SERVICIO/appsettings.Local.json"
PFX="$DIR_SERVICIO/$NOMBRE_SERVIDOR.pfx"
CRT="$DIR_SERVICIO/$NOMBRE_SERVIDOR.crt"
KEY="$DIR_SERVICIO/$NOMBRE_SERVIDOR.key"
SISTEMA="$(uname)"
HOSTS="/etc/hosts"
MARCA_HOSTS="# JudoAdministracion"
SUBRED="${IP_SERVIDOR%.*}.0/24"

# Los archivos que el técnico se lleva del servidor van al home de quien ejecuta el guion, no al de
# root: con sudo, HOME sigue siendo el suyo en Linux pero no siempre en macOS, así que se resuelve
# desde SUDO_USER cuando lo hay.
if [[ -n "${SUDO_USER:-}" ]]; then
    HOGAR="$(eval echo "~$SUDO_USER")"
else
    HOGAR="$HOME"
fi
CREDENCIALES="$HOGAR/judo-credenciales-servidor.txt"
PARA_PUESTOS="$HOGAR/judo-puestos"

# ── Utilidades ────────────────────────────────────────────────────────────────────────────────────

AZUL=$'\033[1;34m'; VERDE=$'\033[0;32m'; AMARILLO=$'\033[0;33m'; ROJO=$'\033[0;31m'; FIN=$'\033[0m'

paso()    { echo; echo "${AZUL}── $*${FIN}"; }
bien()    { echo "   ${VERDE}✓${FIN} $*"; }
aviso()   { echo "   ${AMARILLO}!${FIN} $*"; }
fallo()   { echo "   ${ROJO}✗${FIN} $*" >&2; exit 1; }
igual()   { echo "   ${VERDE}=${FIN} $*"; }          # ya estaba hecho, no se toca

confirmar() {
    [[ $SIN_PREGUNTAS -eq 1 ]] && return 0
    read -r -p "   $1 [s/N] " respuesta
    [[ "$respuesta" =~ ^[sSyY]$ ]]
}

# Contraseñas solo con letras y números: van dentro de una cadena de conexión y de un JSON, y así no
# hay que preocuparse por comillas, punto y coma o barras.
#
# Con openssl y no con "tr -dc … < /dev/urandom | head -c": ahí head cierra la tubería en cuanto tiene
# lo que quería, tr muere con SIGPIPE y, con pipefail activado, el guion entero se va al suelo.
generar_clave() { openssl rand -hex 16; }           # 32 caracteres, 128 bits

# Escribe donde haga falta, con sudo solo si el destino no es escribible. El guion NO se ejecuta
# entero como root a propósito: en macOS con Homebrew, PostgreSQL responde al usuario que ha iniciado
# sesión y no a root, así que elevar todo rompería psql.
escribir() {                                        # escribir <ruta> < contenido por la entrada
    local destino="$1" carpeta
    carpeta="$(dirname "$destino")"

    if [[ -w "$carpeta" ]] && { [[ ! -e "$destino" ]] || [[ -w "$destino" ]]; }; then
        cat > "$destino"
    else
        sudo tee "$destino" >/dev/null
    fi
}

permisos() { chmod "$@" 2>/dev/null || sudo chmod "$@"; }

NECESITA_ROOT=0
como_root() { if [[ $NECESITA_ROOT -eq 1 ]]; then sudo "$@"; else "$@"; fi; }

# Leer un valor de un appsettings.Local.json ya escrito. No hace falta un analizador de JSON: los
# archivos que lee esto son los que escribe este mismo guion, con una propiedad por línea.
leer_json() {                                       # leer_json <archivo> <propiedad>
    [[ -f "$1" ]] || return 1
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\(.*\)\".*/\1/p" "$1" | head -1
}

# ── psql con superusuario ─────────────────────────────────────────────────────────────────────────
# Tres formas según el sistema, resueltas una vez:
#   · psql -U postgres          instalador de EDB, Postgres.app, o un clúster con ese rol
#   · sudo -u postgres psql     Linux con autenticación "peer", que es lo habitual en apt
#   · psql                      Homebrew en macOS, donde el superusuario es el propio usuario
MODO_PSQL=""
resolver_psql() {
    if psql -U "$SUPERUSUARIO" -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; then
        MODO_PSQL="usuario"
    elif sudo -n -u "$SUPERUSUARIO" psql -d postgres -tAc 'SELECT 1' >/dev/null 2>&1 \
      || sudo    -u "$SUPERUSUARIO" psql -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; then
        MODO_PSQL="sudo"
    elif psql -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; then
        MODO_PSQL="local"
    else
        return 1
    fi
}

psql_super() {
    case "$MODO_PSQL" in
        usuario) psql -U "$SUPERUSUARIO" "$@" ;;
        sudo)    sudo -u "$SUPERUSUARIO" psql "$@" ;;
        local)   psql "$@" ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
#  DESHACER
# ══════════════════════════════════════════════════════════════════════════════════════════════════
#
# Quita de este equipo todo lo que puso la instalación, en el orden inverso al que lo puso. El orden
# no es cosmético: el volcado de la base de datos tiene que salir ANTES de borrarla, y borrarla antes
# de desinstalar PostgreSQL, porque después ya no habría con qué hacer ninguna de las dos cosas.
#
# Esto BORRA LA BASE DE DATOS sin volver a preguntar. Es una decisión deliberada: --deshacer es lo
# que se ejecuta al retirar un servidor o al devolver un equipo prestado, y dejar la base de datos
# ahí «por si acaso» convertía la desinstalación en algo que nunca terminaba de estar hecho. El
# volcado del paso 2 es la red de seguridad, y --simular es la forma de ver qué va a pasar antes de
# que pase.

# Las órdenes que borran o desinstalan pasan por aquí, y así --simular sale gratis en todas.
#
# En simulación no ejecuta nada y no imprime nada: la línea que se lee la pone el llamante con
# «resultado», que es la que sabe explicar qué se ha hecho. Que «hacer» imprimiera la orden en crudo
# tenía un problema peor que ser ilegible: los llamantes que redirigían su salida a /dev/null se
# comían ese aviso y dejaban un «✓ borrado» que no era verdad.
hacer() {
    [[ $SIMULAR -eq 1 ]] && return 0
    "$@"
}

# Igual, pero sin dejar salir lo que escriba la orden. psql contesta "DROP ROLE" a cada cosa y aquí
# el resultado ya se cuenta con «resultado».
hacer_callado() {
    [[ $SIMULAR -eq 1 ]] && return 0
    "$@" >/dev/null 2>&1
}

# «✓ hecho» cuando se ha hecho, «[simulado] hecho» cuando solo se ha simulado. Un ✓ en modo
# simulación es una mentira, y es justo el modo en el que hay que poder confiar en lo que se lee.
resultado() {
    if [[ $SIMULAR -eq 1 ]]; then
        echo "   ${AMARILLO}[simulado]${FIN} $*"
    else
        bien "$*"
    fi
}

PLIST_LAUNCHD="/Library/LaunchDaemons/es.judo.api.plist"
UNIDAD_SYSTEMD="/etc/systemd/system/judo-api.service"

quitar_servicio() {
    if [[ "$SISTEMA" == "Darwin" ]]; then
        if [[ -f "$PLIST_LAUNCHD" ]]; then
            hacer_callado sudo launchctl bootout system/es.judo.api
            hacer sudo rm -f "$PLIST_LAUNCHD"
            resultado "servicio launchd es.judo.api quitado"
        else
            igual "no había servicio launchd instalado"
        fi
        return
    fi

    if [[ -f "$UNIDAD_SYSTEMD" ]]; then
        # disable además de stop: sin él el servicio volvería a arrancar al encender el equipo,
        # buscando una carpeta que este mismo guion está a punto de borrar.
        hacer_callado sudo systemctl stop judo-api
        hacer_callado sudo systemctl disable judo-api
        hacer sudo rm -f "$UNIDAD_SYSTEMD"
        hacer_callado sudo systemctl daemon-reload
        resultado "servicio systemd judo-api quitado"
    else
        igual "no había servicio systemd instalado"
    fi
}

# Lo que queda escuchando aunque no fuera un servicio del sistema: la API se puede haber lanzado
# desde el botón de la aplicación de escritorio, y entonces es un proceso suelto.
parar_lo_que_escuche() {
    local pids
    pids="$(lsof -ti "tcp:$PUERTO" -sTCP:LISTEN 2>/dev/null || true)"

    [[ -z "$pids" ]] && return 0

    hacer_callado sudo kill $pids
    resultado "parado lo que quedaba escuchando en el puerto $PUERTO"
}

volcar_base_datos() {
    local destino="$HOGAR/judo-volcado-antes-de-desinstalar-$(date +%Y%m%d-%H%M%S).dump"

    if ! command -v pg_dump >/dev/null; then
        aviso "no encuentro pg_dump: NO hay volcado, y la base de datos se va a borrar igual"
        return 0
    fi

    if [[ "$EXISTE_BD" != "1" ]]; then
        igual "la base de datos \"$BD\" no existe: no hay nada que volcar"
        return 0
    fi

    if [[ $SIMULAR -eq 1 ]]; then
        echo "   ${AMARILLO}[simulado]${FIN} volcaría \"$BD\" en $destino"
        return 0
    fi

    # Con el superusuario y no con judo_owner: su contraseña no está escrita en ninguna parte, y
    # aquí ya da igual quién sea el dueño porque el siguiente paso borra la base entera.
    if psql_super -d postgres -tAc 'SELECT 1' >/dev/null 2>&1 \
       && pg_dump_super "$BD" "$destino"; then
        [[ -n "${SUDO_USER:-}" ]] && sudo chown "$SUDO_USER" "$destino" 2>/dev/null || true
        chmod 600 "$destino" 2>/dev/null || true
        bien "volcado en $destino"
        VOLCADO="$destino"
    else
        aviso "el volcado ha fallado. La base de datos se va a borrar de todos modos (--deshacer)"
    fi
}

# pg_dump por la misma vía que psql: en Linux con autenticación peer hay que ir como el usuario del
# sistema, y en Homebrew basta el usuario que ha iniciado sesión.
pg_dump_super() {
    case "$MODO_PSQL" in
        usuario) pg_dump -U "$SUPERUSUARIO" -Fc -f "$2" "$1" ;;
        sudo)    sudo -u "$SUPERUSUARIO" pg_dump -Fc -f "$2" "$1" ;;
        local)   pg_dump -Fc -f "$2" "$1" ;;
    esac
}

borrar_base_datos() {
    if [[ "$EXISTE_BD" == "1" ]]; then
        # Las sesiones abiertas impiden el DROP DATABASE, y en un servidor que se retira siempre
        # queda alguna: la propia API acaba de morir pero PostgreSQL tarda en enterarse.
        hacer_callado psql_super -d postgres -c \
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$BD' AND pid <> pg_backend_pid();"
        hacer_callado psql_super -d postgres -c "DROP DATABASE IF EXISTS \"$BD\";"
        resultado "base de datos \"$BD\" borrada"
    else
        igual "la base de datos \"$BD\" no existía"
    fi

    # Los roles, después de la base: mientras son dueños de algo, PostgreSQL no los deja caer.
    local rol
    for rol in judo_api judo_owner; do
        if [[ "$(psql_super -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$rol';")" == "1" ]]; then
            if hacer_callado psql_super -d postgres -c "DROP ROLE IF EXISTS $rol;"; then
                resultado "rol $rol borrado"
            else
                aviso "no he podido borrar el rol $rol: aún es dueño de algo en otra base de datos"
            fi
        else
            igual "el rol $rol no existía"
        fi
    done
}

# Cuántas bases de datos quedan que NO sean de PostgreSQL ni de esta aplicación. Es lo que decide si
# se puede desinstalar el gestor: en un equipo que ya lo tenía puesto —un portátil de trabajo, por
# ejemplo—, desinstalarlo se llevaría datos que no son de aquí.
otras_bases_de_datos() {
    local cuenta
    cuenta="$(psql_super -d postgres -tAc \
        "SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname NOT IN ('postgres', '$BD');" \
        2>/dev/null)"

    # Una respuesta vacía es "no lo sé", no "ninguna": ante la duda no se desinstala nada.
    [[ "$cuenta" =~ ^[0-9]+$ ]] && echo "$cuenta" || echo "desconocido"
}

desinstalar_postgresql() {
    local otras; otras="$(otras_bases_de_datos)"

    if [[ "$otras" == "desconocido" ]]; then
        aviso "no he podido comprobar si hay otras bases de datos: NO desinstalo PostgreSQL"
        return 0
    fi

    if [[ "$otras" -gt 0 ]]; then
        aviso "en este clúster quedan $otras bases de datos que no son de esta aplicación:"
        psql_super -d postgres -tAc \
            "SELECT '     · ' || datname FROM pg_database WHERE NOT datistemplate AND datname NOT IN ('postgres', '$BD');" \
            2>/dev/null || true
        aviso "PostgreSQL se queda instalado. Desinstalarlo se llevaría esos datos por delante."
        return 0
    fi

    if [[ "$SISTEMA" == "Darwin" ]]; then
        command -v brew >/dev/null || { aviso "no hay Homebrew: desinstala PostgreSQL a mano"; return 0; }

        local formula
        formula="$(brew list --formula 2>/dev/null | grep '^postgresql@' | sort -t@ -k2 -n | tail -1 || true)"

        if [[ -z "$formula" ]]; then
            aviso "PostgreSQL no lo puso Homebrew: desinstálalo por donde lo instalaste"
            return 0
        fi

        hacer_callado brew services stop "$formula"
        hacer brew uninstall "$formula"
        resultado "$formula desinstalado"

    elif command -v apt-get >/dev/null; then
        # Los paquetes concretos que hay puestos, y no un comodín: "apt-get purge postgresql*" en un
        # equipo con otras cosas instaladas es exactamente el tipo de orden que se lleva lo que no
        # debe.
        local paquetes
        paquetes="$(dpkg-query -W -f='${Package} ${Status}\n' 'postgresql*' 2>/dev/null \
                    | awk '$NF == "installed" { print $1 }' | tr '\n' ' ' || true)"

        if [[ -z "${paquetes// /}" ]]; then
            aviso "no hay paquetes de PostgreSQL instalados con apt: desinstálalo por donde lo instalaste"
            return 0
        fi

        hacer_callado sudo systemctl stop postgresql
        # purge y no remove: remove deja la configuración y el clúster, o sea justo lo que se quiere
        # quitar. Los datos ya están volcados en el paso 2.
        hacer sudo apt-get purge -y $paquetes
        hacer sudo apt-get autoremove -y
        resultado "PostgreSQL desinstalado ($paquetes)"

    elif command -v dnf >/dev/null; then
        hacer_callado sudo systemctl stop postgresql
        hacer sudo dnf remove -y postgresql-server postgresql-contrib
        resultado "PostgreSQL desinstalado"
    else
        aviso "no sé desinstalar PostgreSQL en este sistema: hazlo a mano"
    fi
}

quitar_certificado() {
    if [[ "$SISTEMA" == "Darwin" ]]; then
        if security find-certificate -c "$NOMBRE_SERVIDOR" /Library/Keychains/System.keychain \
           >/dev/null 2>&1; then
            hacer_callado sudo security delete-certificate -c "$NOMBRE_SERVIDOR" \
                 /Library/Keychains/System.keychain
            resultado "certificado de $NOMBRE_SERVIDOR retirado del llavero del sistema"
        else
            igual "el certificado de $NOMBRE_SERVIDOR no estaba en el llavero"
        fi
        return
    fi

    local instalado=""
    [[ -f "/usr/local/share/ca-certificates/$NOMBRE_SERVIDOR.crt" ]] \
        && instalado="/usr/local/share/ca-certificates/$NOMBRE_SERVIDOR.crt"
    [[ -f "/etc/pki/ca-trust/source/anchors/$NOMBRE_SERVIDOR.crt" ]] \
        && instalado="/etc/pki/ca-trust/source/anchors/$NOMBRE_SERVIDOR.crt"

    if [[ -z "$instalado" ]]; then
        igual "el certificado de $NOMBRE_SERVIDOR no estaba en el almacén del sistema"
        return
    fi

    hacer sudo rm -f "$instalado"

    if command -v update-ca-certificates >/dev/null; then
        # --fresh: sin él, update-ca-certificates añade pero no retira, y el certificado seguiría
        # siendo de confianza aunque su archivo ya no esté.
        hacer_callado sudo update-ca-certificates --fresh
    elif command -v update-ca-trust >/dev/null; then
        hacer_callado sudo update-ca-trust
    fi

    resultado "certificado de $NOMBRE_SERVIDOR retirado del almacén del sistema"
}

quitar_hosts() {
    if ! grep -q "$MARCA_HOSTS" "$HOSTS" 2>/dev/null; then
        igual "no había ninguna línea de JudoAdministración en $HOSTS"
        return
    fi

    if [[ $SIMULAR -eq 1 ]]; then
        echo "   ${AMARILLO}[simulado]${FIN} quitaría de $HOSTS las líneas marcadas con $MARCA_HOSTS"
        return
    fi

    local temporal; temporal="$(mktemp)"
    grep -v "$MARCA_HOSTS" "$HOSTS" > "$temporal" || true
    # cat y no mv, igual que en preparar-puesto: así /etc/hosts conserva su dueño y sus permisos.
    sudo cp "$temporal" "$HOSTS.judo-anterior" 2>/dev/null || true
    cat "$temporal" | sudo tee "$HOSTS" >/dev/null
    rm -f "$temporal"
    sudo rm -f "$HOSTS.judo-anterior" 2>/dev/null || true
    bien "línea de $NOMBRE_SERVIDOR quitada de $HOSTS"
}

quitar_cortafuegos() {
    if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
        hacer_callado sudo ufw delete allow proto tcp from "$SUBRED" to any port "$PUERTO"
        hacer_callado sudo ufw delete deny 5432/tcp
        resultado "reglas de ufw quitadas"
        return
    fi

    if command -v firewall-cmd >/dev/null && sudo firewall-cmd --state >/dev/null 2>&1; then
        hacer_callado sudo firewall-cmd --permanent --remove-rich-rule \
            "rule family=ipv4 source address=$SUBRED port port=$PUERTO protocol=tcp accept"
        hacer_callado sudo firewall-cmd --permanent --remove-rich-rule \
            "rule family=ipv4 port port=5432 protocol=tcp drop"
        hacer_callado sudo firewall-cmd --reload
        resultado "reglas de firewalld quitadas"
        return
    fi

    igual "no hay cortafuegos activo que tocar"
}

borrar_carpetas() {
    local carpeta
    for carpeta in "$DIR_SERVICIO" "$DIR_SERVICIO.anterior" "$DIR_SERVICIO.nuevo" \
                   "/opt/judoadministracion-copias"
    do
        if [[ -d "$carpeta" ]]; then
            hacer sudo rm -rf "$carpeta"
            resultado "borrada $carpeta"
        else
            igual "no existe $carpeta"
        fi
    done
}

# La configuración de la aplicación de escritorio de ESTE equipo apunta a un servicio que ya no
# existe. Se quita solo si la escribió la instalación: si alguien la ha tocado a mano, es suya.
# Los mismos sitios que mira buscar_aplicacion, que está definida más abajo en el guion y por tanto
# no existe todavía cuando corre este bloque.
localizar_aplicacion() {
    [[ -n "$DIR_APP" ]] && return 0
    local candidata
    for candidata in \
        "/Applications/JudoAdministracion.app/Contents/MacOS" \
        "/opt/judoadministracion" \
        "$HOGAR/Applications/JudoAdministracion.app/Contents/MacOS"
    do
        if [[ -x "$candidata/JudoAdministracion" ]]; then DIR_APP="$candidata"; return 0; fi
    done
    return 1
}

quitar_config_aplicacion() {
    if [[ -z "$DIR_APP" ]] || [[ ! -f "$DIR_APP/appsettings.Local.json" ]]; then
        igual "no hay configuración de la aplicación de escritorio que quitar"
        return
    fi

    if grep -q 'preparar-servidor' "$DIR_APP/appsettings.Local.json" 2>/dev/null; then
        hacer sudo rm -f "$DIR_APP/appsettings.Local.json"
        resultado "appsettings.Local.json de la aplicación eliminado"
    else
        aviso "hay un appsettings.Local.json que no escribió este guion: no lo toco"
        aviso "  $DIR_APP/appsettings.Local.json"
    fi
}

if [[ $DESHACER -eq 1 ]]; then
    # set +e para todo el bloque, al contrario que el resto del guion.
    #
    # Instalar a medias es peor que no instalar, y de ahí el set -e de arriba. Desinstalar es lo
    # contrario: si no se puede quitar una regla del cortafuegos, lo que hay que hacer es seguir
    # quitando el resto y decir qué ha quedado, no abortar y dejar el equipo a mitad de camino con
    # un servicio apuntando a una carpeta que ya no existe.
    set +e

    echo
    echo "${AZUL}Desinstalar el servidor de JudoAdministración de este equipo${FIN}"
    echo "   base       $BD"
    echo "   carpeta    $DIR_SERVICIO"
    echo "   servidor   $NOMBRE_SERVIDOR, puerto $PUERTO"
    echo
    if [[ $SIN_BASE_DATOS -eq 1 ]]; then
        aviso "se conservan la base de datos, los roles y PostgreSQL (--sin-base-datos)"
    else
        echo "   ${ROJO}Se va a BORRAR la base de datos \"$BD\", sus roles y PostgreSQL.${FIN}"
        echo "   ${ROJO}Antes se saca un volcado al home, y es lo único que quedará.${FIN}"
    fi
    [[ $SIMULAR -eq 1 ]] && aviso "modo simulación: no se cambia nada"
    echo

    confirmar "¿Sigo?" || { echo "   Cancelado."; exit 0; }

    # Fuera de la carpeta que se va a borrar, por si el guion se está ejecutando desde dentro (es lo
    # normal: viene dentro del paquete del servicio).
    cd / || true

    paso "1/8  El servicio"
    quitar_servicio
    parar_lo_que_escuche

    if [[ $SIN_BASE_DATOS -eq 1 ]]; then
        paso "2/8  Base de datos"
        igual "se conserva (--sin-base-datos)"
        paso "3/8  PostgreSQL"
        igual "se conserva (--sin-base-datos)"
    else
        if resolver_psql; then
            EXISTE_BD="$(psql_super -d postgres -tAc \
                "SELECT 1 FROM pg_database WHERE datname = '$BD';" 2>/dev/null || true)"

            paso "2/8  Volcado y borrado de la base de datos"
            volcar_base_datos
            borrar_base_datos

            paso "3/8  PostgreSQL"
            desinstalar_postgresql
        else
            paso "2/8  Base de datos"
            aviso "PostgreSQL no responde, así que no puedo volcarla ni borrarla."
            aviso "  Si el gestor vuelve a arrancar, la base \"$BD\" seguirá ahí."
            paso "3/8  PostgreSQL"
            igual "no responde: no lo toco"
        fi
    fi

    paso "4/8  Certificado del almacén de confianza"
    quitar_certificado

    paso "5/8  Archivo hosts"
    quitar_hosts

    paso "6/8  Cortafuegos"
    quitar_cortafuegos

    paso "7/8  Configuración de la aplicación de escritorio"
    localizar_aplicacion >/dev/null 2>&1
    quitar_config_aplicacion

    paso "8/8  Carpetas"
    borrar_carpetas

    echo
    if [[ $SIMULAR -eq 1 ]]; then
        echo "${AMARILLO}Simulación terminada. No se ha cambiado nada.${FIN}"
        echo "   Quita --simular para hacerlo de verdad."
    else
        echo "${VERDE}Este equipo ya no es el servidor de JudoAdministración.${FIN}"
        [[ -n "${VOLCADO:-}" ]] && echo "   El volcado de la base de datos está en:  $VOLCADO"
        echo
        echo "   La aplicación de escritorio sigue instalada; se desinstala como cualquier"
        echo "   otro programa."
        echo
        echo "   ${AMARILLO}Falta devolver la red, que es lo que le importa a quien use este equipo:${FIN}"
        echo "     sudo configurar-red.sh --deshacer"
    fi
    echo
    exit 0
fi


echo
echo "${AZUL}Preparación del servidor de JudoAdministración${FIN}"
echo "   servidor   $NOMBRE_SERVIDOR ($IP_SERVIDOR), puerto $PUERTO"
echo "   base       $BD"
echo "   carpeta    $DIR_SERVICIO"

# ── 1. Comprobaciones previas ─────────────────────────────────────────────────────────────────────

paso "1/10  Comprobaciones previas"

for herramienta in openssl curl; do
    command -v "$herramienta" >/dev/null || fallo "Falta $herramienta."
done
bien "openssl y curl disponibles"

[[ -n "$SQL_ROLES" ]] || fallo "No encuentro Despliegue/01_roles.sql.
     Debería estar junto a este guion (viene en el paquete api-<sistema>) o en
     JudoAdministracion.Api/Despliegue/ si lo ejecutas desde el repositorio."
bien "guion de roles localizado en $SQL_ROLES"

if [[ ! -x "$BINARIO" ]]; then
    fallo "No encuentro el servicio en $DIR_SERVICIO.
     Descomprime ahí el paquete api-<sistema> (Documentación/00) y vuelve a ejecutar,
     o indica otra carpeta con --dir."
fi
bien "servicio encontrado en $DIR_SERVICIO"

# La aplicación de escritorio busca el servicio en /opt/judoadministracion-api por defecto para
# arrancarlo ella sola (Services/Servidor/ServicioApiLocal.LocalizarBinario; ver doc 00, §8.1). Si
# el paquete se ha descomprimido en otro sitio, mejor pararse aquí que descubrirlo el día del
# campeonato, cuando la aplicación no encuentre el servicio sola.
RUTA_RECOMENDADA="/opt/judoadministracion-api"
RUTA_ACTUAL="$(cd "$DIR_SERVICIO" && pwd)"
if [[ "$RUTA_ACTUAL" != "$RUTA_RECOMENDADA" ]]; then
    fallo "Esta carpeta es $RUTA_ACTUAL y debería ser $RUTA_RECOMENDADA (doc 00, §8.1).
     Mueve ahí el paquete descomprimido y vuelve a ejecutar el guion."
fi

# ¿Podemos escribir en la carpeta del servicio, o hará falta sudo para cada archivo?
if [[ -w "$DIR_SERVICIO" ]]; then
    bien "la carpeta es escribible sin sudo"
else
    NECESITA_ROOT=1
    aviso "la carpeta necesita sudo; se pedirá la contraseña"
    sudo -v
fi

# ¿Es un servidor nuevo o uno ya configurado? Se decide aquí, antes de tocar la base de datos, porque
# de ello depende algo que no se puede deshacer a medias: si ya hay un appsettings.Local.json escrito,
# las contraseñas de los roles NO se pueden cambiar. Ese archivo lleva la de judo_api, y rotarla
# dejaría al servicio sin poder autenticarse —con el añadido de que la de judo_owner no está escrita
# en ninguna parte, así que tampoco habría con qué recomponerlo—.
CONSERVAR_CONFIG=0
if [[ -f "$CONFIG" && $FORZAR_CONFIGURACION -eq 0 ]]; then
    CONSERVAR_CONFIG=1
    igual "hay configuración previa: se conservará, contraseñas incluidas"

    # De esa configuración se puede recuperar lo que hace falta para los pasos que vienen después
    # —configurar la aplicación de escritorio, sobre todo—, así que una segunda ejecución sirve
    # para completar un servidor a medias en vez de quedarse a la mitad.
    CADENA_EXISTENTE="$(leer_json "$CONFIG" ConnectionString || true)"
    if [[ "$CADENA_EXISTENTE" == *"Username=judo_api;"* ]]; then
        CLAVE_API="${CADENA_EXISTENTE##*Password=}"
        bien "contraseña de judo_api recuperada de la configuración existente"
    fi
else
    bien "servidor nuevo: se generará la configuración"
fi

# ── 2. PostgreSQL ─────────────────────────────────────────────────────────────────────────────────

paso "2/10  PostgreSQL"

instalar_postgresql() {
    if [[ "$SISTEMA" == "Darwin" ]]; then
        command -v brew >/dev/null || fallo "No hay Homebrew. Instala PostgreSQL a mano (guía §3.1)."
        brew install postgresql@18
        brew services start postgresql@18
        aviso "añade a tu perfil: export PATH=\"\$(brew --prefix)/opt/postgresql@18/bin:\$PATH\""
        export PATH="$(brew --prefix)/opt/postgresql@18/bin:$PATH"
    elif command -v apt-get >/dev/null; then
        sudo apt-get update
        # postgresql-contrib NO es opcional: trae unaccent y pgcrypto.
        sudo apt-get install -y postgresql postgresql-contrib
        sudo systemctl enable --now postgresql
    elif command -v dnf >/dev/null; then
        sudo dnf install -y postgresql-server postgresql-contrib
        sudo postgresql-setup --initdb || true
        sudo systemctl enable --now postgresql
    else
        fallo "No sé instalar PostgreSQL en este sistema. Hazlo a mano (guía §3.1)."
    fi
}

if ! command -v psql >/dev/null; then
    if [[ $SIN_POSTGRESQL -eq 1 ]]; then
        fallo "PostgreSQL no está instalado y se ha pedido --sin-postgresql. Instálalo a mano (guía §3.1)."
    fi
    aviso "PostgreSQL no está instalado; instalando"
    instalar_postgresql
fi

resolver_psql || fallo "PostgreSQL está instalado pero no responde.
     Comprueba que el servicio está arrancado:
       Linux  → sudo systemctl status postgresql
       macOS  → brew services list"

VERSION_PG="$(psql_super -d postgres -tAc 'SHOW server_version;' | cut -d. -f1)"
bien "PostgreSQL $VERSION_PG en marcha (psql: modo $MODO_PSQL)"

if [[ "$VERSION_PG" -lt 13 ]]; then
    aviso "versión anterior a la 13: las extensiones las creará el superusuario (ya se hace así)"
fi

# ── 3. Base de datos ──────────────────────────────────────────────────────────────────────────────

paso "3/10  Base de datos \"$BD\""

EXISTE_BD="$(psql_super -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$BD';")"

if [[ "$EXISTE_BD" == "1" ]]; then
    igual "ya existe, no se toca"
else
    # Las comillas dobles son imprescindibles: sin ellas PostgreSQL pasa el nombre a minúsculas y la
    # cadena de conexión de la aplicación, que pide "JudoAdministracion", no la encontraría.
    psql_super -d postgres -c "CREATE DATABASE \"$BD\" ENCODING 'UTF8' TEMPLATE template0;"
    bien "creada con codificación UTF8"
fi

CODIFICACION="$(psql_super -d postgres -tAc \
    "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = '$BD';")"
[[ "$CODIFICACION" == "UTF8" ]] || fallo "La base de datos está en $CODIFICACION y debe estar en UTF8."
bien "codificación UTF8"

# La ordenación decide cómo se listan los apellidos. Con "C", los acentuados se van todos al final.
ORDEN="$(psql_super -d "$BD" -tAc \
    "SELECT string_agg(x, ' < ' ORDER BY x) FROM (VALUES ('Ávila'),('Alicante'),('Zamora'),('Ñuño')) t(x);")"
if [[ "$ORDEN" == "Alicante < Ávila < Ñuño < Zamora" ]]; then
    bien "ordenación correcta para castellano"
else
    aviso "ordenación dudosa: $ORDEN"
    aviso "los listados saldrán con los acentos fuera de sitio (guía §3.2)"
fi

# ── 4. Roles y extensiones ────────────────────────────────────────────────────────────────────────

paso "4/10  Roles y extensiones"

YA_HABIA_ROLES="$(psql_super -d postgres -tAc \
    "SELECT count(*) FROM pg_roles WHERE rolname IN ('judo_owner','judo_api');")"

if [[ $CONSERVAR_CONFIG -eq 1 ]]; then
    # Roles y permisos sí, contraseñas no: las que hay son las que conoce la configuración existente.
    psql_super -q -d "$BD" -v rotar_claves=off -v bd="$BD" -f "$SQL_ROLES"
    bien "roles comprobados y permisos repuestos (contraseñas sin tocar)"
else
    [[ -n "$CLAVE_OWNER" ]] || CLAVE_OWNER="$(generar_clave)"
    [[ -n "$CLAVE_API"   ]] || CLAVE_API="$(generar_clave)"

    psql_super -q -d "$BD" \
        -v clave_owner="$CLAVE_OWNER" \
        -v clave_api="$CLAVE_API" \
        -v bd="$BD" \
        -f "$SQL_ROLES"

    if [[ "$YA_HABIA_ROLES" == "2" ]]; then
        bien "judo_owner y judo_api ya existían: contraseñas y permisos repuestos"
    else
        bien "judo_owner y judo_api creados"
    fi
fi

# Objetos que ya estaban ahí y no son de judo_owner.
#
# Pasa siempre que se reutiliza una base de datos de desarrollo: las tablas las creó la cuenta
# personal, y aunque el paso 3 ponga la BASE a nombre de judo_owner, los objetos de dentro siguen
# siendo del otro. El primer arranque del paso 7 se cae entonces con un error que no dice de dónde
# viene:
#
#     SqlState: 42501   MessageText: must be owner of table paises
#
# Reasignarlos NO toca los datos, sólo quién consta como dueño. Y se hace objeto a objeto y no con
# REASSIGN OWNED, que además de la base actual arrastra los objetos COMPARTIDOS del clúster: si la
# cuenta personal es superusuario, se llevaría por delante la propiedad de postgres, template0 y
# template1.
AJENOS="$(psql_super -d "$BD" -tAc "
    SELECT count(*) FROM (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind IN ('r','p','S','v','m','f')
           AND c.relowner <> 'judo_owner'::regrole
        UNION ALL
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proowner <> 'judo_owner'::regrole
    ) t;")"

if [[ "${AJENOS:-0}" -gt 0 ]]; then
    psql_super -q -d "$BD" <<'SQL'
BEGIN;
ALTER SCHEMA public OWNER TO judo_owner;

DO $$
DECLARE r record;
BEGIN
    -- Tablas y vistas primero: las secuencias de columnas serial cambian de dueño con su tabla y
    -- no se pueden cambiar por separado ("cannot change owner of sequence ... is linked to table").
    FOR r IN SELECT c.oid::regclass AS obj, c.relkind AS k
             FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
             WHERE ns.nspname = 'public' AND c.relowner <> 'judo_owner'::regrole
               AND c.relkind IN ('r','p','v','m','f')
    LOOP
        EXECUTE format(CASE r.k
            WHEN 'v' THEN 'ALTER VIEW %s OWNER TO judo_owner'
            WHEN 'm' THEN 'ALTER MATERIALIZED VIEW %s OWNER TO judo_owner'
            ELSE            'ALTER TABLE %s OWNER TO judo_owner' END, r.obj);
    END LOOP;

    -- Y ahora las secuencias que hayan quedado sueltas, sin tabla que las arrastre.
    FOR r IN SELECT c.oid::regclass AS obj
             FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
             WHERE ns.nspname = 'public' AND c.relkind = 'S'
               AND c.relowner <> 'judo_owner'::regrole
               AND NOT EXISTS (SELECT 1 FROM pg_depend d
                               WHERE d.objid = c.oid AND d.deptype IN ('a','i'))
    LOOP
        EXECUTE format('ALTER SEQUENCE %s OWNER TO judo_owner', r.obj);
    END LOOP;

    FOR r IN SELECT p.oid::regprocedure AS obj, p.prokind AS k
             FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
             WHERE ns.nspname = 'public' AND p.proowner <> 'judo_owner'::regrole
    LOOP
        EXECUTE format(CASE r.k
            WHEN 'p' THEN 'ALTER PROCEDURE %s OWNER TO judo_owner'
            WHEN 'a' THEN 'ALTER AGGREGATE %s OWNER TO judo_owner'
            ELSE            'ALTER FUNCTION %s OWNER TO judo_owner' END, r.obj);
    END LOOP;
END $$;
COMMIT;
SQL
    bien "$AJENOS objetos que eran de otra cuenta pasan a judo_owner (los datos no se tocan)"
else
    bien "todo el esquema es de judo_owner"
fi

EXTENSIONES="$(psql_super -d "$BD" -tAc \
    "SELECT string_agg(extname, ', ' ORDER BY extname) FROM pg_extension WHERE extname IN ('unaccent','pgcrypto');")"
[[ "$EXTENSIONES" == "pgcrypto, unaccent" ]] || fallo "Faltan extensiones ($EXTENSIONES).
     En Linux suele ser que falta el paquete postgresql-contrib (guía §3.1)."
bien "extensiones unaccent y pgcrypto instaladas"

# ── 5. Certificado HTTPS ──────────────────────────────────────────────────────────────────────────

paso "5/10  Certificado HTTPS"

if [[ $REGENERAR_CERTIFICADO -eq 1 && $CONSERVAR_CONFIG -eq 1 ]]; then
    fallo "--regenerar-certificado cambia la contraseña del .pfx, y la configuración existente
     se quedaría con la vieja. Añade --forzar-configuracion para reescribir las dos cosas
     (ojo: eso cierra las sesiones abiertas), o pasa --clave-pfx con la contraseña actual."
fi

if [[ -f "$PFX" && $REGENERAR_CERTIFICADO -eq 0 ]]; then
    igual "$(basename "$PFX") ya existe, no se regenera (--regenerar-certificado para rehacerlo)"
    if [[ -z "$CLAVE_PFX" ]]; then
        # La contraseña del .pfx existente no se puede deducir; sin ella no se puede reescribir la
        # configuración, así que se conserva la que ya hubiera.
        aviso "no conozco su contraseña: la configuración conservará la que ya tenga"
    fi
else
    [[ -n "$CLAVE_PFX" ]] || CLAVE_PFX="$(generar_clave)"

    TEMPORAL="$(mktemp -d)"
    # Todos los nombres por los que se puede llegar al servidor. Si falta uno, el cliente que use
    # ese nombre rechaza la conexión: judo-server para los puestos, localhost para el anfitrión.
    cat > "$TEMPORAL/san.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[dn]
CN = $NOMBRE_SERVIDOR
[ext]
subjectAltName   = DNS:$NOMBRE_SERVIDOR, DNS:localhost, IP:$IP_SERVIDOR, IP:127.0.0.1
basicConstraints = critical, CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
CNF

    openssl req -x509 -newkey rsa:2048 -sha256 -days 1825 -nodes \
        -keyout "$TEMPORAL/servidor.key" -out "$TEMPORAL/servidor.crt" \
        -config "$TEMPORAL/san.cnf" 2>/dev/null

    openssl pkcs12 -export -out "$TEMPORAL/servidor.pfx" \
        -inkey "$TEMPORAL/servidor.key" -in "$TEMPORAL/servidor.crt" \
        -passout pass:"$CLAVE_PFX" 2>/dev/null

    escribir "$KEY" < "$TEMPORAL/servidor.key"
    escribir "$CRT" < "$TEMPORAL/servidor.crt"
    escribir "$PFX" < "$TEMPORAL/servidor.pfx"
    # La clave privada y el .pfx no los debe leer nadie más que el servicio.
    permisos 600 "$KEY" "$PFX"
    permisos 644 "$CRT"
    rm -rf "$TEMPORAL"

    bien "certificado emitido para $NOMBRE_SERVIDOR, localhost, $IP_SERVIDOR y 127.0.0.1"
    bien "válido 5 años"
fi

# Este equipo confía en su propio certificado salvo que se diga lo contrario. Hace falta siempre que
# aquí vaya a correr también la aplicación de escritorio —el caso normal, el anfitrión—, y no
# estorba cuando no: es un certificado emitido en esta misma máquina hace un momento.
if [[ $SIN_CONFIANZA -eq 1 ]]; then
    aviso "certificado sin instalar como raíz de confianza (--sin-confianza)"
    aviso "si este equipo ejecuta la aplicación, no podrá conectarse a su propio servidor"
elif [[ "$SISTEMA" == "Darwin" ]]; then
    sudo security add-trusted-cert -d -r trustRoot \
         -k /Library/Keychains/System.keychain "$CRT"
    bien "certificado instalado en el llavero del sistema"
elif [[ -d /usr/local/share/ca-certificates ]]; then
    sudo cp "$CRT" "/usr/local/share/ca-certificates/$NOMBRE_SERVIDOR.crt"
    sudo update-ca-certificates >/dev/null
    bien "certificado instalado en el almacén del sistema"
elif [[ -d /etc/pki/ca-trust/source/anchors ]]; then
    sudo cp "$CRT" "/etc/pki/ca-trust/source/anchors/$NOMBRE_SERVIDOR.crt"
    sudo update-ca-trust
    bien "certificado instalado en el almacén del sistema"
else
    aviso "no sé dónde instalar certificados en este sistema; hazlo a mano (guía §4.2)"
fi

# ── 6. Configuración del servicio ─────────────────────────────────────────────────────────────────

paso "6/10  Configuración del servicio"

escribir_configuracion() {                          # escribir_configuracion <usuario> <clave> <inicializar>
    escribir "$CONFIG" <<JSON
{
    "//": [
        "Generado por preparar-servidor.sh.",
        "Configuración REAL de este equipo: contraseña de la base de datos y clave de firma de",
        "tokens. No se sube a git y no la incluye ningún instalador.",
        "Ver Documentación/01-Guía-de-Instalación.md, §3.5."
    ],
    "Servidor": {
        "Url": "https://0.0.0.0:$PUERTO",
        "CertificadoPfx": "$(basename "$PFX")",
        "CertificadoPassword": "$CLAVE_PFX",
        "ConnectionString": "Host=localhost;Port=5432;Database=$BD;Username=$1;Password=$2",
        "ClaveFirmaTokens": "$CLAVE_TOKENS",
        "HorasValidezToken": 16,
        "IpsAnfitrion": [],
        "InicializarBaseDeDatos": $3
    }
}
JSON
    permisos 600 "$CONFIG"
}

if [[ $CONSERVAR_CONFIG -eq 1 ]]; then
    igual "appsettings.Local.json ya existe, se conserva (--forzar-configuracion para reescribirlo)"
    aviso "la clave de firma de tokens NO se toca: cambiarla cerraría todas las sesiones abiertas"
else
    if [[ -z "${CLAVE_PFX:-}" ]]; then
        fallo "No puedo escribir la configuración sin la contraseña del certificado.
     Usa --clave-pfx <contraseña> o --regenerar-certificado."
    fi
    # Larga y estable: si cambia entre reinicios, todas las sesiones abiertas dejan de valer y hay
    # que volver a entrar en los cinco puestos.
    CLAVE_TOKENS="$(openssl rand -base64 48 | tr -d '\n')"
    escribir_configuracion judo_owner "$CLAVE_OWNER" true
    bien "escrita con el rol judo_owner, para crear el esquema en el primer arranque"
fi

# ── 7. Esquema, datos básicos y disparadores ───────────────────────────────────────────────────────

paso "7/10  Esquema y datos básicos"

if [[ $SIN_ESQUEMA -eq 1 ]]; then
    aviso "omitido por --sin-esquema"
elif [[ $CONSERVAR_CONFIG -eq 1 ]]; then
    igual "se conserva la configuración existente: no se relanza la inicialización"
    aviso "si esta es una actualización con cambios de esquema, sigue la guía §7"
else
    # Si algo ocupa ya el puerto, el servicio que vamos a lanzar no podrá escuchar y la espera de
    # abajo acabaría en un "no llegó a responder" que no dice cuál es el problema. El caso típico es
    # tener el servicio ya instalado y en marcha de una ejecución anterior.
    if command -v lsof >/dev/null && lsof -nP -iTCP:"$PUERTO" -sTCP:LISTEN >/dev/null 2>&1; then
        fallo "Ya hay algo escuchando en el puerto $PUERTO. Párala antes de inicializar:
       Linux  → sudo systemctl stop judo-api
       macOS  → sudo launchctl bootout system/es.judo.api
     Y si es un proceso lanzado a mano:
       pkill -f JudoAdministracion.Api"
    fi

    TABLAS_ANTES="$(psql_super -d "$BD" -tAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")"

    # El primer arranque es el que crea las tablas, las funciones de sorteo y propagación, los
    # disparadores de tiempo real y siembra los datos básicos. Se lanza aquí, se espera a que
    # responda y se para: así el técnico no tiene que hacer el baile a mano.
    echo "   arrancando el servicio para inicializar (puede tardar unos segundos)…"
    REGISTRO="$(mktemp)"

    # Con la ruta absoluta y exec: absoluta para que pkill -f lo encuentre después, y exec para que
    # $! sea el proceso del servicio y no el del subshell que lo lanza.
    if [[ $NECESITA_ROOT -eq 1 ]]; then
        sudo bash -c "cd '$DIR_SERVICIO' && exec '$BINARIO'" > "$REGISTRO" 2>&1 &
    else
        ( cd "$DIR_SERVICIO" && exec "$BINARIO" ) > "$REGISTRO" 2>&1 &
    fi
    PID_LANZADO=$!

    # Si el guion aborta a partir de aquí, el servicio no debe quedarse suelto en segundo plano.
    detener_inicializacion() {
        como_root pkill -f "$BINARIO" 2>/dev/null || true
        kill "$PID_LANZADO" 2>/dev/null || true
        wait "$PID_LANZADO" 2>/dev/null || true
    }
    trap detener_inicializacion EXIT

    LISTO=0
    for _ in $(seq 1 40); do
        if curl -sf --cacert "$CRT" "https://localhost:$PUERTO/api/estado" >/dev/null 2>&1; then
            LISTO=1; break
        fi
        # Si el proceso ya ha muerto, no tiene sentido seguir esperando.
        kill -0 "$PID_LANZADO" 2>/dev/null || break
        sleep 1
    done

    detener_inicializacion
    trap - EXIT

    if [[ $LISTO -eq 0 ]]; then
        echo
        echo "${ROJO}El servicio no llegó a responder. Sus últimas líneas:${FIN}"
        tail -20 "$REGISTRO" >&2
        rm -f "$REGISTRO"
        fallo "Inicialización fallida. Los fallos frecuentes están en la guía §10."
    fi
    rm -f "$REGISTRO"

    TABLAS="$(psql_super -d "$BD" -tAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")"
    PAISES="$(psql_super -d "$BD" -tAc "SELECT count(*) FROM paises;")"
    USUARIOS="$(psql_super -d "$BD" -tAc "SELECT count(*) FROM usuarios;")"

    [[ "$TABLAS" -ge 14 ]] || fallo "Solo hay $TABLAS tablas; se esperaban 14 o más."
    [[ "$PAISES" -gt 0  ]] || fallo "La siembra de datos básicos no ha dejado países."

    if [[ "$TABLAS_ANTES" -eq 0 ]]; then
        bien "esquema creado: $TABLAS tablas, $PAISES países, $USUARIOS usuario(s)"
    else
        bien "esquema comprobado: $TABLAS tablas, $PAISES países, $USUARIOS usuario(s)"
    fi

    # Y ahora la configuración definitiva: el rol que solo lee y escribe datos, sin inicialización.
    # Los dos cambios van juntos; con judo_api e inicialización activada, el arranque falla con
    # permiso denegado (guía §3.6).
    escribir_configuracion judo_api "$CLAVE_API" false
    bien "configuración cambiada al rol judo_api, sin inicialización"

    # Que judo_api sea capaz de leer y NO de tocar el esquema es la comprobación que justifica los
    # dos roles; si esto no se cumple, algo se ha concedido de más.
    if PGPASSWORD="$CLAVE_API" psql -h localhost -U judo_api -d "$BD" \
         -tAc "SELECT count(*) FROM eventos;" >/dev/null 2>&1; then
        bien "judo_api puede leer los datos"
    else
        fallo "judo_api no puede leer. Revisa el paso 4."
    fi

    if PGPASSWORD="$CLAVE_API" psql -h localhost -U judo_api -d "$BD" \
         -c "CREATE TABLE comprobacion_permisos (x int);" >/dev/null 2>&1; then
        PGPASSWORD="$CLAVE_API" psql -h localhost -U judo_api -d "$BD" \
            -c "DROP TABLE comprobacion_permisos;" >/dev/null 2>&1 || true
        aviso "judo_api PUEDE crear tablas y no debería. Revisa los permisos del paso 4."
    else
        bien "judo_api no puede alterar el esquema (correcto)"
    fi
fi

# ── 8. La aplicación de escritorio de este equipo ─────────────────────────────────────────────────
#
# Lo normal es que el equipo servidor ejecute también la aplicación: es el ANFITRIÓN, el único desde
# el que se pueden activar eventos (guía §5). Ese papel no se declara en ninguna parte: se lo gana
# conectándose por localhost, así que todo lo que hace falta es que su appsettings.Local.json apunte
# ahí. Escribirlo aquí es lo que evita el paso manual que antes había que recordar.

paso "8/10  Aplicación de escritorio de este equipo"

buscar_aplicacion() {
    [[ -n "$DIR_APP" ]] && return 0
    local candidata
    for candidata in \
        "/Applications/JudoAdministracion.app/Contents/MacOS" \
        "/opt/judoadministracion" \
        "$HOGAR/Applications/JudoAdministracion.app/Contents/MacOS"
    do
        if [[ -x "$candidata/JudoAdministracion" ]]; then DIR_APP="$candidata"; return 0; fi
    done
    return 1
}

CONFIG_APP=""
if [[ $SIN_APLICACION -eq 1 ]]; then
    aviso "omitido por --sin-aplicacion"
elif ! buscar_aplicacion; then
    aviso "la aplicación de escritorio no está instalada en este equipo"
    aviso "si va a estarlo, instálala (guía §4.1) y vuelve a lanzar este guion: se configurará sola"
elif [[ -z "$CLAVE_API" ]]; then
    aviso "no conozco la contraseña de judo_api, así que no puedo escribir su configuración"
    aviso "vuelve a lanzar el guion sobre este mismo servidor y la recuperará de $CONFIG"
else
    CONFIG_APP="$DIR_APP/appsettings.Local.json"

    # ApiBaseUrl con localhost y no con el nombre del servidor: es exactamente lo que le identifica
    # como anfitrión. Y la cadena de conexión va con judo_api, el mismo rol con el que corre el
    # servicio: las pantallas que todavía no han pasado por la API solo hacen consultas y altas, y
    # ninguna toca el esquema, así que no hay motivo para darle judo_owner a un programa de escritorio.
    escribir "$CONFIG_APP" <<JSON
{
    "//": [
        "Generado por preparar-servidor.sh.",
        "Este equipo es el SERVIDOR y a la vez el ANFITRIÓN de la competición.",
        "",
        "ApiBaseUrl con localhost, y no con ${NOMBRE_SERVIDOR}, es lo que le identifica como anfitrión",
        "y le habilita las operaciones que afectan a toda la red, como activar un evento.",
        "",
        "ConnectionString: la usan las pantallas que todavía no han pasado por la API. Va con el rol",
        "judo_api, el mismo con el que corre el servicio. En los puestos de la red va vacía.",
        "",
        "Ver Documentación/01-Guía-de-Instalación.md, §5."
    ],
    "ApiBaseUrl": "https://localhost:$PUERTO",
    "ConnectionString": "Host=localhost;Port=5432;Database=$BD;Username=judo_api;Password=$CLAVE_API",
    "RutaApi": "$DIR_SERVICIO"
}
JSON
    # Legible por la aplicación —que corre con la cuenta de quien la abre— pero no escribible por
    # ella: la configuración de un equipo de competición no debe poder cambiarla quien lo usa.
    permisos 644 "$CONFIG_APP"
    bien "configurada como anfitrión en $DIR_APP"
    bien "apunta a https://localhost:$PUERTO, con acceso directo a la base de datos"
fi

# ── 9. Red de este equipo ─────────────────────────────────────────────────────────────────────────

paso "9/10  Nombre del servidor y cortafuegos"

poner_hosts() {
    if grep -q "$MARCA_HOSTS" "$HOSTS" 2>/dev/null; then
        igual "la línea de $NOMBRE_SERVIDOR ya está en $HOSTS"
        return
    fi
    printf '%s\t%s\t%s\n' "$IP_SERVIDOR" "$NOMBRE_SERVIDOR" "$MARCA_HOSTS" | sudo tee -a "$HOSTS" >/dev/null
    bien "$NOMBRE_SERVIDOR → $IP_SERVIDOR en $HOSTS"
}

# El cortafuegos solo se toca si ya hay uno activo. Activar uno que estaba apagado cambiaría el
# comportamiento del equipo mucho más allá de esta aplicación, y no es lo que nadie espera de un
# guion de instalación.
configurar_cortafuegos() {
    if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
        sudo ufw allow proto tcp from "$SUBRED" to any port "$PUERTO" >/dev/null
        # PostgreSQL solo se usa desde el propio servidor. Un DENY explícito para que quede escrito,
        # aunque de fábrica ya escuche solo en localhost.
        sudo ufw deny 5432/tcp >/dev/null
        bien "ufw: $PUERTO/tcp abierto a $SUBRED, 5432/tcp cerrado"
        return
    fi

    if command -v firewall-cmd >/dev/null && sudo firewall-cmd --state >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --add-rich-rule \
            "rule family=ipv4 source address=$SUBRED port port=$PUERTO protocol=tcp accept" >/dev/null
        sudo firewall-cmd --permanent --add-rich-rule \
            "rule family=ipv4 port port=5432 protocol=tcp drop" >/dev/null
        sudo firewall-cmd --reload >/dev/null
        bien "firewalld: $PUERTO/tcp abierto a $SUBRED, 5432/tcp cerrado"
        return
    fi

    if [[ "$SISTEMA" == "Darwin" ]]; then
        # El cortafuegos de macOS filtra por aplicación y no por puerto, así que no hay regla que
        # poner. Lo que importa —que PostgreSQL no salga a la red— se comprueba aquí abajo.
        igual "macOS filtra por aplicación, no por puerto: no hay regla que añadir"
        return
    fi

    igual "no hay ningún cortafuegos activo en este equipo"
}

if [[ $SIN_HOSTS -eq 1 ]]; then
    igual "archivo hosts sin tocar (--sin-hosts)"
else
    poner_hosts
fi

if [[ $SIN_CORTAFUEGOS -eq 1 ]]; then
    igual "cortafuegos sin tocar (--sin-cortafuegos)"
else
    configurar_cortafuegos
fi

# Que PostgreSQL no escuche en la red es la mitad importante del asunto, y no depende del
# cortafuegos sino de listen_addresses. De fábrica está bien; se comprueba porque una instalación
# heredada puede venir abierta.
ESCUCHA_PG="$(psql_super -d postgres -tAc 'SHOW listen_addresses;' 2>/dev/null || echo '?')"
if [[ "$ESCUCHA_PG" == "localhost" || "$ESCUCHA_PG" == "127.0.0.1" ]]; then
    bien "PostgreSQL escucha solo en local"
else
    aviso "PostgreSQL escucha en \"$ESCUCHA_PG\" y debería hacerlo solo en local (doc 02, §3.4)"
fi

# ── 10. Servicio del sistema y comprobación ───────────────────────────────────────────────────────

paso "10/10  Arranque automático"

instalar_systemd() {
    local usuario="${SUDO_USER:-$(id -un)}"
    sudo tee /etc/systemd/system/judo-api.service >/dev/null <<UNIDAD
[Unit]
Description=API de JudoAdministración
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=$usuario
WorkingDirectory=$DIR_SERVICIO
ExecStart=$BINARIO
# Si el proceso se cae en mitad de una competición, vuelve solo en cinco segundos y los puestos se
# reconectan sin que nadie tenga que darse cuenta.
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIDAD
    sudo systemctl daemon-reload
    sudo systemctl enable --now judo-api
}

instalar_launchd() {
    sudo tee /Library/LaunchDaemons/es.judo.api.plist >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>es.judo.api</string>
    <key>ProgramArguments</key>
    <array><string>$BINARIO</string></array>
    <!-- El servicio busca el certificado y su configuración por ruta relativa: sin esto arrancaría
         en / y no encontraría ninguno de los dos. -->
    <key>WorkingDirectory</key><string>$DIR_SERVICIO</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/judo-api.log</string>
    <key>StandardErrorPath</key><string>/var/log/judo-api.error.log</string>
</dict>
</plist>
PLIST
    sudo chown root:wheel /Library/LaunchDaemons/es.judo.api.plist
    sudo launchctl bootout system/es.judo.api 2>/dev/null || true
    sudo launchctl bootstrap system /Library/LaunchDaemons/es.judo.api.plist
}

if [[ $SIN_SERVICIO -eq 1 ]]; then
    aviso "no se instala el arranque automático (--sin-servicio)"
    aviso "la API habrá que arrancarla a mano, o desde el botón de la propia aplicación"
elif [[ "$SISTEMA" == "Darwin" ]]; then
    instalar_launchd
    bien "launchd: es.judo.api instalado y arrancado"
elif command -v systemctl >/dev/null; then
    instalar_systemd
    bien "systemd: judo-api instalado y arrancado"
else
    aviso "no hay systemd; configura el arranque a mano (doc 00, §7.3)"
    SIN_SERVICIO=1
fi

if [[ $SIN_SERVICIO -eq 0 ]]; then
    for _ in $(seq 1 20); do
        curl -sf "https://localhost:$PUERTO/api/estado" >/dev/null 2>&1 && break
        sleep 1
    done
    # Sin --cacert a propósito: si esto responde, es que el certificado del paso 5 está bien
    # instalado en el almacén del sistema y la aplicación de escritorio va a poder conectar. Es la
    # misma prueba de fuego que hace preparar-puesto en los puestos.
    if RESPUESTA="$(curl -sf "https://localhost:$PUERTO/api/estado" 2>/dev/null)"; then
        bien "el servicio responde y su certificado es de confianza aquí: $RESPUESTA"
    elif curl -sfk "https://localhost:$PUERTO/api/estado" >/dev/null 2>&1; then
        aviso "el servicio responde, pero su certificado no es de confianza en este equipo"
        aviso "la aplicación de escritorio de aquí no podrá conectar; revisa el paso 5"
    else
        aviso "el servicio no responde todavía; mira el registro:"
        [[ "$SISTEMA" == "Darwin" ]] && aviso "  tail -f /var/log/judo-api.error.log" \
                                     || aviso "  journalctl -u judo-api -f"
    fi
fi

# ── Resumen ───────────────────────────────────────────────────────────────────────────────────────

# Todo lo que hay que llevarse a los puestos, en una sola carpeta del home: el certificado público
# y los guiones de preparación, para los dos sistemas. Se copia a un USB y se va de puesto en puesto
# sin volver a pensar qué archivo hacía falta ni sacarlo de una carpeta del sistema con sudo.
if [[ -f "$CRT" ]]; then
    mkdir -p "$PARA_PUESTOS"
    cp "$CRT" "$PARA_PUESTOS/" 2>/dev/null || sudo cp "$CRT" "$PARA_PUESTOS/"

    # Los guiones vienen dentro del paquete del servicio (doc 00, §8.1). Si este guion se está
    # ejecutando desde el repositorio no están ahí, y se cogen de su sitio de siempre.
    for origen in "$DIR_SERVICIO/Puestos" "$RAIZ/Empaquetado/puesto" "$RAIZ/Empaquetado/red"; do
        [[ -d "$origen" ]] || continue
        cp "$origen"/preparar-puesto.* "$PARA_PUESTOS/" 2>/dev/null || true
        cp "$origen"/configurar-red.*  "$PARA_PUESTOS/" 2>/dev/null || true
    done

    cat > "$PARA_PUESTOS/LEEME.txt" <<TEXTO
Preparación de un puesto de administración de JudoAdministración

Copia esta carpeta a un USB y llévala a cada puesto. En cada uno, con la aplicación ya
instalada (Documentación/01-Guía-de-Instalación.md, §4.1):

  1. Dirección IP fija            macOS y Linux   sudo ./configurar-red.sh
                                  Windows         powershell -ExecutionPolicy Bypass -File .\configurar-red.ps1

  2. Certificado, nombre y        macOS y Linux   sudo ./preparar-puesto.sh
     configuración                Windows         powershell -ExecutionPolicy Bypass -File .\preparar-puesto.ps1

El segundo termina comprobando que el puesto llega al servidor. Si las cuatro comprobaciones
salen en verde, el puesto está listo.

Al acabar la competición, los dos con --deshacer (-Deshacer en Windows) devuelven el equipo a
como estaba.

Servidor: $NOMBRE_SERVIDOR ($IP_SERVIDOR), puerto $PUERTO
Certificado: $NOMBRE_SERVIDOR.crt   (el .pfx y el .key NO salen del servidor)
TEXTO

    chmod -R u+rwX,go+rX "$PARA_PUESTOS" 2>/dev/null || true
    chmod +x "$PARA_PUESTOS"/*.sh 2>/dev/null || true
    [[ -n "${SUDO_USER:-}" ]] && sudo chown -R "$SUDO_USER" "$PARA_PUESTOS" 2>/dev/null || true
fi

if [[ $CONSERVAR_CONFIG -eq 0 ]]; then
    umask 077
    cat > "$CREDENCIALES" <<TEXTO
Credenciales del servidor de JudoAdministración
Generadas por preparar-servidor.sh

Servidor           $NOMBRE_SERVIDOR ($IP_SERVIDOR), puerto $PUERTO
Base de datos      $BD
Carpeta            $DIR_SERVICIO

PostgreSQL
  judo_owner       $CLAVE_OWNER      (dueño del esquema; migraciones y copias de seguridad)
  judo_api         $CLAVE_API      (con el que corre el servicio y la aplicación de este equipo)

Certificado
  $(basename "$PFX")   $CLAVE_PFX

GUARDA ESTE ARCHIVO FUERA DE ESTE EQUIPO. Sin estas contraseñas, una copia de seguridad
restaurada no deja el servidor funcionando (Documentación/01-Guía-de-Instalación.md, §8).
TEXTO
    chmod 600 "$CREDENCIALES"
    [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER" "$CREDENCIALES" 2>/dev/null || true
fi

echo
echo "${VERDE}Servidor preparado.${FIN}"
echo
if [[ $CONSERVAR_CONFIG -eq 0 ]]; then
    echo "   Contraseñas guardadas en:  $CREDENCIALES"
    echo "   ${AMARILLO}Cópialas fuera de este equipo y bórralas de aquí cuando lo hayas hecho.${FIN}"
    echo
fi
echo "   ${AZUL}Queda por hacer:${FIN}"
echo "     1. Abrir la aplicación en este equipo y entrar con admin@judo.com / admin123"
echo "     2. Cambiarle la contraseña y dar de alta los usuarios de los puestos    → guía §3.9"
echo "     3. En cada puesto, con la carpeta de abajo en un USB:"
echo "          sudo ./configurar-red.sh  y  sudo ./preparar-puesto.sh             → guía §4"
echo
echo "   Lo que hay que llevarse a los puestos, en una sola carpeta:"
echo "     $PARA_PUESTOS"
echo "     (el certificado y los guiones de preparación, con su LEEME.txt)"
echo
