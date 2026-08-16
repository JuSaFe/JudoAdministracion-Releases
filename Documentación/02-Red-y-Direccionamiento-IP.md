# Red de competición — Direccionamiento IP y configuración

Documento de referencia para montar la red local en una competición. Describe el plan de
direcciones, cómo se configura cada tipo de dispositivo, qué puertos deben estar abiertos y cómo
verificar que todo funciona antes de que empiece el evento.

El modelo de conexión entre las aplicaciones (API central, PostgreSQL, tiempo real) está en
[03-Arquitectura-Cliente-Servidor.md](03-Arquitectura-Cliente-Servidor.md). Aquí solo se trata la
capa de red. La instalación del servidor y de los puestos —PostgreSQL, roles, certificado,
servicio— está en la [01-Guía-de-Instalación.md](01-Guía-de-Instalación.md).

---

## 1. Resumen del plan de direcciones

Red: **192.168.2.0/24** · Máscara: **255.255.255.0** · Puerta de enlace: **192.168.2.1**

| Rango | Nº | Rol | Asignación |
|---|---|---|---|
| `192.168.2.1` | 1 | **Router** | Puerta de enlace de la red |
| `192.168.2.2` | 1 | *Libre / reserva* | Sin asignar (ver §1.1) |
| `192.168.2.3` | 1 | **Servidor** | PostgreSQL + API de JudoAdministración |
| `192.168.2.4` | 1 | *Servidor de respaldo* | Reservada (ver §7) |
| `192.168.2.5` – `192.168.2.9` | 5 | **Puestos de administración** | La aplicación de escritorio |
| `192.168.2.10` – `192.168.2.19` | 10 | **Marcadores de tatami** | Leen combates, anotan puntos, envían resultado |
| `192.168.2.20` – `192.168.2.29` | 10 | **Pantallas de visualización** | Muestran tatamis y sus 4 próximos combates |
| `192.168.2.30` – `192.168.2.99` | 70 | *Libre* | Ampliación futura |
| `192.168.2.100` – `192.168.2.199` | 100 | **Pool DHCP** | Dispositivos no planificados (ver §1.2) |
| `192.168.2.200` – `192.168.2.254` | 55 | *Libre* | Pruebas y diagnóstico |

### 1.1 Por qué se deja libre la `.2`

Muchos routers domésticos y de operador se asignan a sí mismos una segunda dirección, o la usan
para un punto de acceso Wi-Fi integrado. Dejarla vacía evita un conflicto que solo aparecería el
día de la competición.

### 1.2 El pool DHCP debe quedar FUERA de los rangos fijos

Esta es la configuración **más importante y la que más se olvida**. Como todos los dispositivos
del evento llevan IP estática configurada a mano, el router no sabe que esas direcciones están
ocupadas: si su pool DHCP empieza en `192.168.2.2`, en cuanto alguien conecte un móvil al Wi-Fi el
router le puede entregar la `.7` y tumbar un puesto de administración en mitad del sorteo.

En la configuración del router (`http://192.168.2.1`), en el apartado *LAN* / *DHCP*, deja el pool
en:

```
Inicio del pool DHCP:  192.168.2.100
Fin del pool DHCP:     192.168.2.199
```

Cualquier equipo ajeno al evento que se conecte caerá en el rango `.100`–`.199` y no podrá
colisionar con nada.

### 1.3 Inventario de dispositivos

Rellena y guarda esta tabla en cada evento; es lo primero que se consulta cuando algo no responde.

| IP | Dispositivo | MAC | Ubicación | Responsable |
|---|---|---|---|---|
| 192.168.2.3 | Servidor | | Mesa de control | |
| 192.168.2.5 | Puesto administración 1 | | Mesa de control | |
| 192.168.2.6 | Puesto administración 2 | | | |
| 192.168.2.7 | Puesto administración 3 | | | |
| 192.168.2.8 | Puesto administración 4 | | | |
| 192.168.2.9 | Puesto administración 5 | | | |
| 192.168.2.10 | Marcador tatami 1 | | Tatami 1 | |
| 192.168.2.11 | Marcador tatami 2 | | Tatami 2 | |
| … | | | | |
| 192.168.2.20 | Pantalla 1 | | | |
| … | | | | |

> **Convención:** el último dígito del marcador coincide con el número de tatami menos nueve —
> tatami 1 → `.10`, tatami 2 → `.11`, tatami 5 → `.14`. Cuando un marcador falla, saber su IP de
> memoria ahorra minutos.

