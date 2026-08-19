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
