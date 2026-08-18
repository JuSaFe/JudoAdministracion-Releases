# Guía de instalación — servidor y puestos

Cómo se pone en marcha JudoAdministración en equipos reales, desde una máquina recién formateada
hasta poder iniciar sesión desde un puesto de la red. Cubre Windows, macOS y Linux.

Los paquetes de instalación se generan según la
documentación interna de empaquetado. El direccionamiento IP, los
puertos y el cortafuegos están en la
[02-Red-y-Direccionamiento-IP.md](02-Red-y-Direccionamiento-IP.md); aquí se dan por hechos y solo se
referencian.

Los comandos de PostgreSQL, del certificado y de verificación de este documento están probados; los
específicos de un sistema operativo concreto están marcados.

---

## 1. Qué se instala y en qué orden

| Equipo | PostgreSQL | Servicio (API) | Aplicación de escritorio |
|---|---|---|---|
| **Servidor** `192.168.2.3` | Sí | Sí | Solo si además es el anfitrión (§5) |
| **Puestos** `192.168.2.5`–`.9` | No | No | Sí |
| **Marcadores y pantallas** | No | No | Aplicaciones pendientes de desarrollo |

El orden **no** es negociable, porque cada paso necesita el anterior:

```
1. Red y direcciones IP  ────────────▶ doc 02
2. PostgreSQL en el servidor  ───────▶ §3.1  ┐
3. Base de datos y roles  ───────────▶ §3.2, §3.3
4. Certificado HTTPS  ───────────────▶ §3.4  ├─ los hace el guion de §3
5. Servicio: primer arranque  ───────▶ §3.5, §3.6   (crea el esquema)
6. Servicio como servicio del sistema ▶ §3.7  ┘
7. Cortafuegos  ─────────────────────▶ §3.8
8. Usuarios  ────────────────────────▶ §3.9
9. Puestos  ─────────────────────────▶ §4
```

Los pasos 2 a 6 están automatizados en `Empaquetado/servidor/preparar-servidor.sh` (o `.ps1` en
Windows); ver el principio de §3.

Instalar un puesto antes de tener el servidor en pie no adelanta nada: no hay forma de comprobar que
funciona.

---

## 2. Requisitos previos

### 2.1 En el servidor

| Requisito | Versión | Notas |
|---|---|---|
| **PostgreSQL** | 18 recomendada | Es la que instalan los guiones. Funciona desde la **13** (ver §3.3); en la 14 y anteriores la separación de roles queda coja |
| **Módulos `contrib`** | La del servidor | Aportan `unaccent` y `pgcrypto`. En Windows y macOS vienen incluidos; en Linux es un paquete aparte |
| **OpenSSL** | Cualquiera | Solo para generar el certificado (§3.4). Windows lo trae con Git para Windows |
| **.NET Runtime** | — | **No hace falta** con los paquetes autocontenidos de la doc 00. Ver §2.3 |

El servidor **no** necesita salida a Internet para funcionar, solo para descargar los instaladores.

### 2.2 En los puestos

Nada, con los paquetes autocontenidos. Sí se necesita:

- El **certificado del servidor** (`judo-server.crt`) instalado como raíz de confianza (§4.2).
- La línea del archivo *hosts* apuntando `judo-server` al `192.168.2.3` (doc 02, §2.2).

### 2.3 Si se usan paquetes **no** autocontenidos

La doc 00 recomienda publicar autocontenido precisamente para no tener esta conversación en el
pabellón. Si por tamaño de descarga se opta por lo contrario, entonces hay que instalar el runtime en
cada equipo, y no es el mismo en el servidor que en los puestos:

| Equipo | Runtime | Descarga |
|---|---|---|
| Servidor (API) | **ASP.NET Core Runtime 9** | `dotnet-runtime` + `aspnetcore-runtime` |
| Puestos (escritorio) | **.NET Runtime 9** | `dotnet-runtime` a secas |

La aplicación de escritorio usa Avalonia, no WPF, así que **no** necesita el *Desktop Runtime* de
Windows: le basta el runtime normal. En Linux, además, harían falta las bibliotecas del sistema que
el `.deb` declara como dependencias (doc 00, §7.2): `libx11-6`, `libice6`, `libsm6`,
`libfontconfig1`, `libicu*`.

---

## 3. Instalación del servidor

Ejemplo a lo largo de toda la sección: el servidor es el `192.168.2.3` y responde al nombre
`judo-server`.

### La vía rápida: un solo guion

Todo lo que describe esta sección —de §3.1 a §3.7— está automatizado. **El guion viene dentro del
propio paquete del servicio**, junto al ejecutable y a la carpeta `Despliegue` con el SQL de roles
que necesita: no hay que descargar nada más ni clonar el repositorio. En un servidor recién
formateado, con el paquete ya descomprimido en su sitio:

```bash
# macOS y Linux
cd /opt/judoadministracion-api
sudo ./preparar-servidor.sh --instalar-postgresql --instalar-servicio
```

```powershell
# Windows, en PowerShell abierto COMO ADMINISTRADOR
cd "C:\Program Files\JudoAdministracionServidor"
powershell -ExecutionPolicy Bypass -File .\preparar-servidor.ps1 -InstalarPostgresql -InstalarTarea
```

**La carpeta donde se descomprime el paquete no es indiferente**: `/opt/judoadministracion-api` en
macOS y Linux, `C:\Program Files\JudoAdministracionServidor` en Windows. Es la ruta en la que la
propia aplicación de escritorio busca el servicio para arrancarlo ella sola cuando el equipo que la
ejecuta es también el servidor (doc 00, §8.1); si el `.zip` se descomprime en Descargas y se lanza
desde ahí —fácil de que pase con un doble clic sin fijarse en el destino—, el guion prepara el
servidor igual de bien, pero **avisa** de que la carpeta no es la esperada y de que hay que moverla
antes de que llegue el día del campeonato y la aplicación no encuentre el servicio sola. El aviso
sólo importa si ese mismo equipo va a ejecutar también la aplicación; si es un servidor sin
pantalla, ignorarlo no tiene consecuencias.

