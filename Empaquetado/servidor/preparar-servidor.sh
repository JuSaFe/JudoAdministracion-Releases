#!/usr/bin/env bash
#
# Prepara el servidor de competición de principio a fin: PostgreSQL, base de datos, roles,
# extensiones, certificado HTTPS, configuración del servicio, esquema con sus datos básicos y, si se
# pide, el servicio del sistema para que arranque solo al encender el equipo.
#
# Es el equivalente ejecutable de la Documentación/01-Guía-de-Instalación.md, §3. Se lanza UNA vez,
# en el equipo servidor, antes de instalar los puestos. Para macOS y Linux; el de Windows es
# preparar-servidor.ps1.
#
#     ./preparar-servidor.sh --dir /opt/judoadministracion-api
#
# Antes de ejecutarlo hay que haber descomprimido ahí el paquete del servicio (el api-<sistema> de
# la Documentación/00). El guion comprueba que está.
#
# Es idempotente: se puede volver a ejecutar sobre un servidor ya preparado. Lo que ya existe se
# respeta —en particular la configuración y el certificado, que no se regeneran salvo que se pida
# expresamente— y lo que falta se crea.
#
set -euo pipefail

# ── Parámetros ────────────────────────────────────────────────────────────────────────────────────

BD="JudoAdministracion"
NOMBRE_SERVIDOR="judo-server"
IP_SERVIDOR="192.168.2.3"
DIR_SERVICIO="/opt/judoadministracion-api"
SUPERUSUARIO="postgres"
PUERTO=8443

CLAVE_OWNER=""
CLAVE_API=""
CLAVE_PFX=""

INSTALAR_POSTGRESQL=0
INSTALAR_SERVICIO=0
REGENERAR_CERTIFICADO=0
FORZAR_CONFIGURACION=0
CONFIAR_CERTIFICADO=0
SIN_ESQUEMA=0
SIN_PREGUNTAS=0

ayuda() {
    cat <<'AYUDA'
Prepara el servidor de competición de JudoAdministración.

  --dir RUTA               Carpeta del servicio (por defecto /opt/judoadministracion-api)
  --bd NOMBRE              Base de datos (por defecto JudoAdministracion)
  --nombre NOMBRE          Nombre de red del servidor (por defecto judo-server)
  --ip DIRECCIÓN           IP del servidor (por defecto 192.168.2.3)
  --puerto N               Puerto de la API (por defecto 8443)
  --superusuario USUARIO   Superusuario de PostgreSQL (por defecto postgres)

  --clave-owner CLAVE      Contraseña de judo_owner (por defecto, se genera)
  --clave-api CLAVE        Contraseña de judo_api   (por defecto, se genera)
  --clave-pfx CLAVE        Contraseña del certificado (por defecto, se genera)

  --instalar-postgresql    Instala PostgreSQL si no está (usa brew, apt o dnf)
  --instalar-servicio      Deja el servicio arrancando solo (systemd o launchd)
  --confiar-certificado    Instala el certificado como raíz de confianza de ESTE equipo
                           (hace falta si aquí va a correr también la aplicación: el anfitrión)
  --regenerar-certificado  Rehace el certificado aunque ya exista
  --forzar-configuracion   Reescribe appsettings.Local.json aunque ya exista
  --sin-esquema            No inicializa el esquema (solo prepara la base de datos)
  --si                     No pregunta nada
  --ayuda                  Esto

Ejemplo típico, servidor nuevo con todo:

  sudo mkdir -p /opt/judoadministracion-api && sudo unzip api-1.0.0.1-linux-x64.zip -d /opt
  ./preparar-servidor.sh --instalar-postgresql --instalar-servicio
AYUDA
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)                    DIR_SERVICIO="$2"; shift 2 ;;
        --bd)                     BD="$2"; shift 2 ;;
        --nombre)                 NOMBRE_SERVIDOR="$2"; shift 2 ;;
        --ip)                     IP_SERVIDOR="$2"; shift 2 ;;
        --puerto)                 PUERTO="$2"; shift 2 ;;
        --superusuario)           SUPERUSUARIO="$2"; shift 2 ;;
        --clave-owner)            CLAVE_OWNER="$2"; shift 2 ;;
        --clave-api)              CLAVE_API="$2"; shift 2 ;;
        --clave-pfx)              CLAVE_PFX="$2"; shift 2 ;;
        --instalar-postgresql)    INSTALAR_POSTGRESQL=1; shift ;;
        --instalar-servicio)      INSTALAR_SERVICIO=1; shift ;;
        --confiar-certificado)    CONFIAR_CERTIFICADO=1; shift ;;
        --regenerar-certificado)  REGENERAR_CERTIFICADO=1; shift ;;
        --forzar-configuracion)   FORZAR_CONFIGURACION=1; shift ;;
        --sin-esquema)            SIN_ESQUEMA=1; shift ;;
        --si)                     SIN_PREGUNTAS=1; shift ;;
        --ayuda|-h)               ayuda; exit 0 ;;
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
CREDENCIALES="$HOME/judo-credenciales-servidor.txt"
SISTEMA="$(uname)"

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

