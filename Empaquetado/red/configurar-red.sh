#!/usr/bin/env bash
#
# Configura la red de un equipo para la competición, y la deja como estaba al terminar.
#
# Pone la IP fija que le corresponde según su papel en el evento, la puerta de enlace, los DNS y la
# línea del archivo hosts que resuelve "judo-server". Antes de tocar nada guarda la configuración
# anterior, para que al acabar la competición se pueda devolver el equipo a como estaba —que es
# importante cuando el portátil es de alguien y esa misma tarde se lo lleva a su casa—.
#
#     ./configurar-red.sh                 preguntando, que es lo recomendable
#     ./configurar-red.sh --deshacer      devolver el equipo a como estaba
#     ./configurar-red.sh --simular       decir lo que haría, sin tocar nada
#
# El plan de direcciones es el de Documentación/02-Red-y-Direccionamiento-IP.md. Para macOS y Linux
# (Linux necesita NetworkManager); el de Windows es configurar-red.ps1.
#
set -euo pipefail

# ── Parámetros ────────────────────────────────────────────────────────────────────────────────────

RED="192.168.2"
MASCARA="255.255.255.0"
PUERTA="192.168.2.1"
DNS_ALTERNATIVO="8.8.8.8"
NOMBRE_SERVIDOR="judo-server"
IP_SERVIDOR="192.168.2.3"

ROL=""
IP=""
INTERFAZ=""
SIN_HOSTS=0
DESHACER=0
SIMULAR=0
SIN_PREGUNTAS=0

ESTADO="/etc/judo-red-anterior.conf"
MARCA="# JudoAdministracion"          # con esta marca se reconoce y se quita la línea de hosts
HOSTS="/etc/hosts"
SISTEMA="$(uname)"

ayuda() {
    cat <<'AYUDA'
Configura la red de un equipo para la competición (y la deshace al terminar).

  --rol ROL           servidor | puesto | marcador | pantalla
  --ip DIRECCIÓN      IP fija a poner (si no, se ofrece la que toca según el rol)
  --interfaz NOMBRE   Interfaz de red a configurar (si no, se pregunta)

  --red PREFIJO       Los tres primeros octetos (por defecto 192.168.2)
  --puerta IP         Puerta de enlace (por defecto 192.168.2.1)
  --ip-servidor IP    Servidor al que apuntará "judo-server" (por defecto 192.168.2.3)
  --sin-hosts         No tocar el archivo hosts

  --estado RUTA       Dónde se guarda la configuración anterior
                      (por defecto /etc/judo-red-anterior.conf)
  --hosts RUTA        Archivo hosts a modificar (por defecto /etc/hosts)

  --deshacer          Devolver la configuración anterior y quitar la línea de hosts
  --simular           Decir lo que haría, sin cambiar nada
  --si                No preguntar
  --ayuda             Esto

Rangos del plan de direcciones (doc 02):

  servidor    192.168.2.3
  puesto      192.168.2.5  - 192.168.2.9     puestos de administración
  marcador    192.168.2.10 - 192.168.2.19    marcadores de tatami
  pantalla    192.168.2.20 - 192.168.2.29    pantallas de visualización
AYUDA
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rol)          ROL="$2"; shift 2 ;;
        --ip)           IP="$2"; shift 2 ;;
        --interfaz)     INTERFAZ="$2"; shift 2 ;;
        --red)          RED="$2"; shift 2 ;;
        --puerta)       PUERTA="$2"; shift 2 ;;
        --ip-servidor)  IP_SERVIDOR="$2"; shift 2 ;;
        --sin-hosts)    SIN_HOSTS=1; shift ;;
        --estado)       ESTADO="$2"; shift 2 ;;
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

# En modo simulación, todo lo que cambiaría el sistema pasa por aquí y solo se enseña.
ejecutar() {
    if [[ $SIMULAR -eq 1 ]]; then
        echo "   ${AMARILLO}[simulado]${FIN} $*"
    else
        "$@"
    fi
}

confirmar() {
    [[ $SIN_PREGUNTAS -eq 1 ]] && return 0
    local respuesta
    read -r -p "   $1 [s/N] " respuesta
    [[ "$respuesta" =~ ^[sSyY]$ ]]
}

