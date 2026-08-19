# Arquitectura cliente-servidor

Cómo está repartido el trabajo entre el servicio y la aplicación de escritorio, qué decide cada uno y
qué queda todavía por migrar. Es el documento al que apuntan los avisos del código y de las otras
guías cuando algo depende de esta separación.

No es una guía de instalación: para poner esto en marcha, la
[01-Guía-de-Instalación.md](01-Guía-de-Instalación.md). Para las direcciones, los puertos y el
certificado, la [02-Red-y-Direccionamiento-IP.md](02-Red-y-Direccionamiento-IP.md).

---

## 1. Los procesos y quién habla con quién

```
  Puestos .5 – .9                      Servidor .3  (y anfitrión)
  ┌─────────────┐                      ┌─────────────────────────────────────┐
  │ Escritorio  │                      │  ┌─────────────┐                    │
  └──────┬──────┘   HTTPS 8443         │  │ Escritorio  │                    │
         ├──────────────────────────┐  │  └──┬───────┬──┘                    │
  ┌──────┴──────┐   + WebSocket     │  │     │       └────────────┐          │
  │ Escritorio  │                   │  │     │ HTTPS localhost    │ directo  │
  └──────┬──────┘                   │  │     ▼                    ▼  (§5)    │
         └──────────────────────────┼──┼─▶┌─────┐            ┌────────────┐  │
                                    └──┼─▶│ API │───────────▶│ PostgreSQL │  │
                                       │  └─────┘  judo_api  └────────────┘  │
                                       │                     escucha solo    │
                                       │                     en localhost    │
                                       └─────────────────────────────────────┘
```

Tres reglas que explican casi todo lo demás:

1. **Solo el servicio abre PostgreSQL.** La base de datos escucha únicamente en `localhost` y su
   contraseña no sale de ese equipo: ningún puesto, marcador ni pantalla la conoce.
2. **Los clientes solo hablan HTTPS con el servicio.** Peticiones normales para leer y escribir, y un
   WebSocket por el que **solo reciben**: nunca mandan nada por ahí, para que toda escritura pase por
   las mismas comprobaciones de rol y de concurrencia.
3. **La única excepción es el propio equipo servidor**, que además de la API tiene la base de datos a
   mano. De ahí sale todo lo del §5.

| Proceso | Proyecto | Dónde corre |
|---|---|---|
| Servicio (API) | `JudoAdministracion.Api` | Solo el servidor `192.168.2.3` |
| Aplicación de escritorio | `JudoAdministracion.csproj` (raíz) | Puestos `.5`–`.9` y el anfitrión |
| Cliente HTTP + WebSocket | `JudoAdministracion.Client` | Dentro de la aplicación |
| Modelos y contratos compartidos | `JudoAdministracion.Shared` | Dentro de los dos |
| Acceso a datos | `JudoAdministracion.Datos` | Dentro del servicio, y **de momento** también del escritorio (§5) |

---

## 2. El servicio

### 2.1 La inicialización del esquema la hace **solo** el servidor, una vez

Al arrancar, y si `Servidor:InicializarBaseDeDatos` está en `true`, el servicio crea las tablas, las
funciones de sorteo y propagación, los disparadores de tiempo real y siembra los datos básicos
(`DatabaseInitializer` y `AvisosPostgres.InstalarDisparadoresAsync`).

**Antes lo hacía cada cliente en cada arranque.** Con cinco puestos encendiéndose a la vez, eso eran
cinco procesos redefiniendo las mismas funciones de PostgreSQL al mismo tiempo. Ahora lo hace un solo
proceso, una sola vez, y `DatabaseInitializer` además toma un *advisory lock* por si acaso.

De ahí sale el baile de roles de la instalación, que no es una manía sino una consecuencia directa:

| Momento | `ConnectionString` | `InicializarBaseDeDatos` |
|---|---|---|
| Primer arranque, o actualización con cambios de esquema | `judo_owner` | `true` |
| Competición | `judo_api` | `false` |

Los dos valores van **juntos**: con `judo_api` y la inicialización activada, el arranque falla con
permiso denegado, porque ese rol precisamente no puede tocar el esquema. `preparar-servidor` hace el
cambio solo (guía 01, §3.6); en una actualización hay que repetirlo a mano (guía 01, §7).

### 2.2 Configuración

Toda en la sección `Servidor` de `appsettings.Local.json`, junto al ejecutable (`OpcionesServidor`):

| Clave | Para qué |
|---|---|
| `Url` | Dónde escucha. `https://0.0.0.0:8443` en competición |
| `CertificadoPfx` / `CertificadoPassword` | El certificado, si `Url` es HTTPS |
| `ConnectionString` | PostgreSQL. Siempre `localhost`, y con `judo_api` en competición |
| `ClaveFirmaTokens` | Firma de las sesiones. Mínimo 32 caracteres y **estable entre reinicios** |
| `HorasValidezToken` | 16 por defecto: una jornada larga sin volver a pedir la contraseña |
| `IpsAnfitrion` | Direcciones que cuentan como anfitrión además de la propia máquina (§3.3) |
| `InicializarBaseDeDatos` | §2.1 |