# Escribe en la carpeta del servicio, con sudo solo si hace falta. El guion NO se ejecuta entero
# como root a propósito: en macOS con Homebrew, PostgreSQL responde al usuario que ha iniciado
# sesión y no a root, así que elevar todo rompería psql.
NECESITA_ROOT=0
escribir() {                                        # escribir <ruta> < contenido por la entrada
    if [[ $NECESITA_ROOT -eq 1 ]]; then sudo tee "$1" >/dev/null; else cat > "$1"; fi
}
como_root() { if [[ $NECESITA_ROOT -eq 1 ]]; then sudo "$@"; else "$@"; fi; }

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

echo
echo "${AZUL}Preparación del servidor de JudoAdministración${FIN}"
echo "   servidor   $NOMBRE_SERVIDOR ($IP_SERVIDOR), puerto $PUERTO"
echo "   base       $BD"
echo "   carpeta    $DIR_SERVICIO"

# ── 1. Comprobaciones previas ─────────────────────────────────────────────────────────────────────

paso "1/9  Comprobaciones previas"

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
# arrancarlo ella sola (Services/Servidor/ServicioApiLocal.LocalizarBinario; ver doc 00, 8.1). Si
# el paquete se ha descomprimido en otro sitio, mejor pararse aquí que descubrirlo el día del
# campeonato, cuando la aplicación no encuentre el servicio sola.
RUTA_RECOMENDADA="/opt/judoadministracion-api"
RUTA_ACTUAL="$(cd "$DIR_SERVICIO" && pwd)"
if [[ "$RUTA_ACTUAL" != "$RUTA_RECOMENDADA" ]]; then
    fallo "Esta carpeta es $RUTA_ACTUAL y debería ser $RUTA_RECOMENDADA (doc 00, 8.1).
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
else
    bien "servidor nuevo: se generará la configuración"
fi

# ── 2. PostgreSQL ─────────────────────────────────────────────────────────────────────────────────

paso "2/9  PostgreSQL"

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
    if [[ $INSTALAR_POSTGRESQL -eq 1 ]]; then
        aviso "PostgreSQL no está instalado; instalando"
        instalar_postgresql
    else
        fallo "PostgreSQL no está instalado. Añade --instalar-postgresql o instálalo a mano (guía §3.1)."
    fi
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

paso "3/9  Base de datos \"$BD\""

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

paso "4/9  Roles y extensiones"

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

paso "5/9  Certificado HTTPS"

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
    como_root chmod 600 "$KEY" "$PFX"
    como_root chmod 644 "$CRT"
    rm -rf "$TEMPORAL"

    bien "certificado emitido para $NOMBRE_SERVIDOR, localhost, $IP_SERVIDOR y 127.0.0.1"
    bien "válido 5 años"
fi

if [[ $CONFIAR_CERTIFICADO -eq 1 ]]; then
    # Necesario si este equipo va a ejecutar también la aplicación de escritorio (el anfitrión):
    # si no confía en el certificado, no puede conectarse a su propio servidor. En los puestos, este
    # mismo paso está en la guía §4.2.
    if [[ "$SISTEMA" == "Darwin" ]]; then
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
fi

# ── 6. Configuración del servicio ─────────────────────────────────────────────────────────────────

paso "6/9  Configuración del servicio"

