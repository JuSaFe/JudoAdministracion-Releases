<#
.SYNOPSIS
    Deja el servidor de competición de JudoAdministración funcionando de una sola vez, en Windows.

.DESCRIPTION
    Equivalente de preparar-servidor.sh: PostgreSQL, base de datos, roles, extensiones, certificado
    HTTPS, la configuración del servicio, el esquema con sus datos básicos, la configuración de la
    aplicación de escritorio de este mismo equipo, el nombre en el archivo hosts, el cortafuegos y
    la tarea programada que lo arranca al encender el equipo.

        powershell -ExecutionPolicy Bypass -File .\preparar-servidor.ps1

    Sin ningún parámetro. Ésa es la idea: en un servidor recién formateado, esta línea es toda la
    instalación. Los parámetros que hay sirven para NO hacer algo, no para pedirlo.

    Es el equivalente ejecutable de la Documentación/01-Guía-de-Instalación.md, §3. Se lanza UNA vez,
    en el equipo servidor, antes de instalar los puestos.

    Antes de ejecutarlo hay que haber descomprimido el paquete del servicio (el api-win-x64 de la
    Documentación/00) en C:\Program Files\JudoAdministracionServidor. Este guion, el SQL de roles y
    los guiones de los puestos vienen DENTRO de ese paquete, así que lo normal es ejecutarlo desde
    ahí y no indicar -Dir.

    Windows no ejecuta guiones .ps1 con la directiva por defecto (Restricted / RemoteSigned + marca
    de Internet), así que hay que lanzarlo con -ExecutionPolicy Bypass, en PowerShell abierto como
    administrador. Bypass afecta sólo a esa invocación: no cambia la directiva del equipo. Lo que NO
    hay que hacer es Set-ExecutionPolicy, que cambia la directiva del equipo entero.

    Es idempotente: se puede volver a ejecutar sobre un servidor ya preparado. Lo que ya existe se
    respeta —la configuración y el certificado no se rehacen salvo que se pida— y lo que falta se
    crea. En particular, si ya hay configuración, las contraseñas de los roles NO se cambian: la
    configuración existente lleva la de judo_api y rotarla dejaría al servicio sin poder entrar.

    ATENCIÓN: a diferencia de la versión de macOS y Linux, este guion NO se ha podido probar en un
    Windows real. La lógica es la misma y los comandos son los estándar del sistema, pero la primera
    ejecución conviene hacerla con calma, leyendo lo que dice cada paso.

    DESINSTALAR (-Deshacer)

        powershell -ExecutionPolicy Bypass -File .\preparar-servidor.ps1 -Deshacer -Simular
        powershell -ExecutionPolicy Bypass -File .\preparar-servidor.ps1 -Deshacer

    -Deshacer BORRA LA BASE DE DATOS. Quita de este equipo, por este orden: la tarea programada, la
    base de datos y sus roles, PostgreSQL, el certificado de los almacenes del equipo, la línea del
    hosts, las reglas del cortafuegos y la carpeta del servicio con sus copias. Antes de borrar la
    base de datos saca un volcado al perfil del usuario, que es lo único que queda al terminar.

    Pruébalo SIEMPRE primero con -Simular, que enseña lo que haría sin tocar nada. Con
    -SinBaseDatos se conservan la base de datos, los roles y PostgreSQL.

    PostgreSQL solo se desinstala si en el clúster NO hay más bases de datos que las de esta
    aplicación: en un equipo que ya lo tenía puesto de antes, desinstalarlo se llevaría datos que no
    son de aquí. Si las hay, se dice y se deja el gestor donde está.

    La aplicación de escritorio no la toca: ésa se desinstala desde «Aplicaciones instaladas».

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\preparar-servidor.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\preparar-servidor.ps1 -SinCortafuegos -Si
#>

[CmdletBinding()]
param(
    [string]   $Dir             = "C:\Program Files\JudoAdministracionServidor",
    [string]   $DirAplicacion   = "C:\Program Files\JudoAdministracion",
    [string]   $Bd              = "JudoAdministracion",
    [string]   $Nombre          = "judo-server",
    [string]   $Ip              = "192.168.2.3",
    [int]      $Puerto          = 8443,
    [string]   $Superusuario    = "postgres",
    [string]   $ClavePostgres,                       # contraseña del superusuario; se pide si falta
    [string]   $ClaveOwner,
    [string]   $ClaveApi,
    [string]   $ClavePfx,

    # Todo lo de abajo es para NO hacer algo. Por defecto se hace todo.
    [switch]   $SinPostgresql,
    [switch]   $SinTarea,
    [switch]   $SinAplicacion,
    [switch]   $SinConfianza,
    [switch]   $SinHosts,
    [switch]   $SinCortafuegos,
    [switch]   $SinEsquema,

    [switch]   $RegenerarCertificado,
    [switch]   $ForzarConfiguracion,
    [switch]   $Si,

    # Desinstalar. Ver el bloque DESHACER, mas abajo: -Deshacer BORRA LA BASE DE DATOS.
    [switch]   $Deshacer,
    [switch]   $Simular,
    [switch]   $SinBaseDatos,

    # Nombres de la versión anterior, cuando había que pedir cada cosa. Ahora son el comportamiento
    # por defecto; se aceptan para no romper notas ni guiones de nadie.
    [switch]   $InstalarPostgresql,
    [switch]   $InstalarTarea,
    [switch]   $ConfiarCertificado
)

$ErrorActionPreference = "Stop"

# ── Utilidades ────────────────────────────────────────────────────────────────────────────────────

function Paso  ($t) { Write-Host ""; Write-Host "-- $t" -ForegroundColor Cyan }
function Bien  ($t) { Write-Host "   [ok] $t"    -ForegroundColor Green }
function Aviso ($t) { Write-Host "   [!]  $t"    -ForegroundColor Yellow }
function Igual ($t) { Write-Host "   [=]  $t"    -ForegroundColor Green }
function Fallo ($t) { Write-Host "   [x]  $t"    -ForegroundColor Red; exit 1 }