---

## 2. Configuración de cada dispositivo

### La vía rápida, y cómo deshacerla

Todo lo de esta sección —IP fija, máscara, puerta de enlace, DNS y la línea del archivo *hosts*— está
automatizado, y de dos maneras que hacen lo mismo y son intercambiables.

**En los equipos que llevan la aplicación**, desde ella misma: rueda dentada de la pantalla de inicio
de sesión → **Red de la competición**. Ahí se elige la interfaz, el papel del equipo y su dirección, y
hay un botón para deshacerlo al acabar. Ver la
[01-Guía-de-Instalación.md](01-Guía-de-Instalación.md), §4.

**En cualquier equipo, con o sin aplicación**, con el guion:

```bash
sudo Empaquetado/red/configurar-red.sh          # macOS y Linux
```

```powershell
# Windows, como administrador. Sin -ExecutionPolicy Bypass: «la ejecución de scripts está
# deshabilitada en este sistema». Afecta sólo a esta ejecución, no al equipo.
powershell -ExecutionPolicy Bypass -File .\Empaquetado\red\configurar-red.ps1
```

Pregunta lo justo: enseña las interfaces de red del equipo para elegir cuál se configura —que no es
un detalle menor, porque «Ethernet» se llama distinto en cada máquina y muchos puestos van por un
adaptador USB—, pregunta qué va a ser el equipo, y ofrece la dirección que le toca según el rango de
§1. Si ya está conectado a la red de la competición, además **comprueba qué direcciones del rango
responden** y propone una libre, que es la forma de no caer en el duplicado de §5.2.

**Lo importante es que se deshace:**

```bash
sudo Empaquetado/red/configurar-red.sh --deshacer
```

Antes de tocar nada, el guion guarda la configuración anterior de esa interfaz en
`/etc/judo-red-anterior.conf` (`C:\ProgramData\JudoAdministracion\red-anterior.json` en Windows). La
pantalla de la aplicación escribe **ese mismo archivo con ese mismo formato**, y por eso las dos vías
son intercambiables: se puede configurar con una y deshacer con la otra. El `--deshacer` devuelve la
configuración tal cual: si el equipo estaba en DHCP, vuelve a DHCP; si tenía su propia IP
fija y sus propios DNS, se los repone. Y del archivo *hosts* quita **solo** las líneas que puso él,
que van marcadas con `# JudoAdministracion`.

Esto es lo que permite montar la red el día antes y devolver los portátiles prestados como estaban al
acabar, sin que nadie se lleve un equipo que ya no navega en su casa.

Con `--simular` (`-Simular`) dice exactamente lo que haría, sin cambiar nada. El de macOS y Linux
está probado; el de Windows sigue la misma lógica pero no se ha podido probar en un Windows real.

El resto de la sección es lo que hace el guion, paso a paso, para cuando haya que hacerlo a mano o
entender por qué algo no funciona.

### 2.1 Servidor — 192.168.2.3

Es el único equipo que **debe** llevar IP estática configurada en el sistema operativo, sin
depender del router: si el router se reinicia o falla, el servidor tiene que seguir accesible para
el resto de la red.

**Windows** (`Panel de control → Redes → Cambiar configuración del adaptador → Propiedades →
Protocolo de Internet versión 4`):

```
Dirección IP:        192.168.2.3
Máscara de subred:   255.255.255.0
Puerta de enlace:    192.168.2.1
DNS preferido:       192.168.2.1
DNS alternativo:     8.8.8.8
```

O por línea de comandos, en PowerShell **como administrador**:

```powershell
# Sustituye "Ethernet" por el nombre real del adaptador (Get-NetAdapter para verlo)
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 192.168.2.3 `
                 -PrefixLength 24 -DefaultGateway 192.168.2.1
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.2.1,8.8.8.8
```

**macOS** (`Ajustes del Sistema → Red → Ethernet → Detalles → TCP/IP → Configurar IPv4:
Manualmente`), o por terminal:

```bash
sudo networksetup -setmanual "Ethernet" 192.168.2.3 255.255.255.0 192.168.2.1
sudo networksetup -setdnsservers "Ethernet" 192.168.2.1 8.8.8.8
```

### 2.2 Puestos de administración — 192.168.2.5 a 192.168.2.9

Misma configuración, cambiando el último octeto. Cada puesto ejecuta su propia copia de
JudoAdministración y todos apuntan al mismo servidor.

**Usa un nombre, no la IP, en la configuración de la aplicación.** En cada puesto añade esta línea
al archivo de *hosts*:

- Windows: `C:\Windows\System32\drivers\etc\hosts` (editar como administrador)
- macOS / Linux: `/etc/hosts`

```
192.168.2.3    judo-server
```

Esa línea la pone y la quita `Empaquetado/red/configurar-red.sh` (y también
`Empaquetado/puesto/preparar-puesto.sh`, para el caso de que la red ya estuviera montada); van
marcadas con `# JudoAdministracion` para poder retirarlas sin tocar el resto del archivo.