# ¿Responde esta dirección? El indicador de "ocupada". Los dos sistemas usan la misma letra para
# cosas distintas: en macOS -W son milisegundos, en Linux segundos.
responde() {
    if [[ "$SISTEMA" == "Darwin" ]]; then ping -c 1 -W 800 "$1" >/dev/null 2>&1
    else                                  ping -c 1 -W 1   "$1" >/dev/null 2>&1; fi
}

if [[ "$SISTEMA" != "Darwin" ]] && ! command -v nmcli >/dev/null; then
    fallo "En Linux este guion necesita NetworkManager (nmcli).
     Sin él, la forma de fijar una IP depende de la distribución (netplan, systemd-networkd,
     /etc/network/interfaces) y es mejor hacerlo a mano: doc 02, §2."
fi

if [[ $SIMULAR -eq 0 && $EUID -ne 0 ]]; then
    fallo "Cambiar la red y el archivo hosts necesita permisos de administrador:
       sudo $0 $*"
fi

# ── Interfaces del equipo ─────────────────────────────────────────────────────────────────────────

# Devuelve una línea por interfaz: "<identificador>|<descripción para la persona>"
listar_interfaces() {
    if [[ "$SISTEMA" == "Darwin" ]]; then
        # networksetup trabaja con el nombre del "servicio de red" (Wi-Fi, Ethernet, USB 10/100/1000
        # LAN…), no con el del dispositivo (en0). Se enseñan los dos: el nombre es el que hay que
        # usar, el dispositivo es el que la gente reconoce de ifconfig.
        networksetup -listnetworkserviceorder | awk '
            /^\([0-9]+\)/ { servicio = substr($0, index($0, ") ") + 2) }
            /Device: /     { d = $0; sub(/.*Device: /, "", d); sub(/\).*/, "", d)
                             if (servicio != "" && d != "") print servicio "|" servicio " (" d ")"
                             servicio = "" }'
    else
        # En Linux se configura el perfil de conexión de NetworkManager, no el dispositivo.
        nmcli -t -f NAME,DEVICE,TYPE connection show --active | while IFS=: read -r n d t; do
            [[ "$t" == "loopback" ]] && continue
            printf '%s|%s (%s, %s)\n' "$n" "$n" "$d" "$t"
        done
    fi
}