# Contraseñas solo con letras y números: acaban dentro de una cadena de conexión y de un JSON, y así
# no hay que preocuparse por comillas ni puntos y comas.
function GenerarClave {
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

# Sin BOM: el lector de configuración de .NET lo admite, pero un JSON con BOM da problemas en otras
# herramientas y no cuesta nada evitarlo.
function EscribirTexto ($ruta, $contenido) {
    [IO.File]::WriteAllText($ruta, $contenido, (New-Object Text.UTF8Encoding($false)))
}

# Leer un valor de un appsettings.Local.json ya escrito. No hace falta un analizador de JSON: los
# archivos que lee esto son los que escribe este mismo guion, con una propiedad por línea.
function LeerJson ($ruta, $propiedad) {
    if (-not (Test-Path $ruta)) { return $null }
    $m = [regex]::Match((Get-Content $ruta -Raw), "`"$propiedad`"\s*:\s*`"([^`"]*)`"")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Se instala en Program Files y se registra una tarea del sistema: hace falta elevación.
$identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identidad)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fallo "Abre PowerShell como administrador y vuelve a ejecutarlo."
}

# Este guion se ejecuta en dos sitios distintos y las rutas no son las mismas en uno y en otro:
#
#   - Desde el paquete descomprimido en el servidor, que es el caso normal. Ahí el guion, el .exe,
#     Despliegue\01_roles.sql y Puestos\ están todos en la misma carpeta.
#   - Desde el repositorio, que es lo que hace quien desarrolla. Ahí el SQL está en
#     JudoAdministracion.Api\Despliegue\ y el servicio, donde diga -Dir.
#
# Si no se indica -Dir y al lado del guion está el ejecutable, la carpeta del servicio es ésa.
if (-not $PSBoundParameters.ContainsKey('Dir')) {
    if (Test-Path (Join-Path $PSScriptRoot 'JudoAdministracion.Api.exe')) { $Dir = $PSScriptRoot }
}

$raiz     = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$sqlRoles = @(
    (Join-Path $PSScriptRoot 'Despliegue\01_roles.sql'),                        # dentro del paquete
    (Join-Path $Dir          'Despliegue\01_roles.sql'),                        # paquete, con -Dir
    (Join-Path $raiz         'JudoAdministracion.Api\Despliegue\01_roles.sql')  # repositorio
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$binario      = Join-Path $Dir "JudoAdministracion.Api.exe"
$config       = Join-Path $Dir "appsettings.Local.json"
$pfx          = Join-Path $Dir "$Nombre.pfx"
$crt          = Join-Path $Dir "$Nombre.crt"
$configApp    = Join-Path $DirAplicacion "appsettings.Local.json"
$hosts        = "$env:SystemRoot\System32\drivers\etc\hosts"
$marcaHosts   = "# JudoAdministracion"
$subred       = ($Ip -replace '\.\d+$', '.0') + "/24"
$credenciales = Join-Path $env:USERPROFILE "judo-credenciales-servidor.txt"
$paraPuestos  = Join-Path $env:USERPROFILE "judo-puestos"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
#  DESHACER
# ══════════════════════════════════════════════════════════════════════════════════════════════════
#
# Quita de este equipo todo lo que puso la instalacion, en el orden inverso al que lo puso. El orden
# no es cosmetico: el volcado de la base de datos tiene que salir ANTES de borrarla, y borrarla antes
# de desinstalar PostgreSQL, porque despues ya no habria con que hacer ninguna de las dos cosas.
#
# Esto BORRA LA BASE DE DATOS sin volver a preguntar. Es deliberado: -Deshacer es lo que se ejecuta
# al retirar un servidor o al devolver un equipo prestado, y dejar la base de datos ahi "por si
# acaso" convertia la desinstalacion en algo que nunca terminaba de estar hecho. El volcado del paso
# 2 es la red de seguridad, y -Simular es la forma de ver que va a pasar antes de que pase.
#
# Es un bloque autocontenido: no usa PsqlSuper ni BuscarPsql, que se definen mas abajo y ademas
# abortan al primer fallo. Un desinstalador que aborta a mitad deja el equipo peor que como estaba,
# con una tarea programada apuntando a una carpeta que ya no existe.

if ($Deshacer) {

    $script:VolcadoFinal = $null

    # ── Utilidades propias del bloque ─────────────────────────────────────────────────────────────

    # En simulacion no ejecuta nada y no imprime nada: la linea que se lee la pone ResultadoD, que es
    # la que sabe explicar que se ha hecho.
    function HacerD {
        param([scriptblock]$Orden)
        if ($Simular) { return $true }
        try { & $Orden | Out-Null; return $true } catch { return $false }
    }

    # "[ok] hecho" cuando se ha hecho, "[simulado] hecho" cuando solo se ha simulado. Un [ok] en modo
    # simulacion es una mentira, y es justo el modo en el que hay que poder confiar en lo que se lee.
    function ResultadoD ($t) {
        if ($Simular) { Write-Host "   [simulado] $t" -ForegroundColor Yellow }
        else          { Bien $t }
    }

    # Los mismos sitios que mira BuscarPsql, que esta definida mas abajo en el guion.
    function BuscarHerramientaD ($nombre) {
        $enPath = Get-Command $nombre -ErrorAction SilentlyContinue
        if ($enPath) { return $enPath.Source }
        Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\$nombre" -ErrorAction SilentlyContinue |
            Sort-Object { [int]($_.Directory.Parent.Name) } -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }

    # Las ordenes NATIVAS -psql.exe, pg_dump.exe, winget- hay que llamarlas SIEMPRE por aqui.
    #
    # El guion corre con $ErrorActionPreference = "Stop", y con ese ajuste todo lo que un programa
    # externo escriba en la salida de error se convierte en un error TERMINANTE de PowerShell. psql
    # escribe ahi hasta los avisos, asi que un "no se puede eliminar el rol judo_api porque otros
    # objetos dependen de el" -que es informacion, no una averia- se llevaba el guion por delante y
    # dejaba la desinstalacion hecha a medias, con la base ya borrada y el resto sin tocar.
    #
    # Es el equivalente del "set +e" de la version de macOS y Linux, y esta por el mismo motivo:
    # instalar a medias es peor que no instalar, pero DESINSTALAR es lo contrario. Si un rol no se
    # puede borrar, lo que hay que hacer es decirlo y seguir quitando el resto.
    #
    # Se acota a la llamada nativa y no se pone para todo el bloque a proposito: HacerD necesita que
    # los errores de los cmdlets sigan siendo terminantes para poder cazarlos con try/catch.
    function EjecutarNativoD {
        param([scriptblock]$Orden)
        $anterior = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & $Orden 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        finally { $ErrorActionPreference = $anterior }
    }

    # Como EjecutarNativoD pero devolviendo lo que haya escrito, para las consultas.
    function LeerNativoD {
        param([scriptblock]$Orden)
        $anterior = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $salida = & $Orden 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            return ($salida | Out-String).Trim()
        }
        finally { $ErrorActionPreference = $anterior }
    }

    # psql tolerante: devuelve la salida y NO aborta el guion si falla, al contrario que PsqlValor.
    function PsqlD ($consulta) {
        if (-not $psqlD) { return $null }
        return (LeerNativoD { & $psqlD -U $Superusuario -d postgres -tAc $consulta })
    }

    function EjecutarSqlEnD ($base, $sql) {
        if ($Simular) { return $true }
        return (EjecutarNativoD { & $psqlD -U $Superusuario -d $base -v ON_ERROR_STOP=1 -c $sql })
    }

    function EjecutarSqlD ($sql) { return (EjecutarSqlEnD "postgres" $sql) }

    # Quitar un rol de PostgreSQL no es solo DROP ROLE: mientras queden objetos suyos, o permisos
    # concedidos a el, en CUALQUIER base del cluster, PostgreSQL se niega. Y hace bien.
    #
    # La receta es la documentada, y en este orden, en cada base:
    #
    #   REASSIGN OWNED  no borra nada: pasa al superusuario lo que fuera del rol.
    #   DROP OWNED      despues del anterior el rol ya no es dueno de nada, asi que esto solo
    #                   retira los permisos que tuviera concedidos.
    #
    # Con REASSIGN antes que DROP OWNED, un DROP OWNED nunca llega a borrar datos de nadie.
    function LimpiarDependenciasDeRol ($rol) {
        $bases = PsqlD "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn;"
        if (-not $bases) { return }

        foreach ($linea in ($bases -split "`n")) {
            $base = $linea.Trim()
            if (-not $base) { continue }
            EjecutarSqlEnD $base "REASSIGN OWNED BY $rol TO ""$Superusuario"";" | Out-Null
            EjecutarSqlEnD $base "DROP OWNED BY $rol;" | Out-Null
        }
    }

    # ── Cabecera ──────────────────────────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Host "Desinstalar el servidor de JudoAdministracion de este equipo" -ForegroundColor Cyan
    Write-Host "   base       $Bd"
    Write-Host "   carpeta    $Dir"
    Write-Host "   servidor   $Nombre, puerto $Puerto"
    Write-Host ""
    if ($SinBaseDatos) {
        Aviso "se conservan la base de datos, los roles y PostgreSQL (-SinBaseDatos)"
    } else {
        Write-Host "   Se va a BORRAR la base de datos `"$Bd`", sus roles y PostgreSQL." -ForegroundColor Red
        Write-Host "   Antes se saca un volcado al perfil, y es lo unico que quedara." -ForegroundColor Red
    }
    if ($Simular) { Aviso "modo simulacion: no se cambia nada" }
    Write-Host ""

    if (-not $Si) {
        $r = Read-Host "   Sigo? [s/N]"
        if ($r -notmatch '^[sSyY]$') { Write-Host "   Cancelado."; exit 0 }
    }

    # Fuera de la carpeta que se va a borrar, por si el guion se esta ejecutando desde dentro (es lo
    # normal: viene dentro del paquete del servicio).
    Set-Location "$env:SystemDrive\"

    # ── 1. La tarea programada ────────────────────────────────────────────────────────────────────

    Paso "1/8  El servicio"

    if (Get-ScheduledTask -TaskName "JudoAdministracionApi" -ErrorAction SilentlyContinue) {
        HacerD { Stop-ScheduledTask -TaskName "JudoAdministracionApi" -ErrorAction SilentlyContinue } | Out-Null
        if (HacerD { Unregister-ScheduledTask -TaskName "JudoAdministracionApi" -Confirm:$false }) {
            ResultadoD "tarea JudoAdministracionApi quitada"
        } else {
            Aviso "no he podido quitar la tarea JudoAdministracionApi"
        }
    } else {
        Igual "no habia tarea JudoAdministracionApi"
    }

    # Lo que quede escuchando aunque no fuera la tarea: la API se puede haber lanzado desde el boton
    # de la aplicacion de escritorio, y entonces es un proceso suelto.
    $escuchando = @(Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty OwningProcess -Unique)
    if ($escuchando.Count -gt 0) {
        # $pid NO se puede usar como variable de bucle: es una variable automatica de PowerShell
        # -el identificador de este proceso- y es de solo lectura.
        foreach ($proceso in $escuchando) {
            HacerD { Stop-Process -Id $proceso -Force -ErrorAction SilentlyContinue } | Out-Null
        }
        ResultadoD "parado lo que quedaba escuchando en el puerto $Puerto"
    }

    # ── 2 y 3. Base de datos y PostgreSQL ─────────────────────────────────────────────────────────

    $psqlD = BuscarHerramientaD "psql.exe"

    if ($SinBaseDatos) {
        Paso "2/8  Base de datos"
        Igual "se conserva (-SinBaseDatos)"
        Paso "3/8  PostgreSQL"
        Igual "se conserva (-SinBaseDatos)"
    }
    elseif (-not $psqlD) {
        Paso "2/8  Base de datos"
        Aviso "no encuentro psql.exe, asi que no puedo volcarla ni borrarla."
        Aviso "  Si PostgreSQL sigue instalado, la base `"$Bd`" seguira ahi."
        Paso "3/8  PostgreSQL"
        Igual "no encuentro psql.exe: no lo toco"
    }
    else {
        # La contrasena del superusuario hace falta para todo esto y en Windows no hay camino sin
        # ella. Se pide aqui y no al principio para no molestar cuando -SinBaseDatos.
        if (-not $ClavePostgres) {
            $segura = Read-Host "   Contrasena del superusuario '$Superusuario' de PostgreSQL" -AsSecureString
            $ClavePostgres = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($segura))
        }
        $env:PGPASSWORD = $ClavePostgres

        Paso "2/8  Volcado y borrado de la base de datos"

        $existeBd = (PsqlD "SELECT 1 FROM pg_database WHERE datname = '$Bd';") -eq "1"

        if (-not $existeBd) {
            Igual "la base de datos `"$Bd`" no existe: no hay nada que volcar"
        } else {
            $pgDumpD = BuscarHerramientaD "pg_dump.exe"
            $sello   = Get-Date -Format "yyyyMMdd-HHmmss"
            $volcado = Join-Path $env:USERPROFILE "judo-volcado-antes-de-desinstalar-$sello.dump"

            if (-not $pgDumpD) {
                Aviso "no encuentro pg_dump.exe: NO hay volcado, y la base se va a borrar igual"
            } elseif ($Simular) {
                Write-Host "   [simulado] volcaria `"$Bd`" en $volcado" -ForegroundColor Yellow
            } else {
                if (EjecutarNativoD { & $pgDumpD -U $Superusuario -Fc -f $volcado $Bd }) {
                    Bien "volcado en $volcado"
                    $script:VolcadoFinal = $volcado
                } else {
                    Aviso "el volcado ha fallado. La base se va a borrar de todos modos (-Deshacer)"
                }
            }

            # Las sesiones abiertas impiden el DROP DATABASE, y en un servidor que se retira siempre
            # queda alguna: la API acaba de morir pero PostgreSQL tarda en enterarse.
            EjecutarSqlD ("SELECT pg_terminate_backend(pid) FROM pg_stat_activity " +
                          "WHERE datname = '$Bd' AND pid <> pg_backend_pid();") | Out-Null

            if (EjecutarSqlD "DROP DATABASE IF EXISTS ""$Bd"";") {
                ResultadoD "base de datos `"$Bd`" borrada"
            } else {
                Aviso "no he podido borrar la base de datos `"$Bd`""
            }
        }

        # Los roles, despues de la base: mientras son duenos de algo, PostgreSQL no los deja caer.
        foreach ($rol in @("judo_api", "judo_owner")) {
            if ((PsqlD "SELECT 1 FROM pg_roles WHERE rolname = '$rol';") -eq "1") {
                LimpiarDependenciasDeRol $rol

                if (EjecutarSqlD "DROP ROLE IF EXISTS $rol;") {
                    ResultadoD "rol $rol borrado"
                } else {
                    # Un rol que se queda no estorba: no es dueno de nada, no tiene permisos y nadie
                    # se conecta con el. Se dice y se sigue, que es lo que toca en una desinstalacion.
                    Aviso "no he podido borrar el rol ${rol}; se queda, sin permisos y sin uso"
                    Aviso "  para quitarlo a mano:  DROP ROLE $rol;"
                }
            } else {
                Igual "el rol $rol no existia"
            }
        }

        Paso "3/8  PostgreSQL"

        # Cuantas bases quedan que NO sean de PostgreSQL ni de esta aplicacion. Es lo que decide si se
        # puede desinstalar el gestor: en un equipo que ya lo tenia puesto -un portatil de trabajo,
        # por ejemplo-, desinstalarlo se llevaria datos que no son de aqui.
        $otras = PsqlD ("SELECT count(*) FROM pg_database WHERE NOT datistemplate " +
                        "AND datname NOT IN ('postgres', '$Bd');")

        if ($otras -notmatch '^\d+$') {
            Aviso "no he podido comprobar si hay otras bases de datos: NO desinstalo PostgreSQL"
        }
        elseif ([int]$otras -gt 0) {
            Aviso "en este cluster quedan $otras bases de datos que no son de esta aplicacion:"
            $lista = PsqlD ("SELECT datname FROM pg_database WHERE NOT datistemplate " +
                            "AND datname NOT IN ('postgres', '$Bd');")
            foreach ($n in ($lista -split "`n")) { if ($n.Trim()) { Write-Host "     - $($n.Trim())" } }
            Aviso "PostgreSQL se queda instalado. Desinstalarlo se llevaria esos datos por delante."
        }
        elseif (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Aviso "no hay winget: desinstala PostgreSQL desde 'Aplicaciones instaladas'"
        }
        else {
            # El identificador exacto que hay puesto, y no uno fijo: la version instalada puede no ser
            # la 18 que instala este mismo guion.
            $listado = LeerNativoD { winget list --source winget }
            $id = ($listado | Select-String 'PostgreSQL\.PostgreSQL\S*' |
                   ForEach-Object { $_.Matches[0].Value } | Select-Object -First 1)

            if (-not $id) {
                Aviso "PostgreSQL no lo puso winget: desinstalalo desde 'Aplicaciones instaladas'"
            } elseif ($Simular -or (EjecutarNativoD { winget uninstall --id $id --silent --disable-interactivity })) {
                ResultadoD "PostgreSQL desinstalado ($id)"
            } else {
                Aviso "no he podido desinstalar PostgreSQL ($id). Hazlo desde 'Aplicaciones instaladas'"
            }
        }

        $env:PGPASSWORD = $null
    }

    # ── 4. Certificado del almacen de confianza ───────────────────────────────────────────────────

    Paso "4/8  Certificado del almacen de confianza"

    $certs = @(Get-ChildItem "Cert:\LocalMachine\Root" -ErrorAction SilentlyContinue |
               Where-Object { $_.Subject -match [regex]::Escape($Nombre) })

    if ($certs.Count -eq 0) {
        Igual "el certificado de $Nombre no estaba en el almacen de confianza"
    } else {
        foreach ($c in $certs) {
            HacerD { Remove-Item "Cert:\LocalMachine\Root\$($c.Thumbprint)" -Force } | Out-Null
        }
        ResultadoD "certificado de $Nombre retirado del almacen de confianza ($($certs.Count))"
    }

    # El de LocalMachine\My, que es donde New-SelfSignedCertificate lo dejo al crearlo.
    $propios = @(Get-ChildItem "Cert:\LocalMachine\My" -ErrorAction SilentlyContinue |
                 Where-Object { $_.Subject -match [regex]::Escape($Nombre) })
    if ($propios.Count -gt 0) {
        foreach ($c in $propios) {
            HacerD { Remove-Item "Cert:\LocalMachine\My\$($c.Thumbprint)" -Force } | Out-Null
        }
        ResultadoD "certificado de $Nombre retirado del almacen personal del equipo"
    }

    # ── 5. Archivo hosts ──────────────────────────────────────────────────────────────────────────

    Paso "5/8  Archivo hosts"

    if (-not (Test-Path $hosts) -or
        -not (Get-Content $hosts | Where-Object { $_ -like "*$marcaHosts*" })) {
        Igual "no habia ninguna linea de JudoAdministracion en el hosts"
    } elseif ($Simular) {
        Write-Host "   [simulado] quitaria del hosts las lineas marcadas con $marcaHosts" -ForegroundColor Yellow
    } else {
        $limpio = Get-Content $hosts | Where-Object { $_ -notlike "*$marcaHosts*" }
        Set-Content -Path $hosts -Value $limpio -Encoding ASCII
        Bien "linea de $Nombre quitada del hosts"
    }

    # ── 6. Cortafuegos ────────────────────────────────────────────────────────────────────────────

    Paso "6/8  Cortafuegos"

    $reglas = @('JudoAdministracion-Api', 'JudoAdministracion-PostgreSQL-Bloqueado')
    $quitadas = 0
    foreach ($nombreRegla in $reglas) {
        if (Get-NetFirewallRule -Name $nombreRegla -ErrorAction SilentlyContinue) {
            if (HacerD { Remove-NetFirewallRule -Name $nombreRegla }) { $quitadas++ }
        }
    }
    if ($quitadas -gt 0) { ResultadoD "reglas del cortafuegos quitadas ($quitadas)" }
    else                 { Igual "no habia reglas de JudoAdministracion en el cortafuegos" }

    # ── 7. Configuracion de la aplicacion de escritorio ───────────────────────────────────────────
    #
    # Apunta a un servicio que ya no existe. Se quita solo si la escribio la instalacion: si alguien
    # la ha tocado a mano, es suya.

    Paso "7/8  Configuracion de la aplicacion de escritorio"

    if (-not (Test-Path $configApp)) {
        Igual "no hay configuracion de la aplicacion de escritorio que quitar"
    } elseif ((Get-Content $configApp -Raw) -match 'preparar-servidor') {
        if (HacerD { Remove-Item $configApp -Force }) {
            ResultadoD "appsettings.Local.json de la aplicacion eliminado"
        } else {
            Aviso "no he podido borrar $configApp"
        }
    } else {
        Aviso "hay un appsettings.Local.json que no escribio este guion: no lo toco"
        Aviso "  $configApp"
    }

    # ── 8. Carpetas ───────────────────────────────────────────────────────────────────────────────

    Paso "8/8  Carpetas"

    $carpetas = @($Dir, "$Dir.anterior", "$Dir.nuevo",
                  (Join-Path $env:ProgramData "JudoAdministracion\Copias"))

    foreach ($carpeta in $carpetas) {
        if (Test-Path $carpeta) {
            if (HacerD { Remove-Item $carpeta -Recurse -Force }) { ResultadoD "borrada $carpeta" }
            else { Aviso "no he podido borrar $carpeta (algo la tiene abierta?)" }
        } else {
            Igual "no existe $carpeta"
        }
    }

    # ── Resumen ───────────────────────────────────────────────────────────────────────────────────

    Write-Host ""
    if ($Simular) {
        Write-Host "Simulacion terminada. No se ha cambiado nada." -ForegroundColor Yellow
        Write-Host "   Quita -Simular para hacerlo de verdad."
    } else {
        Write-Host "Este equipo ya no es el servidor de JudoAdministracion." -ForegroundColor Green
        if ($script:VolcadoFinal) {
            Write-Host "   El volcado de la base de datos esta en:  $($script:VolcadoFinal)"
        }
        Write-Host ""
        Write-Host "   La aplicacion de escritorio sigue instalada; se desinstala desde"
        Write-Host "   'Aplicaciones instaladas' como cualquier otro programa."
        Write-Host ""
        Write-Host "   Falta devolver la red, que es lo que le importa a quien use este equipo:" -ForegroundColor Yellow
        Write-Host "     powershell -ExecutionPolicy Bypass -File .\configurar-red.ps1 -Deshacer"
    }
    Write-Host ""
    exit 0
}