Así, si algún día el servidor cambia de dirección, se toca una línea por equipo en lugar de
reconfigurar la aplicación. La configuración de la app queda:

```json
{
    "ApiBaseUrl": "https://judo-server:8443"
}
```

> Durante la fase de transición descrita en
> [03-Arquitectura-Cliente-Servidor.md](03-Arquitectura-Cliente-Servidor.md), los puestos todavía
> apuntan directamente a PostgreSQL. En ese caso el archivo `appsettings.Local.json` lleva:
>
> ```json
> {
>     "ConnectionString": "Host=judo-server;Port=5432;Database=JudoAdministracion;Username=…;Password=…"
> }
> ```

### 2.3 Marcadores — 192.168.2.10 a 192.168.2.19

Aplicación pendiente de desarrollo. Requisitos de red:

- IP estática en su rango.
- Solo necesitan alcanzar el puerto **8443** del servidor. **No** deben poder abrir el 5432.
- Se recomienda **cable** siempre que la instalación del pabellón lo permita: un marcador que
  pierde el resultado de un combate por un corte de Wi-Fi es un incidente arbitral.

### 2.4 Pantallas de visualización — 192.168.2.20 a 192.168.2.29

Misma configuración de red que los marcadores. Son de **solo lectura**: reciben la información de
combates por WebSocket desde el servidor y nunca escriben. Aquí el Wi-Fi es aceptable, porque una
reconexión solo produce un parpadeo en la pantalla.

---

## 3. Puertos y flujos permitidos

### 3.1 Puertos del servidor (192.168.2.3)

| Puerto | Protocolo | Servicio | Quién puede acceder |
|---|---|---|---|
| **8443** | TCP / HTTPS + WebSocket | API de JudoAdministración | `.5`–`.9`, `.10`–`.19`, `.20`–`.29` |
| **5432** | TCP | PostgreSQL | **Solo el propio servidor** (`127.0.0.1`) |
| 3389 / 22 | TCP | Escritorio remoto / SSH | Solo `.5` (opcional, para mantenimiento) |

**PostgreSQL no se expone a la red.** Ésta es una de las principales ventajas de centralizar todo
en la API: la base de datos solo escucha en local, la contraseña vive únicamente en el servidor y
ningún dispositivo del pabellón puede conectarse a ella aunque alguien enchufe un portátil ajeno al
switch.

### 3.2 Matriz de comunicación

```
                          ┌──────────────────────────────┐
                          │  192.168.2.3   SERVIDOR      │
  Puestos admin  ──8443──▶│                              │
  .5 – .9                 │   API  :8443 ──▶ PostgreSQL  │
                          │                     :5432    │
  Marcadores     ──8443──▶│                  (solo local)│
  .10 – .19               │                              │
                          │                              │
  Pantallas      ──8443──▶│                              │
  .20 – .29        (WS)   └──────────────────────────────┘
```

Ningún dispositivo necesita hablar con otro dispositivo: **todo el tráfico es radial hacia el
`.3`**. Si observas tráfico entre dos marcadores, algo está mal configurado.

### 3.3 Firewall del servidor

**Windows**, en PowerShell como administrador:

```powershell
# Permitir la API únicamente desde la subred de la competición
New-NetFirewallRule -DisplayName "JudoAdmin API" -Direction Inbound `
    -Protocol TCP -LocalPort 8443 -RemoteAddress 192.168.2.0/24 -Action Allow

# Bloquear explícitamente PostgreSQL desde la red (solo debe usarse en local)
New-NetFirewallRule -DisplayName "PostgreSQL bloqueado en LAN" -Direction Inbound `
    -Protocol TCP -LocalPort 5432 -RemoteAddress 192.168.2.0/24 -Action Block
```