En Windows, `-ExecutionPolicy Bypass` **no es opcional**: sin él sale *«la ejecución de scripts está
deshabilitada en este sistema»*, porque ésa es la directiva de fábrica y además un `.ps1` recién
descomprimido de un `.zip` descargado lleva la marca de Internet. Afecta sólo a esa ejecución, no al
equipo — lo que **no** hay que hacer es `Set-ExecutionPolicy`, que cambia la directiva del equipo
entero y luego nadie la deja como estaba.

`-InstalarPostgresql` y `-InstalarTarea` piden «instala todo lo que haga falta» sin tener que saber
qué le falta al servidor de una vez anterior: repetirlos no hace daño si ya está hecho —el guion
busca `psql.exe` y la tarea programada existente antes de tocar nada, y si ya están, no vuelve a
instalarlos—. Lo que **no** hace por defecto, con o sin esos dos flags, es tocar una configuración o
un certificado ya existentes: eso sólo pasa si se pide expresamente con `-ForzarConfiguracion` o
`-RegenerarCertificado`.

Si el paquete se ha descomprimido en otra carpeta, el guion se da cuenta: la carpeta del servicio es
aquella en la que está él mismo. `--dir` (o `-Dir`) sólo hace falta para configurar un servicio que
esté en otro sitio distinto del guion.

En nueve pasos deja el servidor listo: instala PostgreSQL si falta, crea la base de datos con la
codificación correcta, crea los roles con contraseñas generadas al azar, instala las extensiones,
emite el certificado con todos los nombres que hacen falta, escribe la configuración, **hace por su
cuenta el cambio de rol del primer arranque** (§3.6, que es el paso donde más fácil es equivocarse),
comprueba que `judo_api` puede leer y no puede tocar el esquema, y registra el servicio del sistema.
Al terminar deja las contraseñas en `~/judo-credenciales-servidor.txt`.

Se puede volver a ejecutar tantas veces como se quiera. Lo que ya está hecho lo respeta, y en
concreto **no toca la configuración ni las contraseñas de un servidor ya montado**: cambiarlas
dejaría al servicio sin poder entrar en la base de datos y cerraría las sesiones abiertas. `--ayuda`
lista todas las opciones.

> El guion de macOS y Linux está probado de principio a fin. El de Windows sigue la misma lógica y
> usa comandos estándar del sistema, pero **no se ha podido probar en un Windows real**: la primera
> vez, ejecútalo leyendo lo que dice cada paso.

**El resto de la sección sigue siendo útil**, y por eso está: explica *qué* hace cada paso y *por
qué*, que es lo que se necesita cuando algo falla, cuando hay que hacerlo a mano, o cuando toca
entender un servidor que montó otra persona. Lo que el guion **no** hace queda en §3.8 (cortafuegos)
y §3.9 (usuarios).

### 3.1 PostgreSQL