Write-Host ""
Write-Host "Preparacion del servidor de JudoAdministracion" -ForegroundColor Cyan
Write-Host "   servidor   $Nombre ($Ip), puerto $Puerto"
Write-Host "   base       $Bd"
Write-Host "   carpeta    $Dir"

# ── 1. Comprobaciones previas ─────────────────────────────────────────────────────────────────────

Paso "1/10  Comprobaciones previas"

if (-not $sqlRoles) {
    Fallo ("No encuentro Despliegue\01_roles.sql.`n" +
           "        Deberia estar junto a este guion (viene en el paquete api-win-x64) o en`n" +
           "        JudoAdministracion.Api\Despliegue\ si lo ejecutas desde el repositorio.")
}
Bien "guion de roles localizado en $sqlRoles"

if (-not (Test-Path $binario)) {
    Fallo "No encuentro el servicio en $Dir.`n        Descomprime ahi el paquete api-win-x64 (Documentacion/00) o indica otra carpeta con -Dir."
}
Bien "servicio encontrado en $Dir"

# La aplicacion de escritorio busca el servicio en Program Files por defecto para arrancarlo ella
# sola (Services/Servidor/ServicioApiLocal.LocalizarBinario; ver doc 00, §8.1). Si el paquete se ha
# descomprimido en otro sitio -Descargas es el caso tipico, de abrir el .zip a doble clic sin
# fijarse en el destino-, mejor pararse aqui que descubrirlo el dia del campeonato, cuando la
# aplicacion no encuentre el servicio sola.
$rutaRecomendada = Join-Path $env:ProgramFiles 'JudoAdministracionServidor'
if (([IO.Path]::GetFullPath($Dir)).TrimEnd('\') -ine $rutaRecomendada.TrimEnd('\')) {
    Fallo ("Esta carpeta es $Dir y deberia ser $rutaRecomendada (doc 00, §8.1).`n" +
           "        Mueve ahi el paquete descomprimido y vuelve a ejecutar el guion.")
}

# ¿Servidor nuevo o ya configurado? Se decide antes de tocar la base de datos, porque de ello depende
# si las contraseñas de los roles se pueden cambiar o no.
$conservarConfig = (Test-Path $config) -and (-not $ForzarConfiguracion)
if ($conservarConfig) {
    Igual "hay configuracion previa: se conservara, contrasenas incluidas"

    # De esa configuración se puede recuperar lo que hace falta para los pasos que vienen después
    # —configurar la aplicación de escritorio, sobre todo—, así que una segunda ejecución sirve para
    # completar un servidor a medias en vez de quedarse a la mitad.
    $cadenaExistente = LeerJson $config 'ConnectionString'
    if ($cadenaExistente -and $cadenaExistente -match 'Username=judo_api;Password=(.+)$') {
        $ClaveApi = $Matches[1]
        Bien "contrasena de judo_api recuperada de la configuracion existente"
    }
}
else { Bien "servidor nuevo: se generara la configuracion" }

# ── 2. PostgreSQL ─────────────────────────────────────────────────────────────────────────────────

Paso "2/10  PostgreSQL"

function BuscarPsql {
    $enPath = Get-Command psql.exe -ErrorAction SilentlyContinue
    if ($enPath) { return $enPath.Source }
    # El instalador de EDB no toca el PATH: se busca la versión más alta instalada.
    Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\psql.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.Directory.Parent.Name) } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