**macOS / Linux** con `pf` o `ufw` según el sistema; el criterio es el mismo: 8443 abierto a
`192.168.2.0/24`, 5432 cerrado a todo lo que no sea `localhost`.

### 3.4 Configuración de PostgreSQL

Con la arquitectura de API central, PostgreSQL se queda **como está**, escuchando solo en local. No
hay que tocar `listen_addresses` ni `pg_hba.conf`.

Si durante la transición necesitas que los puestos de administración conecten directamente,
entonces sí:

En `postgresql.conf`:

```conf
listen_addresses = 'localhost,192.168.2.3'
max_connections = 100
```

En `pg_hba.conf` — nótese que se autoriza **solo el rango de administración**, no la subred
completa:

```conf
# TYPE  DATABASE              USER          ADDRESS              METHOD
host    JudoAdministracion    judo_app      192.168.2.5/32       scram-sha-256
host    JudoAdministracion    judo_app      192.168.2.6/32       scram-sha-256
host    JudoAdministracion    judo_app      192.168.2.7/32       scram-sha-256
host    JudoAdministracion    judo_app      192.168.2.8/32       scram-sha-256
host    JudoAdministracion    judo_app      192.168.2.9/32       scram-sha-256
```

Tras editar cualquiera de los dos archivos hay que recargar PostgreSQL (`pg_ctl reload`, o reiniciar
el servicio). Y cuando la migración a la API se complete, **estas líneas deben eliminarse**.

---

## 4. Certificado HTTPS

La API usa HTTPS incluso dentro de la red local, porque por ella viajan credenciales de usuario y
resultados de combate. Como no hay un dominio público, se emplea un certificado autofirmado
generado una sola vez en el servidor con OpenSSL. **El procedimiento completo, con el archivo de
configuración de los nombres, está en la [01-Guía-de-Instalación.md](01-Guía-de-Instalación.md),
§3.4.**

Ese certificado (la parte pública, `.crt`) se instala en cada puesto, marcador y pantalla como
entidad de confianza. Sin ese paso, los clientes rechazarán la conexión.

> El certificado debe incluir **todos** los nombres y direcciones por los que se pueda llegar al
> servidor: `judo-server` (el del archivo *hosts*), `localhost` (por el que conecta el anfitrión) y
> la IP `192.168.2.3`. Si un cliente conecta por un nombre que no está en el certificado, la
> validación falla.
>
> Por esta razón **`dotnet dev-certs https` no sirve** para esto: solo emite certificados para
> `localhost`, y los cinco puestos conectan por `judo-server`.

---

## 5. Verificación previa al evento

Ejecuta esta lista **el día antes**, no la mañana de la competición.

> En los puestos, estas cinco comprobaciones las hace de una vez
> `Empaquetado/puesto/preparar-puesto.sh` (paso 5), y las hace incluso con `--simular`, que no cambia
> nada. Sigue mereciendo la pena saber qué se comprueba y en qué orden, porque es lo que dice en qué
> capa está el problema.

### 5.1 En cada dispositivo

```powershell
# 1. ¿Tengo la IP que me corresponde?
ipconfig                     # Windows
ifconfig | grep "inet "      # macOS / Linux

# 2. ¿Llego al router?
ping 192.168.2.1

# 3. ¿Llego al servidor?
ping 192.168.2.3

# 4. ¿Resuelve el nombre?
ping judo-server

# 5. ¿Está abierto el puerto de la API?
Test-NetConnection judo-server -Port 8443        # Windows
nc -vz judo-server 8443                          # macOS / Linux
```

Los cinco pasos deben salir bien. Si el 3 funciona y el 4 no, falta la línea en el archivo *hosts*.
Si el 4 funciona y el 5 no, es el firewall del servidor o la API no está arrancada.

### 5.2 Buscar direcciones duplicadas

Con IP estáticas, un duplicado es el fallo más probable y el más confuso de diagnosticar: los dos
equipos funcionan a ratos.

Lo primero es no provocarlos: tanto la pantalla de Red de la aplicación como `configurar-red.sh`
comprueban el rango antes de asignar una dirección y marcan las que ya responden —la pantalla las
enseña en rojo y no deja aplicar—. Para buscar los que ya existan, desde el servidor y con todos los
dispositivos encendidos:

```bash
# Instalar nmap si hace falta. Debe listar exactamente los dispositivos previstos.
nmap -sn 192.168.2.0/24
```