**Windows.** Instalador de EDB desde
[postgresql.org/download/windows](https://www.postgresql.org/download/windows/). Durante el
asistente:

- Componentes: **PostgreSQL Server** y **Command Line Tools** (contiene `psql`). *Stack Builder* no
  hace falta.
- Contraseña del superusuario `postgres`: apuntarla; se usa en §3.2 y §3.3.
- Puerto **5432**, el de por defecto.
- *Locale*: **`Spanish, Spain`** o `Default locale`; lo que no debe quedarse es `C`.

Después, añadir `psql` al PATH para no escribir la ruta completa cada vez, en PowerShell **como
administrador**:

```powershell
$env:Path += ";C:\Program Files\PostgreSQL\18\bin"
# Permanente:
[Environment]::SetEnvironmentVariable("Path",
    [Environment]::GetEnvironmentVariable("Path","Machine") + ";C:\Program Files\PostgreSQL\18\bin",
    "Machine")
```

**macOS.** Con Homebrew:

```bash
brew install postgresql@18
brew services start postgresql@18           # arranque automático al encender
echo 'export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"' >> ~/.zprofile
```

(Alternativa sin terminal: [Postgres.app](https://postgresapp.com/), que trae `contrib` incluido.)

**Linux (Debian / Ubuntu).**

```bash
sudo apt update
sudo apt install postgresql postgresql-contrib
sudo systemctl enable --now postgresql
```

`postgresql-contrib` **no es opcional**: sin él no existen `unaccent` ni `pgcrypto`, y la
inicialización del esquema falla (§3.6). En Fedora/RHEL el paquete es `postgresql-contrib` también, y
el clúster hay que inicializarlo a mano con `postgresql-setup --initdb`.

**En los tres sistemas:** PostgreSQL se queda escuchando **solo en local**, que es su configuración
de fábrica. No hay que tocar `listen_addresses` ni `pg_hba.conf`; la razón está explicada en la doc
02, §3.4.

Comprobación:

```bash
psql -U postgres -c "SELECT version();"
```

**Si ya había una versión anterior instalada.** Un salto de versión mayor (de la 14 a la 18, por
ejemplo) **no** conserva los datos por sí solo: cada versión mayor tiene su propia carpeta de datos y
la nueva arranca vacía. El camino seguro es volcar antes y restaurar después, con la versión vieja
todavía en marcha:

```bash
# 1. Con la versión ANTIGUA arrancada
pg_dumpall -U postgres > ~/copia-postgresql-antes-de-actualizar.sql

# 2. Instalar la nueva y dejar solo la nueva escuchando en el 5432
#    macOS:   brew services stop postgresql@14 && brew install postgresql@18 && brew services start postgresql@18
#    Linux:   sudo apt install postgresql-18   (y pg_upgradecluster / pg_dropcluster para la vieja)
#    Windows: instalador de EDB de la 18; el asistente NO migra, hay que restaurar el volcado

# 3. Restaurar
psql -U postgres -f ~/copia-postgresql-antes-de-actualizar.sql

# 4. Comprobar antes de borrar nada de la versión vieja
psql -U postgres -c "SELECT version();"
psql -U postgres -d JudoAdministracion -c "SELECT count(*) FROM eventos;"
```

`pg_dumpall` se lleva también los roles (`judo_owner`, `judo_api`) con sus contraseñas, así que
`appsettings.Local.json` del servidor sigue valiendo tal cual y no hay que volver a ejecutar
`preparar-servidor` con `--forzar-configuracion`. **Nunca hagas esto el día de la competición**: es la
única operación de toda esta guía que deja la base de datos inaccesible mientras dura.

### 3.2 Crear la base de datos

```bash
psql -U postgres -c "CREATE DATABASE \"JudoAdministracion\" ENCODING 'UTF8' TEMPLATE template0;"
```

**Las comillas dobles alrededor del nombre son obligatorias.** PostgreSQL pasa a minúsculas todo
identificador sin comillar, así que `CREATE DATABASE JudoAdministracion` crea
`judoadministracion` —en minúsculas— y la cadena de conexión de la aplicación, que pide
`Database=JudoAdministracion`, no la encuentra. Es un fallo que se manifiesta mucho más tarde y
cuesta relacionar con su causa.

Comprobar la codificación y la ordenación:

```bash
psql -U postgres -l
```

Debe mostrar `UTF8` y un *Collate* que acabe en `.UTF-8` (`es_ES.UTF-8`, `en_US.UTF-8`… cualquiera
sirve; el equipo de desarrollo usa `en_US.UTF-8`). Si aparece `C` o `POSIX`, los listados saldrán
ordenados de forma extraña, con los apellidos acentuados al final. Verificación directa:

```bash
psql -U postgres -d JudoAdministracion -tAc \
  "SELECT string_agg(x, ' < ' ORDER BY x) FROM (VALUES ('Ávila'),('Alicante'),('Zamora'),('Ñuño')) t(x);"
```

Correcto: `Alicante < Ávila < Ñuño < Zamora`. Si sale `Alicante < Zamora < Ávila < Ñuño`, la
ordenación es `C` y hay que recrear la base de datos con `LC_COLLATE` adecuado (se hace ahora sin
coste; después obligaría a volcar y restaurar).

### 3.3 Roles de PostgreSQL

El repositorio trae el guion listo en `JudoAdministracion.Api/Despliegue/01_roles.sql`. Crea dos
roles con propósitos distintos, y esa separación es la que hace que una contraseña filtrada no
permita alterar el esquema:

| Rol | Para qué | Puede |
|---|---|---|
| `judo_owner` | Dueño del esquema | Crear y modificar tablas, funciones y disparadores |
| `judo_api` | Con el que corre el servicio en competición | Leer y escribir datos. **No** puede tocar el esquema |

Las contraseñas se le pasan como parámetros; no están escritas dentro del archivo, que está en git:

```bash
psql -U postgres -d JudoAdministracion \
     -v clave_owner="$(openssl rand -hex 16)" \
     -v clave_api="$(openssl rand -hex 16)" \
     -f JudoAdministracion.Api/Despliegue/01_roles.sql
```

Así generadas no se pueden leer después, claro: para saberlas hay que ponerlas a mano en lugar del
`openssl rand`, o dejar que el guion de preparación las genere y las anote por ti, que es la razón
de ser de `~/judo-credenciales-servidor.txt`.

Hay que lanzarlo **con la base de datos ya creada** (§3.2), porque hace
`ALTER DATABASE … OWNER TO judo_owner`. Es idempotente: volver a ejecutarlo repone los permisos. Y
si se pasa `-v rotar_claves=off`, deja las contraseñas que ya haya y se limita a los permisos —que es
lo que interesa en un servidor ya en marcha, donde cambiar la de `judo_api` dejaría al servicio sin
poder entrar—.

Además de los roles, el guion instala las dos extensiones que hacen falta (`unaccent`, que usa la
búsqueda de nombres sin acentos, y `pgcrypto`, que hará falta en §3.9 para dar de alta usuarios). Se
crean aquí, con superusuario, para no depender de que el dueño de la base de datos pueda hacerlo.

Comprobación, tal como indica el propio guion:

```bash
psql -U judo_api -d JudoAdministracion -c "CREATE TABLE prueba (x int);"   # debe dar permiso denegado
```

Que ese comando **falle** es la señal de que los permisos están bien puestos, y merece la pena
insistir en la comprobación porque **durante mucho tiempo no falló**. En PostgreSQL 14 y anteriores,
el esquema `public` concede `CREATE` a `PUBLIC` —es decir, a cualquier rol— de fábrica, así que
`judo_api` podía crear tablas pese a no tener ningún permiso que se lo permitiera y la separación de
los dos roles era decorativa. El guion lo corrige con un `REVOKE CREATE ON SCHEMA public FROM
PUBLIC`; en la 15 y posteriores viene revocado de serie. Si has preparado un servidor con una versión
anterior de este archivo, vuelve a ejecutarlo (`-v rotar_claves=off`) y comprueba la línea de arriba.

> **Sobre la versión mínima de PostgreSQL.** El esquema declara
> `CREATE EXTENSION IF NOT EXISTS unaccent`, y quien lo ejecuta al arrancar es `judo_owner`, que no
> es superusuario. Desde PostgreSQL 13 `unaccent` y `pgcrypto` son extensiones *de confianza* y el
> dueño de la base de datos puede instalarlas; en versiones anteriores hace falta superusuario. Por
> eso las crea este guion y no el arranque del servicio: así funciona en cualquier versión. Sueltas,
> si hiciera falta:
>
> ```bash
> psql -U postgres -d JudoAdministracion -c "CREATE EXTENSION IF NOT EXISTS unaccent;"
> psql -U postgres -d JudoAdministracion -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
> ```

### 3.4 Certificado HTTPS

La API habla HTTPS incluso dentro de la red local, porque por ella viajan credenciales y resultados
de combate (doc 02, §4). Como no hay dominio público, el certificado es autofirmado y se genera **una
sola vez** en el servidor.

**`dotnet dev-certs https` no sirve aquí:** solo emite certificados para `localhost`, y los puestos
conectan a `judo-server`. La validación fallaría en los cinco. Con OpenSSL, en cambio, se controla la
lista de nombres del certificado.

Crear `san.cnf`:

```ini
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[dn]
CN = judo-server

[ext]
# Todos los nombres y direcciones por los que se puede llegar al servidor. Si falta uno, el cliente
# que use ese nombre rechaza la conexión.
subjectAltName   = DNS:judo-server, DNS:localhost, IP:192.168.2.3, IP:127.0.0.1
basicConstraints = critical, CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
```

Generar el certificado y el `.pfx` que lee el servicio:

```bash
# Cinco años: cubre de sobra la vida útil de esta instalación
openssl req -x509 -newkey rsa:2048 -sha256 -days 1825 -nodes \
    -keyout judo-server.key -out judo-server.crt -config san.cnf

openssl pkcs12 -export -out judo-server.pfx \
    -inkey judo-server.key -in judo-server.crt \
    -passout pass:LA_CONTRASEÑA_DEL_PFX
```

Comprobar que los nombres han quedado dentro:

```bash
openssl x509 -in judo-server.crt -noout -subject -ext subjectAltName
```

```
subject=CN=judo-server
X509v3 Subject Alternative Name:
    DNS:judo-server, DNS:localhost, IP Address:192.168.2.3, IP Address:127.0.0.1
```

Quedan tres archivos con destinos distintos:

| Archivo | Dónde va | Advertencia |
|---|---|---|
| `judo-server.pfx` | Solo el servidor, junto al servicio | Lleva la clave privada. **No sale del servidor** |
| `judo-server.key` | Se guarda con las copias de seguridad | Clave privada suelta |
| `judo-server.crt` | Se copia a **todos** los puestos (§4.2) | Es la parte pública; se puede repartir sin problema |

`*.pfx` está en el `.gitignore` del repositorio, así que no hay riesgo de subirlo por descuido.

### 3.5 Instalar el servicio y configurarlo

Descomprimir el paquete `api-<sistema>` de la doc 00 en su sitio definitivo:

| Sistema | Ruta recomendada |
|---|---|
| Windows | `C:\Program Files\JudoAdministracionServidor\` |
| macOS | `/opt/judoadministracion-api/` |
| Linux | `/opt/judoadministracion-api/` |

Copiar `judo-server.pfx` a esa misma carpeta y crear ahí `appsettings.Local.json`.

**Para el primer arranque, la cadena de conexión usa `judo_owner`**, porque es lo que va a crear el
esquema:

```json
{
    "Servidor": {
        "Url": "https://0.0.0.0:8443",
        "CertificadoPfx": "judo-server.pfx",
        "CertificadoPassword": "LA_CONTRASEÑA_DEL_PFX",
        "ConnectionString": "Host=localhost;Port=5432;Database=JudoAdministracion;Username=judo_owner;Password=LA_DE_OWNER",
        "ClaveFirmaTokens": "una-cadena-larga-y-aleatoria-de-al-menos-32-caracteres",
        "HorasValidezToken": 16,
        "IpsAnfitrion": [],
        "InicializarBaseDeDatos": true
    }
}
```

Cuatro valores que merecen atención:

- **`Url`**: `0.0.0.0` significa «todas las interfaces». Con `localhost` el servicio solo se vería a
  sí mismo y ningún puesto llegaría.
- **`ClaveFirmaTokens`**: con la que se firman las sesiones. Mínimo 32 caracteres —el servicio se
  niega a arrancar con menos— y **estable entre reinicios**: si cambia, todas las sesiones abiertas
  dejan de valer y hay que volver a iniciar sesión en los cinco puestos. En mitad de una competición
  no interesa. Una forma cómoda de generarla:
  ```bash
  openssl rand -base64 48
  ```
- **`Host=localhost`** en la cadena de conexión, nunca la IP de red. La base de datos no se expone.
- **`InicializarBaseDeDatos`**: `true` ahora; en §3.6 pasa a `false`.

`Windows`: cuidado con el editor de texto. El archivo debe quedar en UTF-8 sin BOM; el Bloc de notas
moderno lo hace bien, pero conviene comprobarlo si el servicio se queja de la configuración.

### 3.6 Primer arranque: crear el esquema

Ejecutar el servicio **a mano**, en primer plano, para ver lo que hace:

```bash
cd /opt/judoadministracion-api        # o la carpeta correspondiente
./JudoAdministracion.Api             # Windows: .\JudoAdministracion.Api.exe
```

En este arranque el servicio crea las tablas, las funciones de sorteo y propagación, los
disparadores de tiempo real y los datos básicos (continentes, países, comunidades, ciudades, clubes,
categorías con sus pesos, funciones y sistemas de competición), además del usuario administrador
inicial. Debe terminar mostrando:

```
info: JudoAdministracion.Api.TiempoReal.EscuchaCambiosPostgres[0]
      Escuchando avisos de cambio en el canal judo_cambios.
info: Microsoft.Hosting.Lifetime[14]
      Now listening on: https://0.0.0.0:8443
info: Microsoft.Hosting.Lifetime[0]
      Application started. Press Ctrl+C to shut down.
```

Sin cerrarlo, desde otra terminal del mismo equipo:

```bash
curl --cacert judo-server.crt https://localhost:8443/api/estado
```

```json
{"estado":"ok"}
```

Y comprobar que el esquema está:

```bash
psql -U judo_owner -d JudoAdministracion -c "\dt"        # 14 tablas
psql -U judo_owner -d JudoAdministracion -c "SELECT count(*) FROM paises;"
```

Ahora se para el servicio (`Ctrl+C`) y **se cambian dos valores** de
`appsettings.Local.json` para la configuración definitiva:

```json
"ConnectionString": "Host=localhost;Port=5432;Database=JudoAdministracion;Username=judo_api;Password=LA_DE_API",
"InicializarBaseDeDatos": false
```

Este paso no es opcional y conviene entender por qué:

- Con `judo_api` **y** `InicializarBaseDeDatos: true`, el servicio intenta redefinir funciones y
  disparadores en cada arranque y **falla con permiso denegado**, porque ese rol precisamente no
  puede. Los dos cambios van juntos.
- Durante la competición el servicio corre con el rol que solo puede leer y escribir datos. Si
  alguien se hiciera con esa contraseña, no podría alterar el esquema ni la lógica de sorteo que vive
  dentro de la base de datos.

Vuelve a arrancarse a mano una vez para confirmar que sigue en pie con el rol nuevo, y se comprueba
otra vez `/api/estado`.

> Cuando una versión futura cambie el esquema, se repite este baile: `judo_owner` +
> `InicializarBaseDeDatos: true` para el arranque de la actualización, y vuelta a `judo_api` +
> `false`. Está en §7.

### 3.7 Dejarlo como servicio del sistema

Para que arranque solo al encender el equipo, aunque nadie inicie sesión. Las unidades y los
comandos completos están en la doc 00:

| Sistema | Mecanismo | Dónde |
|---|---|---|
| Linux | `systemd` | doc 00, §7.3 |
| macOS | `launchd` | doc 00, §6.2 |
| Windows | Tarea programada al inicio (o servicio, con el cambio de código que se indica) | doc 00, §5.1 |

En los tres casos hay un detalle que se paga caro si se olvida: **el directorio de trabajo debe ser
la carpeta del servicio**. Tanto `judo-server.pfx` como `appsettings.Local.json` se buscan por ruta
relativa, así que un servicio que arranque en `/` no encuentra su configuración y muere al instante.

Después de configurarlo, **reiniciar el servidor** y comprobar que el servicio ha subido solo:

```bash
curl --cacert judo-server.crt https://localhost:8443/api/estado
sudo systemctl status judo-api           # Linux
sudo launchctl list | grep es.judo.api   # macOS
```

### 3.8 Cortafuegos

Abrir el **8443** solo a la subred de la competición y dejar el **5432** cerrado a todo lo que no sea
`localhost`. Los comandos por sistema están en la doc 02, §3.3, y la comprobación de que PostgreSQL
*no* responde desde fuera —que debe fallar— en la doc 02, §5.3.

### 3.9 Usuarios

La inicialización deja un solo usuario:

| Correo | Contraseña | Rol |
|---|---|---|
| `admin@judo.com` | `admin123` | `admin` |

**Cambiar esa contraseña antes de que el servidor esté en la red del pabellón.** Todavía no hay
pantalla de gestión de usuarios en la aplicación, así que las altas y los cambios se hacen por SQL.
La contraseña se guarda como hash bcrypt y `pgcrypto` genera hashes que la aplicación acepta
(comprobado: `crypt(…, gen_salt('bf', 11))` produce hashes `$2a$` que valida `BCrypt.Verify`):

```sql
-- Cambiar la contraseña del administrador
UPDATE usuarios
   SET password_hash = crypt('LA_NUEVA_CONTRASEÑA', gen_salt('bf', 11)),
       fecha_update  = NOW()
 WHERE email = 'admin@judo.com';
```

Los tres roles que entiende el servidor, y a quién corresponde cada uno:

| Rol | Quién | Qué puede hacer |
|---|---|---|
| `admin` | Responsable de la competición | Todo, incluida la configuración del evento y los datos maestros |
| `operador` | Compañeros en los puestos `.5`–`.9` | Participantes, pesaje, sorteo, orden de combates y resultados |
| `marcador` | Marcadores de tatami `.10`–`.19` | Solo anotar el resultado de los combates |

Un usuario por persona, no uno compartido: las tablas guardan quién insertó y quién modificó cada
fila (`usuario_insert` / `usuario_update`), y con una cuenta común esa traza no vale para nada.

```sql
INSERT INTO usuarios (nombre, email, password_hash, rol)
VALUES ('María López', 'maria@ejemplo.es',
        crypt('su-contraseña', gen_salt('bf', 11)), 'operador');
```

Comprobar que la contraseña funciona, desde el propio servidor:

```bash
curl --cacert judo-server.crt -X POST https://localhost:8443/api/auth/login \
     -H "Content-Type: application/json" \
     -d '{"Email":"maria@ejemplo.es","Password":"su-contraseña"}'
```

Devuelve un token y los datos del usuario. Una contraseña equivocada devuelve **401** y el mismo
mensaje que un correo inexistente, a propósito: no interesa decir qué cuentas están dadas de alta.

Hay una precaución que no se ve venir: **el nombre del sistema donde se escriben las contraseñas
importa**. Si se dan de alta usuarios desde una terminal, la contraseña queda en el historial del
intérprete de comandos y en el registro de sentencias de PostgreSQL. Para un club es aceptable;
conviene al menos borrar el historial (`history -c`) al terminar.

---

## 4. Instalación de un puesto de administración

Repetir en cada equipo `192.168.2.5`–`.9`. Son tres pasos y hay que hacer los tres.

### La vía rápida: desde la propia aplicación

Después de instalar la aplicación (§4.1), todo lo que queda se puede hacer **desde ella misma**, sin
tocar una terminal: en la pantalla de inicio de sesión, la rueda dentada de arriba a la derecha →
**Red de la competición**.

Esa pantalla está antes del login a propósito, y es la única que puede estarlo: si la red está mal no
se puede iniciar sesión, así que es el único momento en que sirve de algo. Reúne los cuatro pasos de
esta sección —dirección IP, nombre del servidor, certificado y comprobación— y trae dos cosas que
merece la pena conocer:

- **Diagnostica al entrar, sin pedir permisos.** Enseña en qué punto de la cadena está el problema:
  si este equipo tiene la IP que le toca, si llega al servidor, si el nombre resuelve, si el puerto
  está abierto y si el certificado es de confianza. Comprobar no cambia nada, así que la pantalla se
  puede abrir solo para mirar.
- **La comprobación del HTTPS la hace con el mismo `HttpClient` que usa la aplicación para conectar.**
  Lo que dice ahí es exactamente lo que la aplicación se va a encontrar, no una aproximación con otra
  herramienta que tiene sus propios almacenes de certificados.
- **Enseña qué direcciones del rango están libres.** Al elegir la IP, las que ya responden salen en
  rojo y marcadas «EN USO», y con una de esas seleccionada no deja aplicar. Es la defensa contra el
  duplicado de la doc 02, §5.2, que es el fallo más difícil de diagnosticar de la competición. Solo
  puede saberlo si el equipo ya está en esa red; si no, las deja en gris en vez de darlas por libres.

La pantalla **cambia según el papel del equipo**, porque lo que necesita un puesto y lo que necesita
el servidor no es lo mismo:

| | Puesto | Servidor |
|---|---|---|
| Dirección IP fija | Sí, del `.5` al `.9` | Sí, la `.3` |
| Nombre `judo-server` en *hosts* | Sí | No: se conecta a sí mismo por `localhost` |
| Certificado | Lo **instala**, traído del servidor | Lo **emite**, y lo instala también aquí |

En el servidor, la sección 2 pasa a ser **«Generar certificado»**: emite los tres archivos de §3.4
sin salir de la aplicación y sin pedir permisos de administrador —emitir no los necesita; instalarlo
después, sí—. Al terminar enseña la contraseña del `.pfx`, que hay que copiar al
`appsettings.Local.json` del servicio (`Servidor:CertificadoPassword`) y **no se puede volver a
averiguar**, y la ruta del `.crt`, que es el único de los tres que se reparte a los puestos.

Aplicar la configuración y deshacerla sí cambian el sistema, así que piden permisos de administrador
—uno por operación, no uno por cada cosa que se toca—. En el apartado 3 de esa misma pantalla está el
botón de **deshacer**, que devuelve el equipo a como estaba.

> La rueda dentada tiene ahora dos entradas y con condiciones distintas: **Red** aparece en todos los
> equipos, y **Datos básicos** solo en el servidor, porque va directa a la base de datos.

### La otra vía rápida: los guiones

Sirven para lo mismo y son intercambiables con la pantalla —comparten el archivo donde guardan la
configuración anterior y la marca de las líneas del archivo *hosts*, así que se puede configurar por
una vía y deshacer por la otra—. Hacen falta cuando la aplicación todavía no está instalada, o para
equipos que no la llevan (marcadores, pantallas):

```bash
# macOS y Linux
sudo Empaquetado/red/configurar-red.sh                                   # IP fija + hosts
sudo Empaquetado/puesto/preparar-puesto.sh --certificado judo-server.crt  # certificado + pruebas
```

```powershell
# Windows, en PowerShell como administrador. -ExecutionPolicy Bypass es imprescindible: sin él,
# «la ejecución de scripts está deshabilitada en este sistema». Vale sólo para esa ejecución.
powershell -ExecutionPolicy Bypass -File .\Empaquetado\red\configurar-red.ps1
powershell -ExecutionPolicy Bypass -File .\Empaquetado\puesto\preparar-puesto.ps1 -Certificado judo-server.crt
```

`configurar-red` enseña las interfaces de red del equipo para elegir cuál se toca, propone la IP
libre que le corresponde al rol —del `.5` al `.9` si es un puesto— y avisa si esa dirección ya
responde. `preparar-puesto` instala el certificado, comprueba **antes** que sirve para el nombre
`judo-server` y no está caducado, y termina probando la cadena entera: llego al servidor, resuelve el
nombre, el puerto está abierto, y el HTTPS es de confianza. Cada comprobación que falla dice en qué
capa está el problema.

**Y los dos se deshacen**, que es lo que importa cuando el portátil es de alguien y esa tarde se lo
lleva a su casa:

```bash
sudo Empaquetado/puesto/preparar-puesto.sh --deshacer      # quita el certificado y la configuración
sudo Empaquetado/red/configurar-red.sh --deshacer          # devuelve la red a como estaba
```

El guion de red guarda la configuración anterior antes de tocar nada (en
`/etc/judo-red-anterior.conf`, o `C:\ProgramData\JudoAdministracion\red-anterior.json`), así que el
`--deshacer` no deja el equipo «en automático» a lo bruto: si tenía su propia IP fija y sus propios
DNS, se los devuelve tal cual. Y de `/etc/hosts` quita solo las líneas que puso él, reconocibles por
la marca `# JudoAdministracion`.

Los dos aceptan `--simular` (`-Simular`), que dice lo que harían sin cambiar nada. En
`preparar-puesto` la simulación **sí ejecuta las comprobaciones**, porque no modifican nada: es la
forma de diagnosticar un puesto ya montado sin tocarle un pelo.

> Las versiones de macOS y Linux están probadas. Las de Windows siguen la misma lógica pero **no se
> han podido probar en un Windows real**: la primera vez, `-Simular`.

El resto de la sección explica lo que hacen esos guiones, que es lo que se necesita cuando algo falla
o cuando hay que hacerlo a mano.

### 4.1 Instalar la aplicación

**Windows.** Ejecutar el `.exe` generado en la doc 00, §5. Para los cinco puestos, en modo
desatendido:

```powershell
.\JudoAdministracion-1.0.0.1-win-x64.exe /SILENT /TASKS="desktopicon"
```

Queda en `C:\Program Files\JudoAdministracion\`.

**macOS.** Abrir el `.dmg` y arrastrar la aplicación a *Aplicaciones*. Si al abrirla aparece «no se
puede comprobar si contiene malware» (Gatekeeper, doc 00, §10):

```bash
xattr -dr com.apple.quarantine /Applications/JudoAdministracion.app
```

**Linux.** Con el paquete `.deb`:

```bash
sudo apt install ./judoadministracion_1.0.0.1_amd64.deb
```

Con `apt` y no con `dpkg -i`, para que resuelva las dependencias. Queda en
`/opt/judoadministracion/` y aparece en el menú de aplicaciones. Si se usa el AppImage, basta con
`chmod +x` y ejecutarlo.

### 4.2 Instalar el certificado del servidor

Sin este paso la aplicación **no conecta**: rechaza el certificado del servidor por no conocer quién
lo emitió. Copiar `judo-server.crt` (solo el `.crt`, nunca el `.pfx`) al puesto y:

**Windows**, en PowerShell **como administrador**:

```powershell
certutil -addstore -f Root judo-server.crt
# Comprobar:
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*judo-server*" }
```

**macOS**:

```bash
sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain judo-server.crt
```

**Linux (Debian / Ubuntu)**:

```bash
sudo cp judo-server.crt /usr/local/share/ca-certificates/judo-server.crt
sudo update-ca-certificates
```

En los tres casos se instala **para todo el equipo**, no para el usuario: la aplicación puede acabar
ejecutándose con otra cuenta. En los tres, además, .NET usa el almacén del sistema, así que con esto
la aplicación ya confía en el servidor sin más configuración.

Comprobación, sin abrir la aplicación:

```bash
curl https://judo-server:8443/api/estado          # sin --cacert: si responde, la confianza está puesta
```

```powershell
# Windows
Invoke-RestMethod https://judo-server:8443/api/estado
```

### 4.3 El archivo *hosts*

La aplicación busca el servidor por **nombre**, no por IP, para que el plan de contingencia de la doc
02 (§7) funcione sin tocar los cinco puestos. Añadir la línea:

- Windows: `C:\Windows\System32\drivers\etc\hosts` (editar como administrador)
- macOS / Linux: `/etc/hosts`

```
192.168.2.3    judo-server
```

### 4.4 Configuración de la aplicación: normalmente, ninguna

Aquí hay una buena noticia: **un puesto no necesita archivo de configuración**. El `appsettings.json`
que viene en el paquete ya apunta a donde debe:

```json
{
    "ApiBaseUrl": "https://judo-server:8443",
    "ConnectionString": ""
}
```

Es exactamente lo que necesita un puesto de la red: el nombre del servidor y **ninguna** credencial
de base de datos. Con el certificado instalado (§4.2) y la línea de *hosts* (§4.3), la aplicación
funciona tal cual.

Solo hay que crear `appsettings.Local.json` junto al ejecutable si ese equipo se sale de lo normal:
otro puerto, otro nombre de servidor, o que sea el anfitrión (§5). Las rutas donde debe quedar el
archivo:

| Sistema | Carpeta |
|---|---|
| Windows | `C:\Program Files\JudoAdministracion\` |
| macOS | `/Applications/JudoAdministracion.app/Contents/MacOS/` |
| Linux | `/opt/judoadministracion/` |

Las tres exigen permisos de administrador para escribir en ellas, lo cual es conveniente: la
configuración de un puesto no debe poder cambiarla quien lo esté usando.

> Existen también las variables de entorno `JUDO_API_URL` y `JUDO_DB_CONNECTION`, pero **solo se
> aplican si el JSON no define ese valor** (ver `ConfiguracionApp.Cargar()`). Como el
> `appsettings.json` del paquete sí define `ApiBaseUrl`, en la práctica la vía para cambiarlo es el
> archivo. Conviene saberlo para no perder el tiempo exportando una variable que no va a tener
> efecto.

---

## 5. El equipo anfitrión

Hay operaciones que afectan a toda la competición a la vez —señaladamente **activar un evento**, que
le cambia bajo los pies la pantalla a los demás puestos— y están reservadas al equipo que *hostea* la
aplicación: el **anfitrión**. Quien decide si una petición viene del anfitrión es el servidor,
mirando por dónde ha entrado; no es un rol ni una marca que mande el cliente.

Lo normal es que el anfitrión sea el propio servidor, con la aplicación de escritorio instalada
además del servicio. En ese equipo, `appsettings.Local.json` sí es necesario:

```json
{
    "ApiBaseUrl": "https://localhost:8443",
    "ConnectionString": "Host=localhost;Port=5432;Database=JudoAdministracion;Username=judo_owner;Password=LA_DE_OWNER"
}
```

Dos cosas concretas:

- **`localhost`, no `judo-server`.** Entrando por loopback, el servidor reconoce la conexión como
  propia y habilita las operaciones reservadas. (Por eso el certificado de §3.4 incluye `localhost`
  en su lista de nombres: sin él, esta URL daría error de certificado.)
- **Aquí sí va la cadena de conexión.** Mientras quede alguna pantalla sin migrar a la API —la
  transición está descrita en `03-Arquitectura-Cliente-Servidor.md`—, esas áreas siguen yendo
  directas a PostgreSQL y solo funcionan en este equipo. En un puesto de la red darían el aviso
  «Esta pantalla todavía no funciona en red».

Si el anfitrión tuviera que ser otro equipo distinto del servidor, se declara su dirección en
`IpsAnfitrion` del `appsettings.Local.json` del **servicio**. Es una decisión deliberada y conviene
que quede escrita ahí.

---

## 5.1 Si la base de datos ya existía: «must be owner of table»

Reutilizar una base de datos que ya se venía usando —la del equipo de desarrollo, típicamente— tiene
una trampa. El guion pone la **base** a nombre de `judo_owner`, pero las **tablas de dentro** siguen
siendo de la cuenta que las creó. El primer arranque intenta ajustar el esquema y se cae con un error
que no dice de dónde viene:

```
La API se ha cerrado nada más arrancar.

MessageText: must be owner of table paises
File: aclchk.c
```

Desde la versión actual **el guion lo detecta y lo arregla solo** en el paso 4, y avisa de ello:

```
✓ 47 objetos que eran de otra cuenta pasan a judo_owner (los datos no se tocan)
```

Sólo cambia quién consta como dueño; los datos se quedan donde estaban. Si hay que hacerlo a mano,
lo importante es **no usar `REASSIGN OWNED`**: además de la base actual arrastra los objetos
compartidos del clúster, así que con una cuenta personal que sea superusuario se llevaría por
delante la propiedad de `postgres`, `template0` y `template1`. Hay que ir objeto a objeto, tablas y
vistas primero —las secuencias de columnas `serial` cambian con su tabla y no se pueden cambiar
sueltas— y después las rutinas.

---

## 6. Verificación de extremo a extremo

Con el servidor y al menos un puesto instalados, **el día antes del evento** (la lista completa de
comprobaciones de red está en la doc 02, §5).

Desde un puesto:

```bash
ping 192.168.2.3                                  # 1. llego al servidor
ping judo-server                                  # 2. resuelve el nombre  → si falla, §4.3
nc -vz judo-server 8443                           # 3. el puerto está abierto → si falla, §3.8
curl https://judo-server:8443/api/estado          # 4. HTTPS de confianza  → si falla, §4.2
```

```powershell
# Equivalentes en Windows
Test-NetConnection judo-server -Port 8443
Invoke-RestMethod https://judo-server:8443/api/estado
```

Los cuatro deben salir bien **antes** de abrir la aplicación; así, si algo falla, se sabe en qué capa
está el problema en lugar de mirar un mensaje de error genérico.

Después, con la aplicación:

1. **Inicio de sesión** con un usuario `operador` desde un puesto.
2. **Los datos maestros están ahí**: al crear un participante se ven países, comunidades, clubes y
   categorías. Si están vacíos, la siembra no llegó a completarse (§3.6).
3. **Un cambio se ve en el otro puesto.** Con dos puestos abiertos en el mismo evento, dar de alta un
   participante en uno debe aparecer en el otro **sin recargar**: es lo que confirma que el
   WebSocket y los disparadores de PostgreSQL funcionan, que es la parte que no se puede probar con
   un solo equipo.
4. **Generar un informe** (un listado de participantes) y verlo en pantalla. Ejercita la generación
   de PDF en el servidor y su rasterizado en el cliente, que es donde viven las bibliotecas nativas
   de la doc 00, §4.2.
5. **Reiniciar el servidor** y repetir el punto 1 sin tocar nada: es la prueba de que el servicio
   arranca solo (§3.7).

---

## 7. Actualizar a una versión nueva

```
1. Avisar y esperar a que nadie esté trabajando (una actualización corta las sesiones).
2. Copia de seguridad de la base de datos  ─────────▶ §8
3. Parar el servicio.
4. Reemplazar los archivos del servicio, CONSERVANDO appsettings.Local.json y judo-server.pfx.
5. Si la versión cambia el esquema: judo_owner + InicializarBaseDeDatos true, arrancar,
   comprobar, y volver a judo_api + false.                             ─────▶ §3.6
6. Actualizar la aplicación de los puestos (el instalador respeta la configuración local).
7. Verificación de §6.
```

Dos cosas que conviene tener claras:

- **El servidor se actualiza primero.** Una aplicación nueva contra un servidor viejo puede pedir
  endpoints que no existen.
- **Los cambios de esquema sobre una base de datos que ya existe no son automáticos.** Los guiones de
  `Scripts/Tablas` son `CREATE TABLE IF NOT EXISTS` y describen la forma final de cada tabla: crean
  lo que falta, pero no añaden una columna a una tabla existente. Eso se aplica a mano, con
  `judo_owner`, y es deliberado. Antes de actualizar hay que leer las notas de la versión.
- **Nunca se actualiza el día de la competición.** Con una semana de margen y una prueba real entre
  medias.

---

## 8. Copias de seguridad

Durante el evento, cada 15 minutos y a un disco distinto del principal (doc 02, §7):

```bash
pg_dump -U judo_owner -F c -f "backup_$(date +%H%M).dump" JudoAdministracion
```

Restauración:

```bash
pg_restore -U judo_owner -d JudoAdministracion --clean --if-exists backup_1230.dump
```

Junto a los volcados hay que guardar también, porque sin ellos una restauración no deja el servidor
funcionando:

- `appsettings.Local.json` del servicio (cadena de conexión y clave de firma de tokens).
- `judo-server.pfx`, `judo-server.key` y `judo-server.crt`.
- Las contraseñas de `judo_owner` y `judo_api` — el guion de preparación las deja en
  `~/judo-credenciales-servidor.txt` justamente para esto; cópialo fuera del equipo y bórralo de ahí.

Que no estén en el mismo disco que la base de datos, ni en el mismo equipo.

---

## 9. Problemas frecuentes de la instalación

| Síntoma | Causa probable | Comprobación |
|---|---|---|
| El servicio no arranca: «Falta Servidor:ConnectionString» | `appsettings.Local.json` no se está leyendo — el servicio arrancó en otro directorio | El directorio de trabajo del servicio (§3.7) |
| El servicio no arranca: «ClaveFirmaTokens debe tener al menos 32 caracteres» | La clave es corta | §3.5 |
| El servicio no arranca: «Url es HTTPS pero falta CertificadoPfx» | Falta la ruta al `.pfx`, o el archivo no está junto al ejecutable | §3.4, §3.5 |
| El servicio no arranca y en el registro pone «address already in use» | Ya hay otra copia escuchando en el 8443 (el servicio del sistema, o uno lanzado a mano) | `sudo systemctl stop judo-api`, o `pkill -f JudoAdministracion.Api` |
| Al arrancar: `password authentication failed for user "judo_api"` | Contraseña distinta de la que se puso en `01_roles.sql` | §3.3 |
| Al arrancar: `permission denied for schema public` o al crear un disparador | `judo_api` con `InicializarBaseDeDatos: true` | §3.6 — los dos valores van juntos |
| Al arrancar: `permission denied to create extension "unaccent"` | Falta `postgresql-contrib`, o PostgreSQL anterior a la 13 | §3.1, §3.3 |
| `database "JudoAdministracion" does not exist` y en `psql -l` aparece en minúsculas | Se creó sin comillas dobles | §3.2 |
| La aplicación no conecta: error de certificado | El `.crt` no está instalado en ese puesto, o el certificado no incluye el nombre por el que se conecta | §4.2, §3.4 |
| La aplicación no conecta y no hay error de certificado | El nombre no resuelve o el 8443 está cerrado | §6, pasos 2 y 3 |
| «Esta pantalla todavía no funciona en red» | Área sin migrar, abierta desde un puesto en vez del anfitrión | §5 |
| La aplicación arranca pero se cierra al abrir un informe | Publicado sin `-r <RID>`: faltan las bibliotecas nativas | doc 00, §4.2 |
| Los listados salen ordenados de forma extraña, con los acentos al final | Ordenación `C` en la base de datos | §3.2 |
| Los cambios de un puesto no se ven en otro | Capa de aplicación, no instalación | `03-Arquitectura-Cliente-Servidor.md` |