$psql = BuscarPsql
if (-not $psql) {
    if ($SinPostgresql) {
        Fallo "PostgreSQL no esta instalado y se ha pedido -SinPostgresql. Instalalo a mano (guia 01, 3.1)."
    }
    Aviso "PostgreSQL no esta instalado; instalando con winget"
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fallo "No hay winget. Instala PostgreSQL a mano (guia 01, 3.1) y vuelve a ejecutar."
    }
    winget install --id PostgreSQL.PostgreSQL.18 --accept-package-agreements --accept-source-agreements
    $psql = BuscarPsql
    if (-not $psql) { Fallo "La instalacion no ha dejado psql.exe donde se esperaba." }
    Aviso "winget instala con la contrasena de superusuario que pida su asistente; tenla a mano"
}
Bien "psql en $psql"

if (-not $ClavePostgres) {
    $segura = Read-Host "   Contrasena del superusuario '$Superusuario' de PostgreSQL" -AsSecureString
    $ClavePostgres = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($segura))
}
# PGPASSWORD evita que psql pida la contraseña en cada llamada. Solo vive en este proceso.
$env:PGPASSWORD = $ClavePostgres

function PsqlSuper {
    param([string]$Base = "postgres", [string[]]$Argumentos)
    & $psql -U $Superusuario -d $Base -v ON_ERROR_STOP=1 @Argumentos
    if ($LASTEXITCODE -ne 0) { Fallo "psql ha fallado (codigo $LASTEXITCODE)." }
}
function PsqlValor {
    param([string]$Base = "postgres", [string]$Consulta)
    $v = & $psql -U $Superusuario -d $Base -tAc $Consulta
    if ($LASTEXITCODE -ne 0) { Fallo "psql ha fallado (codigo $LASTEXITCODE)." }
    return ($v | Out-String).Trim()
}