```powershell
# Alternativa en Windows: la tabla ARP tras hacer ping a toda la red
arp -a
```

Compara el resultado con el inventario de §1.3. Cualquier dirección que aparezca y no esté en la
tabla, o cualquier equipo previsto que no aparezca, hay que investigarlo antes de empezar.

### 5.3 En el servidor

```bash
# PostgreSQL activo y escuchando SOLO en local
psql -h localhost -U judo_app -d JudoAdministracion -c "SELECT 1;"

# Que NO responda desde fuera: esto debe FALLAR (es la comprobación correcta)
psql -h 192.168.2.3 -U judo_app -d JudoAdministracion -c "SELECT 1;"
```

---

## 6. Hardware y buenas prácticas de montaje

- **Switch, no solo el router.** Los router de operador traen 4 puertos; aquí hacen falta hasta 26
  dispositivos. Un switch gigabit no gestionado de 24 puertos es suficiente y cuesta poco.
- **Cable para lo crítico.** Servidor, los 5 puestos de administración y los marcadores por cable.
  Las pantallas de visualización pueden ir por Wi-Fi.
- **SAI en el servidor.** Un corte de corriente en el `.3` para la competición entera. Un SAI
  pequeño da los minutos necesarios para cerrar en condiciones.
- **Wi-Fi separado.** Si el pabellón ofrece Wi-Fi al público, que no sea la misma red. Si no hay
  más remedio, el pool DHCP de §1.2 es la única protección.
- **Sin salida a Internet no pasa nada.** La competición funciona íntegramente en la red local. La
  puerta de enlace solo sirve para actualizaciones o consultas puntuales.
- **Hora sincronizada.** Todos los dispositivos deben tener la misma hora, porque las marcas de
  tiempo de los combates y de la auditoría (`fecha_insert` / `fecha_update`) se comparan entre sí.
  Configura el servidor como fuente NTP de la red, o al menos verifica que todos los equipos
  sincronizan con el mismo servidor de hora.
- **Etiqueta físicamente cada dispositivo** con su IP. Una pegatina en el marcador del tatami 3 que
  ponga `192.168.2.12` resuelve una incidencia en segundos.

---

## 7. Contingencia

El servidor `192.168.2.3` es un punto único de fallo: si cae, la competición se detiene. Medidas:

1. **Copia de seguridad automática cada 15 minutos** durante el evento, a un disco distinto del
   principal:

   ```bash
   pg_dump -U judo_app -F c -f "backup_$(date +%H%M).dump" JudoAdministracion
   ```

2. **Equipo de respaldo preparado en la `192.168.2.4`**, con PostgreSQL y la API ya instalados y una
   restauración probada. El procedimiento de conmutación es:

   - Restaurar la última copia en el equipo de respaldo.
   - Cambiar su IP de `192.168.2.4` a `192.168.2.3` (con el servidor original apagado, para no
     duplicar la dirección).
   - Arrancar la API.

   Al usar el nombre `judo-server` en la configuración y no la IP, **ningún cliente necesita
   reconfigurarse**: todos siguen apuntando al mismo nombre, que ahora resuelve al equipo nuevo.

3. **Prueba la conmutación antes del evento**, al menos una vez. Un plan de contingencia sin
   ensayar no es un plan.

---

## 8. Resolución de problemas frecuentes

| Síntoma | Causa probable | Comprobación |
|---|---|---|
| Un puesto no conecta, el resto sí | IP mal escrita o duplicada | `ipconfig` en ese puesto; `arp -a` en el servidor |
| Todos pierden la conexión a la vez | Servidor caído, cable del switch, o corte eléctrico | `ping 192.168.2.3` desde cualquier puesto |
| Un puesto funciona de forma intermitente | Dirección IP duplicada con otro dispositivo | `nmap -sn 192.168.2.0/24` (§5.2) |
| `ping 192.168.2.3` va pero la app no conecta | Firewall del servidor, o la API no está arrancada | `Test-NetConnection judo-server -Port 8443` |
| Un móvil tumba un puesto al conectarse al Wi-Fi | Pool DHCP solapado con el rango estático | Revisar §1.2 en el router |
| Error de certificado al abrir la app | El certificado no está instalado en ese cliente, o se emitió para la IP en vez del nombre | Revisar §4 |
| La app conecta pero no ve los cambios de otros | Problema de la capa de aplicación, no de red | Ver `03-Arquitectura-Cliente-Servidor.md` |