elegir_interfaz() {
    local -a ids=() etiquetas=()
    while IFS='|' read -r id etiqueta; do
        [[ -n "$id" ]] || continue
        ids+=("$id"); etiquetas+=("$etiqueta")
    done < <(listar_interfaces)

    [[ ${#ids[@]} -gt 0 ]] || fallo "No encuentro ninguna interfaz de red activa."

    if [[ ${#ids[@]} -eq 1 ]]; then
        INTERFAZ="${ids[0]}"
        bien "única interfaz: ${etiquetas[0]}"
        return
    fi

    echo "   ¿Qué interfaz de red hay que configurar?"
    echo
    local i
    for i in "${!ids[@]}"; do
        printf '     %d) %s\n' "$((i + 1))" "${etiquetas[$i]}"
    done
    echo
    aviso "para lo crítico, cable antes que Wi-Fi (doc 02, §6)"
    echo

    local eleccion
    while true; do
        read -r -p "   Número [1-${#ids[@]}]: " eleccion
        if [[ "$eleccion" =~ ^[0-9]+$ ]] && (( eleccion >= 1 && eleccion <= ${#ids[@]} )); then
            INTERFAZ="${ids[$((eleccion - 1))]}"
            return
        fi
        echo "   No es un número de la lista."
    done
}

# ── Estado anterior: guardar y restaurar ──────────────────────────────────────────────────────────

guardar_estado() {
    local metodo="dhcp" ip="" mascara="" puerta="" dns=""

    if [[ "$SISTEMA" == "Darwin" ]]; then
        local info; info="$(networksetup -getinfo "$INTERFAZ")"
        if grep -q "^Manual Configuration" <<<"$info"; then
            metodo="manual"
            ip="$(awk -F': ' '/^IP address: /   {print $2; exit}' <<<"$info")"
            mascara="$(awk -F': ' '/^Subnet mask: / {print $2; exit}' <<<"$info")"
            puerta="$(awk -F': ' '/^Router: /      {print $2; exit}' <<<"$info")"
        fi
        # "There aren't any DNS Servers set on X." cuando no hay ninguno puesto a mano.
        local servidores; servidores="$(networksetup -getdnsservers "$INTERFAZ" 2>/dev/null || true)"
        grep -qi "aren't any" <<<"$servidores" || dns="$(tr '\n' ' ' <<<"$servidores" | sed 's/ *$//')"
    else
        metodo="$(nmcli -g ipv4.method connection show "$INTERFAZ")"
        [[ "$metodo" == "manual" ]] || metodo="dhcp"
        ip="$(nmcli -g ipv4.addresses connection show "$INTERFAZ")"
        puerta="$(nmcli -g ipv4.gateway  connection show "$INTERFAZ")"
        dns="$(nmcli -g ipv4.dns        connection show "$INTERFAZ" | tr ',' ' ')"
    fi

    if [[ $SIMULAR -eq 1 ]]; then
        echo "   ${AMARILLO}[simulado]${FIN} guardaría en $ESTADO:"
        echo "              interfaz=$INTERFAZ metodo=$metodo ip=$ip puerta=$puerta dns=$dns"
        return
    fi

    cat > "$ESTADO" <<FIN_ESTADO
# Configuración de red de este equipo ANTES de la competición.
# La escribió Empaquetado/red/configurar-red.sh; la usa --deshacer para devolverlo a como estaba.
# Si borras este archivo, --deshacer solo podrá dejar la interfaz en automático (DHCP).
sistema=$SISTEMA
interfaz=$INTERFAZ
metodo=$metodo
ip=$ip
mascara=$mascara
puerta=$puerta
dns=$dns
FIN_ESTADO
    chmod 644 "$ESTADO"
    bien "configuración anterior guardada ($metodo) en $ESTADO"
}

aplicar_estatica() {
    if [[ "$SISTEMA" == "Darwin" ]]; then
        ejecutar networksetup -setmanual "$INTERFAZ" "$IP" "$MASCARA" "$PUERTA"
        ejecutar networksetup -setdnsservers "$INTERFAZ" "$PUERTA" "$DNS_ALTERNATIVO"
    else
        ejecutar nmcli connection modify "$INTERFAZ" \
            ipv4.method manual \
            ipv4.addresses "$IP/24" \
            ipv4.gateway "$PUERTA" \
            ipv4.dns "$PUERTA,$DNS_ALTERNATIVO"
        ejecutar nmcli connection up "$INTERFAZ"
    fi
}

# Lo que se leyó del archivo de estado. Con valores por defecto por si el archivo está a medias.
est_interfaz=""; est_metodo="dhcp"; est_ip=""; est_mascara=""; est_puerta=""; est_dns=""

# Se parsea clave=valor en lugar de hacer "source" del archivo: un archivo de configuración que se
# ejecuta como shell es una forma de ejecutar código arbitrario como root, y aquí no hace ninguna
# falta. Leyendo con redirección y no por tubería, las asignaciones se conservan al salir del bucle.
leer_estado() {
    local clave valor
    while IFS='=' read -r clave valor; do
        case "$clave" in
            interfaz) est_interfaz="$valor" ;;
            metodo)   est_metodo="$valor" ;;
            ip)       est_ip="$valor" ;;
            mascara)  est_mascara="$valor" ;;
            puerta)   est_puerta="$valor" ;;
            dns)      est_dns="$valor" ;;
        esac
    done < "$1"
}

restaurar_estado() {
    local interfaz="$1" metodo="$2" ip="$3" mascara="$4" puerta="$5" dns="$6"

    if [[ "$SISTEMA" == "Darwin" ]]; then
        if [[ "$metodo" == "manual" && -n "$ip" ]]; then
            ejecutar networksetup -setmanual "$interfaz" "$ip" "${mascara:-255.255.255.0}" "$puerta"
        else
            ejecutar networksetup -setdhcp "$interfaz"
        fi
        if [[ -n "$dns" ]]; then
            # shellcheck disable=SC2086  # se quieren como argumentos separados
            ejecutar networksetup -setdnsservers "$interfaz" $dns
        else
            # "empty" es como networksetup borra los DNS puestos a mano y vuelve a los del DHCP.
            ejecutar networksetup -setdnsservers "$interfaz" empty
        fi
    else
        if [[ "$metodo" == "manual" && -n "$ip" ]]; then
            ejecutar nmcli connection modify "$interfaz" \
                ipv4.method manual ipv4.addresses "$ip" ipv4.gateway "$puerta" \
                ipv4.dns "$(tr ' ' ',' <<<"$dns")"
        else
            # Las tres propiedades se vacían explícitamente: dejar la dirección puesta con method
            # auto confunde a NetworkManager, que la conserva como dirección adicional.
            ejecutar nmcli connection modify "$interfaz" \
                ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
        fi
        ejecutar nmcli connection up "$interfaz"
    fi
}

# ── Archivo hosts ─────────────────────────────────────────────────────────────────────────────────

poner_hosts() {
    if grep -q "$MARCA" "$HOSTS" 2>/dev/null; then
        # Ya hay una línea nuestra: se rehace, por si cambió la IP del servidor.
        quitar_hosts silencioso
    fi
    if [[ $SIMULAR -eq 1 ]]; then
        echo "   ${AMARILLO}[simulado]${FIN} añadiría a $HOSTS:  $IP_SERVIDOR  $NOMBRE_SERVIDOR  $MARCA"
        return
    fi
    printf '%s\t%s\t%s\n' "$IP_SERVIDOR" "$NOMBRE_SERVIDOR" "$MARCA" >> "$HOSTS"
    bien "$NOMBRE_SERVIDOR → $IP_SERVIDOR en $HOSTS"
}

quitar_hosts() {
    local silencioso="${1:-}"
    if ! grep -q "$MARCA" "$HOSTS" 2>/dev/null; then
        [[ -n "$silencioso" ]] || igual "no había ninguna línea de JudoAdministración en $HOSTS"
        return
    fi
    if [[ $SIMULAR -eq 1 ]]; then
        echo "   ${AMARILLO}[simulado]${FIN} quitaría de $HOSTS las líneas marcadas con $MARCA"
        return
    fi
    # Solo las líneas con nuestra marca: el resto del archivo no se toca.
    local temporal; temporal="$(mktemp)"
    grep -v "$MARCA" "$HOSTS" > "$temporal"
    cat "$temporal" > "$HOSTS"          # cat y no mv, para conservar permisos y dueño de /etc/hosts
    rm -f "$temporal"
    [[ -n "$silencioso" ]] || bien "línea de $NOMBRE_SERVIDOR quitada de $HOSTS"
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
#  DESHACER
# ══════════════════════════════════════════════════════════════════════════════════════════════════

if [[ $DESHACER -eq 1 ]]; then
    echo
    echo "${AZUL}Devolver la red de este equipo a como estaba${FIN}"
    [[ $SIMULAR -eq 1 ]] && aviso "modo simulación: no se cambia nada"

    paso "1/3  Configuración anterior"

    if [[ -f "$ESTADO" ]]; then
        leer_estado "$ESTADO"
        [[ -n "$est_interfaz" ]] || fallo "$ESTADO no dice a qué interfaz se refiere; está corrupto."
        bien "encontrada: interfaz '$est_interfaz', estaba en $est_metodo"
        [[ "$est_metodo" == "manual" ]] && bien "IP anterior $est_ip, puerta $est_puerta"
    else
        aviso "no hay $ESTADO: no sé cómo estaba este equipo"
        aviso "lo mejor que puedo hacer es dejar la interfaz en automático (DHCP)"
        [[ -n "$INTERFAZ" ]] || elegir_interfaz
        est_interfaz="$INTERFAZ"
    fi

    if ! confirmar "¿Restauro la interfaz '$est_interfaz'?"; then
        echo "   Cancelado."; exit 0
    fi

    paso "2/3  Restaurando la interfaz"
    restaurar_estado "$est_interfaz" "$est_metodo" "$est_ip" "$est_mascara" "$est_puerta" "$est_dns"
    bien "interfaz '$est_interfaz' devuelta a $est_metodo"

    paso "3/3  Archivo hosts"
    quitar_hosts

    if [[ -f "$ESTADO" && $SIMULAR -eq 0 ]]; then
        rm -f "$ESTADO"
        bien "$ESTADO eliminado"
    fi

    echo
    echo "${VERDE}Red restaurada.${FIN}"
    echo
    echo "   Comprueba que el equipo vuelve a navegar:"
    echo "     ping -c 2 8.8.8.8"
    if [[ "$SISTEMA" == "Darwin" ]]; then
        echo "     networksetup -getinfo \"$est_interfaz\""
    else
        echo "     nmcli connection show \"$est_interfaz\" | grep ipv4"
    fi
    echo
    echo "   El certificado del servidor, si se instaló, se quita con:"
    echo "     Empaquetado/puesto/preparar-puesto.sh --deshacer"
    echo
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════
#  CONFIGURAR
# ══════════════════════════════════════════════════════════════════════════════════════════════════

echo
echo "${AZUL}Configuración de red para la competición${FIN}"
echo "   red $RED.0/24 · puerta $PUERTA · servidor $NOMBRE_SERVIDOR ($IP_SERVIDOR)"
[[ $SIMULAR -eq 1 ]] && aviso "modo simulación: no se cambia nada"

# ── 1. Interfaz ───────────────────────────────────────────────────────────────────────────────────

paso "1/6  Interfaz de red"

if [[ -n "$INTERFAZ" ]]; then
    bien "indicada: $INTERFAZ"
else
    elegir_interfaz
    bien "elegida: $INTERFAZ"
fi

# ── 2. Rol ────────────────────────────────────────────────────────────────────────────────────────

paso "2/6  Papel de este equipo en la competición"

# Los rangos del plan de direcciones, con funciones y no con arrays asociativos: macOS todavía trae
# bash 3.2, que es de 2007 y no los tiene, y aquí interesa funcionar con el bash que hay en el equipo
# y no obligar a instalar otro.
rango_desde() {
    case "$1" in servidor) echo 3 ;; puesto) echo 5 ;; marcador) echo 10 ;; pantalla) echo 20 ;;
                 *) return 1 ;; esac
}
rango_hasta() {
    case "$1" in servidor) echo 3 ;; puesto) echo 9 ;; marcador) echo 19 ;; pantalla) echo 29 ;;
                 *) return 1 ;; esac
}
que_es() {
    case "$1" in
        servidor) echo "Servidor: PostgreSQL y la API" ;;
        puesto)   echo "Puesto de administración: la aplicación de escritorio" ;;
        marcador) echo "Marcador de tatami" ;;
        pantalla) echo "Pantalla de visualización" ;;
        *)        return 1 ;;
    esac
}