$version = (PsqlValor -Consulta "SHOW server_version;").Split(".")[0]
Bien "PostgreSQL $version responde"

# ── 3. Base de datos ──────────────────────────────────────────────────────────────────────────────

Paso "3/10  Base de datos `"$Bd`""

if ((PsqlValor -Consulta "SELECT 1 FROM pg_database WHERE datname = '$Bd';") -eq "1") {
    Igual "ya existe, no se toca"
}
else {
    # Las comillas dobles alrededor del nombre son imprescindibles: sin ellas PostgreSQL pasa el
    # nombre a minusculas y la cadena de conexion de la aplicacion, que pide "JudoAdministracion",
    # no la encontraria. Pero NO pueden ir en un argumento -c: Windows PowerShell reconstruye la
    # linea de comandos para el ejecutable nativo, y una comilla doble incrustada dentro de ese
    # argumento se pierde por el camino. El sintoma es silencioso: psql no da ningun error, crea la
    # base de datos igual, solo que sin comillas y por tanto en minusculas ("judoadministracion"),
    # y el fallo no salta hasta la comprobacion de la codificacion de aqui abajo, que ya no
    # encuentra ninguna fila con el nombre exacto que busca.
    #
    # La solucion es la misma que ya usa 01_roles.sql: pasar el nombre por -v y dejar que sea psql,
    # leyendo un archivo con -f, quien interprete :"bd" como identificador entrecomillado. Dentro
    # de un archivo no hay linea de comandos de por medio, asi que el problema no se puede dar.
    $sqlCrear = Join-Path $env:TEMP "judo-crear-bd.sql"
    Set-Content -Path $sqlCrear -Encoding ascii -Value 'CREATE DATABASE :"bd" ENCODING ''UTF8'' TEMPLATE template0;'
    try {
        PsqlSuper -Argumentos @("-v", "bd=$Bd", "-f", $sqlCrear)
    }
    finally {
        Remove-Item $sqlCrear -Force -ErrorAction SilentlyContinue
    }
    Bien "creada con codificacion UTF8"
}

$codificacion = PsqlValor -Consulta "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = '$Bd';"
if ($codificacion -ne "UTF8") { Fallo "La base de datos esta en $codificacion y debe estar en UTF8." }
Bien "codificacion UTF8"

# La ordenacion decide como se listan los apellidos. Con "C", los acentuados se van todos al final.
$orden = PsqlValor -Base $Bd -Consulta "SELECT string_agg(x, ' < ' ORDER BY x) FROM (VALUES ('Ávila'),('Alicante'),('Zamora'),('Ñuño')) t(x);"
if ($orden -eq "Alicante < Ávila < Ñuño < Zamora") { Bien "ordenacion correcta para castellano" }
else {
    Aviso "ordenacion dudosa: $orden"
    Aviso "los listados saldran con los acentos fuera de sitio (guia 01, 3.2)"
}

# ── 4. Roles y extensiones ────────────────────────────────────────────────────────────────────────

Paso "4/10  Roles y extensiones"

if ($conservarConfig) {
    # Roles y permisos si, contrasenas no: las que hay son las que conoce la configuracion existente.
    PsqlSuper -Base $Bd -Argumentos @("-q", "-v", "rotar_claves=off", "-v", "bd=$Bd", "-f", $sqlRoles)
    Bien "roles comprobados y permisos repuestos (contrasenas sin tocar)"
}
else {
    if (-not $ClaveOwner) { $ClaveOwner = GenerarClave }
    if (-not $ClaveApi)   { $ClaveApi   = GenerarClave }

    PsqlSuper -Base $Bd -Argumentos @(
        "-q", "-v", "clave_owner=$ClaveOwner", "-v", "clave_api=$ClaveApi", "-v", "bd=$Bd", "-f", $sqlRoles)
    Bien "judo_owner y judo_api listos"
}

$extensiones = PsqlValor -Base $Bd -Consulta "SELECT string_agg(extname, ', ' ORDER BY extname) FROM pg_extension WHERE extname IN ('unaccent','pgcrypto');"
if ($extensiones -ne "pgcrypto, unaccent") { Fallo "Faltan extensiones ($extensiones). Reinstala PostgreSQL incluyendo los modulos contrib." }
Bien "extensiones unaccent y pgcrypto instaladas"

# ── 5. Certificado HTTPS ──────────────────────────────────────────────────────────────────────────

Paso "5/10  Certificado HTTPS"

if ($RegenerarCertificado -and $conservarConfig) {
    Fallo "-RegenerarCertificado cambia la contrasena del .pfx y la configuracion existente se`n        quedaria con la vieja. Anade -ForzarConfiguracion (cierra las sesiones abiertas) o`n        pasa -ClavePfx con la contrasena actual."
}

if ((Test-Path $pfx) -and (-not $RegenerarCertificado)) {
    Igual "$Nombre.pfx ya existe, no se regenera (-RegenerarCertificado para rehacerlo)"
    if (-not $ClavePfx) { Aviso "no conozco su contrasena: la configuracion conservara la que ya tenga" }
}
else {
    if (-not $ClavePfx) { $ClavePfx = GenerarClave }

    # New-SelfSignedCertificate en lugar de openssl: es nativo de Windows y no obliga a instalar Git
    # solo para esto. Todos los nombres por los que se puede llegar al servidor van en el SAN; si
    # falta uno, el cliente que use ese nombre rechaza la conexion. localhost es el del anfitrion.
    $certificado = New-SelfSignedCertificate `
        -Subject "CN=$Nombre" `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -NotAfter (Get-Date).AddYears(5) `
        -KeyExportPolicy Exportable `
        -KeyLength 2048 `
        -KeyAlgorithm RSA `
        -HashAlgorithm SHA256 `
        -KeyUsage DigitalSignature, KeyEncipherment `
        -TextExtension @(
            "2.5.29.37={text}1.3.6.1.5.5.7.3.1",
            "2.5.29.17={text}DNS=$Nombre&DNS=localhost&IPAddress=$Ip&IPAddress=127.0.0.1")

    Export-PfxCertificate -Cert $certificado -FilePath $pfx `
        -Password (ConvertTo-SecureString -String $ClavePfx -Force -AsPlainText) | Out-Null

    # El .crt se reparte a los puestos y ahi lo consumen tambien Linux y macOS, asi que se exporta en
    # PEM (base 64) y no en DER: certutil -encode es lo que hace la conversion.
    $temporalDer = Join-Path $env:TEMP "$Nombre.der"
    Export-Certificate -Cert $certificado -FilePath $temporalDer -Type CERT | Out-Null
    & certutil -encode $temporalDer $crt | Out-Null
    Remove-Item $temporalDer -Force

    Bien "certificado emitido para $Nombre, localhost, $Ip y 127.0.0.1"
    Bien "valido 5 anos"
}