escribir_configuracion() {                          # escribir_configuracion <usuario> <clave> <inicializar>
    escribir "$CONFIG" <<JSON
{
    "//": [
        "Generado por Empaquetado/servidor/preparar-servidor.sh.",
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
    como_root chmod 600 "$CONFIG"
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

paso "7/9  Esquema y datos básicos"

if [[ $SIN_ESQUEMA -eq 1 ]]; then
    aviso "omitido por --sin-esquema"
elif [[ $CONSERVAR_CONFIG -eq 1 ]]; then
    igual "se conserva la configuración existente: no se relanza la inicialización"
    aviso "si esta es una actualización con cambios de esquema, sigue la guía §7"
else
    # Si algo ocupa ya el puerto, el servicio que vamos a lanzar no podrá escuchar y la espera de
    # abajo acabaría en un "no llegó a responder" que no dice cuál es el problema. El caso típico es
    # tener el servicio ya instalado y en marcha (--instalar-servicio de una ejecución anterior).
    if command -v lsof >/dev/null && lsof -nP -iTCP:"$PUERTO" -sTCP:LISTEN >/dev/null 2>&1; then
        fallo "Ya hay algo escuchando en el puerto $PUERTO. Párala antes de inicializar:
       Linux  → sudo systemctl stop judo-api
       macOS  → sudo launchctl unload /Library/LaunchDaemons/es.judo.api.plist
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
        fallo "Inicialización fallida. Los fallos frecuentes están en la guía §9."
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

# ── 8. Servicio del sistema ───────────────────────────────────────────────────────────────────────

paso "8/9  Arranque automático"

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
    sudo launchctl load -w /Library/LaunchDaemons/es.judo.api.plist
}

if [[ $INSTALAR_SERVICIO -eq 0 ]]; then
    aviso "no solicitado (--instalar-servicio). El servicio no arrancará solo al encender el equipo"
elif [[ "$SISTEMA" == "Darwin" ]]; then
    instalar_launchd
    bien "launchd: es.judo.api instalado y arrancado"
else
    command -v systemctl >/dev/null || fallo "No hay systemd; configura el arranque a mano (doc 00, §7.3)."
    instalar_systemd
    bien "systemd: judo-api instalado y arrancado"
fi

# ── 9. Comprobación final y resumen ───────────────────────────────────────────────────────────────

paso "9/9  Comprobación"

if [[ $INSTALAR_SERVICIO -eq 1 ]]; then
    for _ in $(seq 1 20); do
        curl -sf --cacert "$CRT" "https://localhost:$PUERTO/api/estado" >/dev/null 2>&1 && break
        sleep 1
    done
    if RESPUESTA="$(curl -sf --cacert "$CRT" "https://localhost:$PUERTO/api/estado" 2>/dev/null)"; then
        bien "el servicio responde: $RESPUESTA"
    else
        aviso "el servicio no responde todavía; mira el registro:"
        [[ "$SISTEMA" == "Darwin" ]] && aviso "  tail -f /var/log/judo-api.error.log" \
                                     || aviso "  journalctl -u judo-api -f"
    fi
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
  judo_api         $CLAVE_API      (con el que corre el servicio)

Certificado
  $(basename "$PFX")   $CLAVE_PFX

GUARDA ESTE ARCHIVO FUERA DE ESTE EQUIPO. Sin estas contraseñas, una copia de seguridad
restaurada no deja el servidor funcionando (Documentación/01-Guía-de-Instalación.md, §8).
TEXTO
    chmod 600 "$CREDENCIALES"
fi

echo
echo "${VERDE}Servidor preparado.${FIN}"
echo
if [[ $CONSERVAR_CONFIG -eq 0 ]]; then
    echo "   Contraseñas guardadas en:  $CREDENCIALES"
    echo "   ${AMARILLO}Cópialas fuera de este equipo y bórralas de aquí cuando lo hayas hecho.${FIN}"
    echo
fi
echo "   Queda por hacer, según la guía de instalación:"
echo "     · Cambiar la contraseña de admin@judo.com, que es 'admin123'   → §3.9"
echo "     · Dar de alta los usuarios de los puestos                      → §3.9"
echo "     · Abrir el $PUERTO al 192.168.2.0/24 y cerrar el 5432          → doc 02, §3.3"
echo "     · Copiar $NOMBRE_SERVIDOR.crt a cada puesto e instalarlo       → §4.2"
echo
echo "   El certificado que hay que repartir a los puestos:"
echo "     $CRT"
echo