if [[ -z "$ROL" ]]; then
    echo "   ¿Qué va a ser este equipo?"
    echo
    # El rango va primero porque es ASCII puro y se puede alinear con printf; los rótulos llevan
    # acentos, y printf cuenta bytes, así que padearlos descuadraría la columna.
    printf '     1) %-30s %s\n' "$RED.5 - $RED.9"   "$(que_es puesto)"
    printf '     2) %-30s %s\n' "$RED.3"            "$(que_es servidor)"
    printf '     3) %-30s %s\n' "$RED.10 - $RED.19" "$(que_es marcador)"
    printf '     4) %-30s %s\n' "$RED.20 - $RED.29" "$(que_es pantalla)"
    echo
    read -r -p "   Número [1-4]: " eleccion
    case "$eleccion" in
        1) ROL="puesto" ;;
        2) ROL="servidor" ;;
        3) ROL="marcador" ;;
        4) ROL="pantalla" ;;
        *) fallo "No es un número de la lista." ;;
    esac
fi

que_es "$ROL" >/dev/null || fallo "Rol desconocido: $ROL (servidor, puesto, marcador o pantalla)."
bien "$(que_es "$ROL")"

# ── 3. Dirección ──────────────────────────────────────────────────────────────────────────────────

paso "3/6  Dirección IP"