# Este equipo confia en su propio certificado salvo que se diga lo contrario. Hace falta siempre que
# aqui vaya a correr tambien la aplicacion de escritorio -el caso normal, el anfitrion- y no estorba
# cuando no: es un certificado emitido en esta misma maquina hace un momento.
if ($SinConfianza) {
    Aviso "certificado sin instalar como raiz de confianza (-SinConfianza)"
    Aviso "si este equipo ejecuta la aplicacion, no podra conectarse a su propio servidor"
}
else {
    Import-Certificate -FilePath $crt -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
    Bien "certificado instalado como raiz de confianza de este equipo"
}

# ── 6. Configuración del servicio ─────────────────────────────────────────────────────────────────

Paso "6/10  Configuracion del servicio"

function EscribirConfiguracion {
    param([string]$Usuario, [string]$Clave, [bool]$Inicializar)

    EscribirTexto $config @"
{
    "//": [
        "Generado por preparar-servidor.ps1.",
        "Configuracion REAL de este equipo: contrasena de la base de datos y clave de firma de",
        "tokens. No se sube a git y no la incluye ningun instalador.",
        "Ver Documentacion/01-Guia-de-Instalacion.md, 3.5."
    ],
    "Servidor": {
        "Url": "https://0.0.0.0:$Puerto",
        "CertificadoPfx": "$Nombre.pfx",
        "CertificadoPassword": "$ClavePfx",
        "ConnectionString": "Host=localhost;Port=5432;Database=$Bd;Username=$Usuario;Password=$Clave",
        "ClaveFirmaTokens": "$script:claveTokens",
        "HorasValidezToken": 16,
        "IpsAnfitrion": [],
        "InicializarBaseDeDatos": $($Inicializar.ToString().ToLower())
    }
}
"@
}

if ($conservarConfig) {
    Igual "appsettings.Local.json ya existe, se conserva (-ForzarConfiguracion para reescribirlo)"
    Aviso "la clave de firma de tokens NO se toca: cambiarla cerraria todas las sesiones abiertas"
}
else {
    if (-not $ClavePfx) {
        Fallo "No puedo escribir la configuracion sin la contrasena del certificado.`n        Usa -ClavePfx <contrasena> o -RegenerarCertificado."
    }
    # Larga y estable: si cambia entre reinicios, todas las sesiones abiertas dejan de valer y hay
    # que volver a entrar en los cinco puestos.
    $bytes = New-Object byte[] 48
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $script:claveTokens = [Convert]::ToBase64String($bytes)

    EscribirConfiguracion -Usuario "judo_owner" -Clave $ClaveOwner -Inicializar $true
    Bien "escrita con el rol judo_owner, para crear el esquema en el primer arranque"
}

# ── 7. Esquema, datos básicos y disparadores ───────────────────────────────────────────────────────

Paso "7/10  Esquema y datos basicos"

function EsperarServicio {
    param([int]$Segundos = 40)
    for ($i = 0; $i -lt $Segundos; $i++) {
        try {
            $r = Invoke-RestMethod "https://localhost:$Puerto/api/estado" -TimeoutSec 3
            if ($r.estado -eq "ok") { return $true }
        } catch { Start-Sleep -Seconds 1 }
    }
    return $false
}