Las **variables de entorno mandan sobre el archivo**, y no al revés. Es deliberado: `Program.cs`
vuelve a registrar el proveedor de entorno *después* de `appsettings.Local.json`, y eso es lo que
permite arrancar la API atada solo a *loopback* —como hace el botón de la aplicación de escritorio,
con `Servidor__Url`— sin reescribirle su configuración ni dejar rastro.

### 2.3 Tiempo real

Un cambio hecho en un puesto aparece en los demás sin que nadie refresque nada. La cadena:

```
UPDATE/INSERT/DELETE ──▶ disparador ──▶ pg_notify('judo_cambios') ──▶ EscuchaCambiosPostgres
                                                                          │
   pantalla del puesto ◄── WebSocket /ws/eventos/{id} ◄── CentroDeAvisos ◄─┘
```

Dos decisiones de diseño que se notan cuando la competición va cargada:

- **Un aviso por sentencia y evento afectado, no por fila.** El sorteo de un peso inserta de una vez
  todos sus combates; con un disparador por fila serían cientos de avisos idénticos saliendo hacia
  veinte dispositivos. Con las tablas de transición se agrupan y sale uno solo.
- **`pg_notify` solo entrega al confirmar la transacción**, así que nadie recibe el aviso de un
  cambio que después se deshace.

Los disparadores se instalan en cada arranque del servicio y **no** están en `Scripts/Funciones`, a
propósito: son parte del funcionamiento en red y no del esquema. Una base de datos sin servidor
delante sigue siendo válida sin ellos.

El WebSocket va autenticado. Acepta el token en la cabecera y, **solo en las rutas `/ws`**, también
en la cadena de consulta: las aplicaciones de marcador y pantalla abrirán la conexión desde entornos
que no siempre pueden poner cabeceras.

---

## 3. Quién puede hacer qué

### 3.1 Sesiones

`POST /api/auth/login` devuelve un JWT firmado con `ClaveFirmaTokens`, con el identificador, el
correo, el nombre y el rol del usuario. Sin margen de gracia en la expiración (`ClockSkew` a cero):
los relojes de la red van por NTP, así que la caducidad es la que dice ser.

Cambiar `ClaveFirmaTokens` invalida **todas** las sesiones abiertas. Por eso `preparar-servidor` no
la toca al reejecutarse sobre un servidor ya montado.

### 3.2 Roles

| Rol | Quién | Política | Qué puede |
|---|---|---|---|
| `admin` | Responsable de la competición | `Administracion` | Todo: configuración del evento y datos maestros |
| `operador` | Puestos `.5`–`.9` | `Operacion` | Participantes, pesaje, sorteo, orden de combates y resultados |
| `marcador` | Marcadores de tatami `.10`–`.19` | `Resultados` | Solo anotar el resultado de un combate |

Un usuario por persona y no uno compartido: las tablas guardan `usuario_insert` y `usuario_update`, y
con una cuenta común esa traza no vale para nada.

### 3.3 El anfitrión

Hay operaciones que afectan a toda la competición a la vez y están reservadas al equipo que *hostea*
la aplicación, el **anfitrión**. Ahora mismo son dos, las dos sobre eventos:

| Operación | Por qué está reservada |
|---|---|
| `PUT /api/eventos/{id}/activo` — activar un evento | Le cambia bajo los pies la pantalla a todos los demás puestos |
| `DELETE /api/eventos/{id}` — eliminar un evento | Arrastra participantes y combates por `ON DELETE CASCADE` |

Las dos exigen **además** rol `admin`: ser anfitrión no da permisos, los restringe.

**Quien decide es el servidor, mirando por dónde ha entrado la petición**, no un rol ni una marca que
mande el cliente. Un puesto no puede declararse anfitrión. `Anfitrion.EsConexionDelAnfitrion` acepta
tres casos, en este orden:

1. La conexión llega por *loopback* (`127.0.0.1` / `::1`). **Es el caso normal**, y por eso la
   aplicación del anfitrión apunta a `https://localhost:8443` y no a `https://judo-server:8443`.
2. La conexión llega desde una de las propias direcciones de red del servidor —el anfitrión apuntó al
   nombre en vez de a `localhost`, y su petición salió y volvió a entrar—. Sigue siendo la misma
   máquina.
3. La dirección está declarada en `IpsAnfitrion`, para cuando el anfitrión es otro equipo. Es una
   decisión deliberada y conviene que quede escrita en la configuración del servidor.

Si enumerar las interfaces de red falla, **no** es anfitrión: se prefiere negar de más y que el
usuario apunte a `localhost`.

> Esto no es una frontera de seguridad fuerte y no pretende serlo. Falsearlo desde otro equipo
> exigiría suplantar la dirección del servidor y sostener el diálogo TCP, muy lejos del riesgo que
> previene: que un compañero toque sin darse cuenta algo que afecta a todos.

---

## 4. Dos puestos editando lo mismo

Con un solo puesto no hacía falta; con cinco personas y diez marcadores a la vez, sí. El mecanismo es
**bloqueo optimista** sobre la columna `fecha_update` que ya llevan todas las tablas:

1. El cliente manda la marca de tiempo que traía la fila cuando la leyó (`IPeticionVersionada`).
2. El servidor la mete en el `WHERE` del `UPDATE`.
3. Si la fila cambió entretanto, el `UPDATE` no afecta a ninguna fila y responde **409** con un
   `ConflictoEdicion`: qué se intentaba editar, quién se adelantó y cuándo.

La aplicación lo traduce a un aviso con nombre y apellidos —«*lo ha modificado María López mientras
lo tenías abierto*»— en lugar de un error genérico, y recarga los datos.

Solo lo implementan las escrituras que **editan una fila existente**. Las que insertan, y las que
reescriben un bloque entero calculado por el servidor —el sorteo, por ejemplo—, no lo necesitan.

---

## 5. Lo que todavía va directo a PostgreSQL

La migración a la API no está terminada. Lo que queda fuera va **directo a la base de datos**, y por
eso solo funciona en el equipo servidor, que es el único con `ConnectionString` configurada.

En un puesto de la red no se registra siquiera la fábrica de conexiones, así que esas pantallas
fallan de forma evidente en vez de intentar alcanzar una base de datos que no deberían ver:

> Esta pantalla todavía no funciona en red: solo puede usarse en el equipo servidor.

### Datos maestros

Los datos básicos —continentes, países, comunidades, ciudades, clubes, categorías con sus pesos,
funciones y sistemas de competición— tienen las dos vías, y no por descuido:

| | Vía | Quién |
|---|---|---|
| **Leerlos** | `GET /api/datos/…` | Todos los puestos, para llenar los desplegables |
| **Mantenerlos** | Directo a PostgreSQL | Solo el servidor, desde la rueda dentada del *login* |

El mantenimiento sigue siendo directo porque es **una tarea de preparación anterior a cualquier
evento**: se hace sobre una base de datos recién creada, antes de que exista un evento y a veces
antes de que exista un usuario distinto del de fábrica. No puede depender de tener sesión abierta
contra la API, porque en ese momento todavía no la hay.

Por el mismo motivo va directo el **alta de usuarios** desde la pantalla de *login*: sobre una base
recién creada el único usuario es `admin@judo.com`, y dar de alta a los compañeros desde dentro
obligaría a entrar con él, que es justo el que hay que dejar de usar.

Por eso el botón de **Datos básicos** de la rueda dentada solo aparece donde hay base de datos a
mano, y por eso el `appsettings.Local.json` del anfitrión lleva cadena de conexión.

### Las fases

| Fase | Qué | Estado |
|---|---|---|
| **1** | Autenticación, contexto de evento, datos maestros de lectura, banderas | Migrado |
| **2** | Eventos, participantes, pesaje, sorteo, combates, informes, tiempo real | Migrado |
| **3** | Las pantallas del escritorio que todavía piden `DbConnectionFactory` | **Pendiente** |

La fase 3 es la que sostiene todo lo de esta sección. Las pantallas implicadas son las que en
`MainWindowViewModel` llaman a `FabricaDirecta()`: eventos, participantes, pesaje, sorteo y combates
—que ya tienen su endpoint y lo usan, pero conservan la conexión directa para lo que aún no ha
pasado—, más los datos maestros y el alta de usuarios descritos arriba.

**Cuando se cierre la fase 3 desaparecen tres cosas a la vez**, y ése es el modo de saber que está
terminada:

- La referencia del proyecto de escritorio a `JudoAdministracion.Datos`.
- `ConnectionString` del `appsettings.Local.json` de la aplicación, en todos los equipos incluido el
  anfitrión.
- El método `FabricaDirecta()` y el aviso «Esta pantalla todavía no funciona en red».

Mientras tanto, y por eso lo dice la guía de instalación, **lo razonable es que el anfitrión sea el
propio servidor**: es el único equipo donde esas pantallas funcionan.

---

## 6. Dónde mirar cada cosa

| Qué | Archivo |
|---|---|
| Arranque, políticas y registro de endpoints | `JudoAdministracion.Api/Program.cs` |
| Configuración del servicio | `JudoAdministracion.Api/Seguridad/OpcionesServidor.cs` |
| Sesiones y tokens | `JudoAdministracion.Api/Seguridad/ServicioTokens.cs` |
| El anfitrión | `JudoAdministracion.Api/Seguridad/PoliticaAnfitrion.cs` |
| Los endpoints, por áreas | `JudoAdministracion.Api/Endpoints/` |
| Disparadores y WebSocket | `JudoAdministracion.Api/TiempoReal/` |
| Contratos compartidos | `JudoAdministracion.Shared/Contratos/` |
| Cliente HTTP y suscripción | `JudoAdministracion.Client/` |
| Configuración de la aplicación | `Services/Configuracion/ConfiguracionApp.cs` |
| Arrancar y parar la API desde la aplicación | `Services/Servidor/ServicioApiLocal.cs` |
| Traducción de fallos de arranque | `JudoAdministracion.Api/DiagnosticoArranque.cs` |