primero="$(rango_desde "$ROL")"; ultimo="$(rango_hasta "$ROL")"

# El escaneo solo dice algo si ya estamos en esa red; si no, todas parecerían libres.
EN_LA_RED=0
if [[ "$SISTEMA" == "Darwin" ]]; then
    ifconfig 2>/dev/null | grep -q "inet $RED\." && EN_LA_RED=1
else
    ip -4 addr 2>/dev/null | grep -q "inet $RED\." && EN_LA_RED=1
fi

ocupada() { [[ $EN_LA_RED -eq 1 ]] && responde "$1"; }

if [[ -z "$IP" ]]; then
    if [[ "$primero" == "$ultimo" ]]; then
        IP="$RED.$primero"
        bien "al rol $ROL le corresponde $IP"
    else
        echo "   Direcciones del rango de $ROL:"
        echo
        [[ $EN_LA_RED -eq 1 ]] || aviso "este equipo no está aún en $RED.0/24: no puedo ver cuáles están ocupadas"
        libre_sugerida=""
        for n in $(seq "$primero" "$ultimo"); do
            candidata="$RED.$n"
            if ocupada "$candidata"; then
                printf '     %-16s %s\n' "$candidata" "responde: OCUPADA"
            elif [[ $EN_LA_RED -eq 1 ]]; then
                printf '     %-16s %s\n' "$candidata" "libre"
                [[ -n "$libre_sugerida" ]] || libre_sugerida="$candidata"
            else
                printf '     %-16s\n' "$candidata"
            fi
        done
        echo
        [[ -n "$libre_sugerida" ]] || libre_sugerida="$RED.$primero"
        read -r -p "   IP para este equipo [$libre_sugerida]: " respuesta
        IP="${respuesta:-$libre_sugerida}"
    fi