if ($SinEsquema) {
    Aviso "omitido por -SinEsquema"
}
elseif ($conservarConfig) {
    Igual "se conserva la configuracion existente: no se relanza la inicializacion"
    Aviso "si esta es una actualizacion con cambios de esquema, sigue la guia 01, 7"
}
else {
    # El primer arranque es el que crea las tablas, las funciones de sorteo y propagacion, los
    # disparadores de tiempo real y siembra los datos basicos. Se lanza aqui, se espera a que
    # responda y se para: asi el tecnico no tiene que hacer el baile a mano.
    Write-Host "   arrancando el servicio para inicializar (puede tardar unos segundos)..."

    $registro = Join-Path $env:TEMP "judo-inicializacion.log"
    # WorkingDirectory es imprescindible: el servicio busca su configuracion y el .pfx por ruta
    # relativa, y arrancado desde otro sitio no encuentra ninguno de los dos.
    $proceso = Start-Process -FilePath $binario -WorkingDirectory $Dir -PassThru `
                             -RedirectStandardOutput $registro -RedirectStandardError "$registro.err" `
                             -WindowStyle Hidden

    # Para que Invoke-RestMethod valide el certificado hace falta confiar en el. Con el paso 5 por
    # defecto ya se confia; solo cuando se ha pedido -SinConfianza hay que confiar durante esta
    # comprobacion y deshacerlo al terminar.
    $confianzaTemporal = $false
    if ($SinConfianza) {
        $importado = Import-Certificate -FilePath $crt -CertStoreLocation "Cert:\LocalMachine\Root"
        $confianzaTemporal = $true
    }

    $listo = EsperarServicio

    if (-not $proceso.HasExited) { Stop-Process -Id $proceso.Id -Force }
    if ($confianzaTemporal) {
        Remove-Item "Cert:\LocalMachine\Root\$($importado.Thumbprint)" -Force -ErrorAction SilentlyContinue
    }

    if (-not $listo) {
        Write-Host ""
        Write-Host "El servicio no llego a responder. Sus ultimas lineas:" -ForegroundColor Red
        if (Test-Path $registro)       { Get-Content $registro       -Tail 20 }
        if (Test-Path "$registro.err") { Get-Content "$registro.err" -Tail 20 }
        Fallo "Inicializacion fallida. Los fallos frecuentes estan en la guia 01, 9."
    }

    $tablas   = [int](PsqlValor -Base $Bd -Consulta "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")
    $paises   = [int](PsqlValor -Base $Bd -Consulta "SELECT count(*) FROM paises;")
    $usuarios = [int](PsqlValor -Base $Bd -Consulta "SELECT count(*) FROM usuarios;")

    if ($tablas -lt 14) { Fallo "Solo hay $tablas tablas; se esperaban 14 o mas." }
    if ($paises -eq 0)  { Fallo "La siembra de datos basicos no ha dejado paises." }
    Bien "esquema listo: $tablas tablas, $paises paises, $usuarios usuario(s)"

    # Y ahora la configuracion definitiva: el rol que solo lee y escribe datos, sin inicializacion.
    # Los dos cambios van juntos; con judo_api e inicializacion activada, el arranque falla con
    # permiso denegado (guia 01, 3.6).
    EscribirConfiguracion -Usuario "judo_api" -Clave $ClaveApi -Inicializar $false
    Bien "configuracion cambiada al rol judo_api, sin inicializacion"

    # Que judo_api pueda leer y NO tocar el esquema es la comprobacion que justifica los dos roles.
    $env:PGPASSWORD = $ClaveApi
    & $psql -h localhost -U judo_api -d $Bd -tAc "SELECT count(*) FROM eventos;" | Out-Null
    if ($LASTEXITCODE -eq 0) { Bien "judo_api puede leer los datos" }
    else                     { Fallo "judo_api no puede leer. Revisa el paso 4." }

    # Esta comprobacion tiene que poder FALLAR sin matar el guion: lo correcto es que psql termine
    # con "permiso denegado" en su stderr, y con $ErrorActionPreference = Stop (arriba del todo),
    # un 2>&1 convierte cada linea de stderr en un registro de error que se propaga como excepcion
    # terminante en el momento en que se crea -antes incluso de llegar al Out-Null que deberia
    # tragarsela-. Por eso se baja a Continue solo para estas dos llamadas: aqui SI queremos leer
    # $LASTEXITCODE en vez de que una excepcion decida por nosotros.
    $eapAnterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $psql -h localhost -U judo_api -d $Bd -c "CREATE TABLE comprobacion_permisos (x int);" 2>&1 | Out-Null
        $judoApiPuedeCrear = ($LASTEXITCODE -eq 0)
        if ($judoApiPuedeCrear) {
            & $psql -h localhost -U judo_api -d $Bd -c "DROP TABLE comprobacion_permisos;" 2>&1 | Out-Null
        }
    }
    finally {
        $ErrorActionPreference = $eapAnterior
    }
    if ($judoApiPuedeCrear) { Aviso "judo_api PUEDE crear tablas y no deberia. Revisa los permisos del paso 4." }
    else                    { Bien "judo_api no puede alterar el esquema (correcto)" }
    $env:PGPASSWORD = $ClavePostgres
}

# ── 8. La aplicación de escritorio de este equipo ─────────────────────────────────────────────────
#
# Lo normal es que el equipo servidor ejecute tambien la aplicacion: es el ANFITRION, el unico desde
# el que se pueden activar eventos (guia 01, 5). Ese papel no se declara en ninguna parte: se lo gana
# conectandose por localhost, asi que todo lo que hace falta es que su appsettings.Local.json apunte
# ahi. Escribirlo aqui es lo que evita el paso manual que antes habia que recordar.

Paso "8/10  Aplicacion de escritorio de este equipo"

if ($SinAplicacion) {
    Aviso "omitido por -SinAplicacion"
}
elseif (-not (Test-Path (Join-Path $DirAplicacion "JudoAdministracion.exe"))) {
    Aviso "la aplicacion de escritorio no esta instalada en $DirAplicacion"
    Aviso "si va a estarlo, instalala (guia 01, 4.1) y vuelve a lanzar este guion: se configurara sola"
}
elseif (-not $ClaveApi) {
    Aviso "no conozco la contrasena de judo_api, asi que no puedo escribir su configuracion"
    Aviso "vuelve a lanzar el guion sobre este mismo servidor y la recuperara de $config"
}
else {
    # ApiBaseUrl con localhost y no con el nombre del servidor: es exactamente lo que le identifica
    # como anfitrion. Y la cadena de conexion va con judo_api, el mismo rol con el que corre el
    # servicio: las pantallas que todavia no han pasado por la API solo hacen consultas y altas, y
    # ninguna toca el esquema, asi que no hay motivo para darle judo_owner a un programa de escritorio.
    EscribirTexto $configApp @"
{
    "//": [
        "Generado por preparar-servidor.ps1.",
        "Este equipo es el SERVIDOR y a la vez el ANFITRION de la competicion.",
        "",
        "ApiBaseUrl con localhost -y no con $Nombre- es lo que le identifica como anfitrion",
        "y le habilita las operaciones que afectan a toda la red, como activar un evento.",
        "",
        "ConnectionString: la usan las pantallas que todavia no han pasado por la API. Va con el rol",
        "judo_api, el mismo con el que corre el servicio. En los puestos de la red va vacia.",
        "",
        "Ver Documentacion/01-Guia-de-Instalacion.md, 5."
    ],
    "ApiBaseUrl": "https://localhost:$Puerto",
    "ConnectionString": "Host=localhost;Port=5432;Database=$Bd;Username=judo_api;Password=$ClaveApi",
    "RutaApi": "$($Dir -replace '\\','\\')"
}
"@
    Bien "configurada como anfitrion en $DirAplicacion"
    Bien "apunta a https://localhost:$Puerto, con acceso directo a la base de datos"
}

# ── 9. Red de este equipo ─────────────────────────────────────────────────────────────────────────

Paso "9/10  Nombre del servidor y cortafuegos"

if ($SinHosts) {
    Igual "archivo hosts sin tocar (-SinHosts)"
}
elseif ((Test-Path $hosts) -and (Get-Content $hosts | Where-Object { $_ -like "*$marcaHosts*" })) {
    Igual "la linea de $Nombre ya esta en $hosts"
}
else {
    Add-Content -Path $hosts -Value "$Ip`t$Nombre`t$marcaHosts" -Encoding ASCII
    Bien "$Nombre -> $Ip en $hosts"
}

if ($SinCortafuegos) {
    Igual "cortafuegos sin tocar (-SinCortafuegos)"
}
else {
    # Las reglas llevan -Name propio para poder rehacerlas sin duplicarlas en cada ejecucion.
    foreach ($regla in @(
        @{ Nombre = 'JudoAdministracion-Api'
           Titulo = "JudoAdministracion API ($Puerto/tcp desde $subred)"
           Puerto = $Puerto; Accion = 'Allow'; Remoto = $subred },
        @{ Nombre = 'JudoAdministracion-PostgreSQL-Bloqueado'
           Titulo = 'JudoAdministracion PostgreSQL (5432/tcp bloqueado desde la red)'
           Puerto = 5432;    Accion = 'Block'; Remoto = 'Any' }))
    {
        Remove-NetFirewallRule -Name $regla.Nombre -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name $regla.Nombre -DisplayName $regla.Titulo `
            -Direction Inbound -Protocol TCP -LocalPort $regla.Puerto `
            -RemoteAddress $regla.Remoto -Action $regla.Accion -Profile Any | Out-Null
    }
    Bien "cortafuegos: $Puerto/tcp abierto a $subred, 5432/tcp cerrado desde la red"
}