fi

[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fallo "'$IP' no parece una dirección IP."

ultimo_octeto="${IP##*.}"
if [[ "${IP%.*}" != "$RED" ]]; then
    aviso "$IP no está en la red $RED.0/24 del plan de direcciones"
elif (( ultimo_octeto < primero || ultimo_octeto > ultimo )); then
    aviso "$IP queda fuera del rango de $ROL ($RED.$primero - $RED.$ultimo)"
    aviso "revisa el plan de direcciones (doc 02, §1) antes de seguir"
fi

if ocupada "$IP"; then
    aviso "${ROJO}$IP ya responde: hay otro equipo usándola${FIN}"
    aviso "dos equipos con la misma IP funcionan a ratos, y es el fallo más difícil de diagnosticar"
    confirmar "¿Seguir de todas formas?" || { echo "   Cancelado."; exit 0; }
fi
bien "se usará $IP"

# ── 4. Confirmación ───────────────────────────────────────────────────────────────────────────────

paso "4/6  Resumen"

echo "     interfaz          $INTERFAZ"
echo "     dirección IP      $IP"
echo "     máscara           $MASCARA"
echo "     puerta de enlace  $PUERTA"
echo "     DNS               $PUERTA, $DNS_ALTERNATIVO"
[[ $SIN_HOSTS -eq 0 ]] && echo "     hosts             $NOMBRE_SERVIDOR → $IP_SERVIDOR"
echo
aviso "se perderá la conexión un momento al aplicar los cambios"
confirmar "¿Aplico esta configuración?" || { echo "   Cancelado."; exit 0; }

# ── 5. Aplicar ────────────────────────────────────────────────────────────────────────────────────

paso "5/6  Aplicando"

guardar_estado
aplicar_estatica
bien "interfaz '$INTERFAZ' con IP fija $IP"

if [[ $SIN_HOSTS -eq 0 ]]; then
    poner_hosts
else
    igual "archivo hosts sin tocar (--sin-hosts)"
fi

# ── 6. Verificación ───────────────────────────────────────────────────────────────────────────────

paso "6/6  Comprobación"

if [[ $SIMULAR -eq 1 ]]; then
    aviso "en simulación no hay nada que comprobar"
else
    sleep 2      # dar tiempo a que la interfaz se levante con la configuración nueva

    if responde "$PUERTA"; then bien "llego a la puerta de enlace $PUERTA"
    else aviso "no llego a $PUERTA: revisa el cable y que el router sea el de la competición"; fi

    if [[ "$IP" != "$IP_SERVIDOR" ]]; then
        if responde "$IP_SERVIDOR"; then bien "llego al servidor $IP_SERVIDOR"
        else aviso "no llego al servidor $IP_SERVIDOR (¿está encendido?)"; fi

        if [[ $SIN_HOSTS -eq 0 ]]; then
            if responde "$NOMBRE_SERVIDOR"; then bien "el nombre $NOMBRE_SERVIDOR resuelve"
            else aviso "$NOMBRE_SERVIDOR no resuelve: revisa $HOSTS"; fi
        fi
    fi
fi

echo
echo "${VERDE}Red configurada.${FIN}"
echo
echo "   ${AMARILLO}Al acabar la competición, devuelve el equipo a como estaba:${FIN}"
echo "     sudo $0 --deshacer"
echo
if [[ "$ROL" == "puesto" ]]; then
    echo "   Ahora, la parte de la aplicación en este puesto (certificado y comprobaciones):"
    echo "     sudo Empaquetado/puesto/preparar-puesto.sh --certificado judo-server.crt"
    echo
fi