# Que PostgreSQL no escuche en la red es la mitad importante del asunto, y no depende del
# cortafuegos sino de listen_addresses. De fabrica esta bien; se comprueba porque una instalacion
# heredada puede venir abierta.
$escuchaPg = PsqlValor -Consulta "SHOW listen_addresses;"
if ($escuchaPg -eq "localhost" -or $escuchaPg -eq "127.0.0.1") { Bien "PostgreSQL escucha solo en local" }
else { Aviso "PostgreSQL escucha en `"$escuchaPg`" y deberia hacerlo solo en local (doc 02, 3.4)" }

# ── 10. Arranque automático y comprobación ────────────────────────────────────────────────────────

Paso "10/10  Arranque automatico"

if ($SinTarea) {
    Aviso "no se instala el arranque automatico (-SinTarea)"
    Aviso "la API habra que arrancarla a mano, o desde el boton de la propia aplicacion"
}
else {
    # Tarea programada y no servicio de Windows: el proyecto de la API es una aplicacion de consola
    # que no llama a UseWindowsService(), asi que registrada con sc.exe el Administrador de servicios
    # da error de tiempo de espera. Ver Documentacion/00, 5.1: ahi esta el cambio de una linea que
    # permitiria convertirla en servicio de verdad.
    $accion    = New-ScheduledTaskAction -Execute $binario -WorkingDirectory $Dir
    $disparador = New-ScheduledTaskTrigger -AtStartup
    $ajustes   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    # SYSTEM para que arranque sin que nadie inicie sesion.
    $identidadTarea = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName "JudoAdministracionApi" -Action $accion -Trigger $disparador `
        -Settings $ajustes -Principal $identidadTarea `
        -Description "API de JudoAdministracion" -Force | Out-Null
    Start-ScheduledTask -TaskName "JudoAdministracionApi"
    Bien "tarea JudoAdministracionApi registrada y arrancada"

    # Invoke-RestMethod valida el certificado, asi que esto comprueba las dos cosas a la vez: que el
    # servicio responde y que su certificado es de confianza en este equipo. Es la misma prueba de
    # fuego que hace preparar-puesto en los puestos.
    if ($SinConfianza) {
        Aviso "con -SinConfianza no se puede comprobar por HTTPS desde aqui; hazlo desde un puesto"
    }
    elseif (EsperarServicio -Segundos 20) {
        Bien "el servicio responde en https://localhost:$Puerto/api/estado y su certificado es de confianza"
    }
    else {
        Aviso "el servicio no responde todavia. Mira el estado de la tarea:"
        Aviso "  Get-ScheduledTaskInfo -TaskName JudoAdministracionApi"
    }
}

# ── Resumen ───────────────────────────────────────────────────────────────────────────────────────

# Todo lo que hay que llevarse a los puestos, en una sola carpeta del perfil: el certificado publico
# y los guiones de preparacion, para los dos sistemas. Se copia a un USB y se va de puesto en puesto
# sin volver a pensar que archivo hacia falta.
if (Test-Path $crt) {
    New-Item -ItemType Directory -Force -Path $paraPuestos | Out-Null
    Copy-Item $crt -Destination $paraPuestos -Force

    # Los guiones vienen dentro del paquete del servicio (doc 00, 8.1). Si este guion se esta
    # ejecutando desde el repositorio no estan ahi, y se cogen de su sitio de siempre.
    foreach ($origen in @((Join-Path $Dir 'Puestos'),
                          (Join-Path $raiz 'Empaquetado\puesto'),
                          (Join-Path $raiz 'Empaquetado\red'))) {
        if (-not (Test-Path $origen)) { continue }
        # El comodin en la ruta es obligatorio: -Include sobre una carpeta a secas no filtra nada
        # si no se anade -Recurse, y aqui no queremos recorrer subcarpetas.
        Get-ChildItem (Join-Path $origen '*') -File -Include 'preparar-puesto.*', 'configurar-red.*' `
                      -ErrorAction SilentlyContinue |
            Copy-Item -Destination $paraPuestos -Force
    }

    EscribirTexto (Join-Path $paraPuestos 'LEEME.txt') @"
Preparacion de un puesto de administracion de JudoAdministracion

Copia esta carpeta a un USB y llevala a cada puesto. En cada uno, con la aplicacion ya
instalada (Documentacion/01-Guia-de-Instalacion.md, 4.1):

  1. Direccion IP fija            Windows         powershell -ExecutionPolicy Bypass -File .\configurar-red.ps1
                                  macOS y Linux   sudo ./configurar-red.sh

  2. Certificado, nombre y        Windows         powershell -ExecutionPolicy Bypass -File .\preparar-puesto.ps1
     configuracion                macOS y Linux   sudo ./preparar-puesto.sh

El segundo termina comprobando que el puesto llega al servidor. Si las cuatro comprobaciones
salen en verde, el puesto esta listo.

Al acabar la competicion, los dos con -Deshacer (--deshacer en macOS y Linux) devuelven el
equipo a como estaba.

Servidor: $Nombre ($Ip), puerto $Puerto
Certificado: $Nombre.crt   (el .pfx NO sale del servidor)
"@
}

if (-not $conservarConfig) {
    @"
Credenciales del servidor de JudoAdministracion
Generadas por preparar-servidor.ps1

Servidor           $Nombre ($Ip), puerto $Puerto
Base de datos      $Bd
Carpeta            $Dir

PostgreSQL
  judo_owner       $ClaveOwner      (dueno del esquema; migraciones y copias de seguridad)
  judo_api         $ClaveApi      (con el que corre el servicio y la aplicacion de este equipo)

Certificado
  $Nombre.pfx   $ClavePfx

GUARDA ESTE ARCHIVO FUERA DE ESTE EQUIPO. Sin estas contrasenas, una copia de seguridad
restaurada no deja el servidor funcionando (Documentacion/01-Guia-de-Instalacion.md, 8).
"@ | Set-Content -Path $credenciales -Encoding UTF8

    # Solo el administrador debe poder leerlo.
    $acl = Get-Acl $credenciales
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $identidad.Name, "FullControl", "Allow")))
    Set-Acl -Path $credenciales -AclObject $acl
}

$env:PGPASSWORD = $null

Write-Host ""
Write-Host "Servidor preparado." -ForegroundColor Green
Write-Host ""
if (-not $conservarConfig) {
    Write-Host "   Contrasenas guardadas en:  $credenciales"
    Write-Host "   Copialas fuera de este equipo y borralas de aqui cuando lo hayas hecho." -ForegroundColor Yellow
    Write-Host ""
}
Write-Host "   Queda por hacer:" -ForegroundColor Cyan
Write-Host "     1. Abrir la aplicacion en este equipo y entrar con admin@judo.com / admin123"
Write-Host "     2. Cambiarle la contrasena y dar de alta los usuarios de los puestos    -> guia 3.9"
Write-Host "     3. En cada puesto, con la carpeta de abajo en un USB                    -> guia 4"
Write-Host ""
Write-Host "   Lo que hay que llevarse a los puestos, en una sola carpeta:"
Write-Host "     $paraPuestos"
Write-Host "     (el certificado y los guiones de preparacion, con su LEEME.txt)"
Write-Host ""
