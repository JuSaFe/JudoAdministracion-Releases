<#
.SYNOPSIS
    Prepara el servidor de competición de JudoAdministración en Windows.

.DESCRIPTION
    Equivalente de preparar-servidor.sh para Windows: PostgreSQL, base de datos, roles, extensiones,
    certificado HTTPS, configuración del servicio, esquema con sus datos básicos y, si se pide, la
    tarea programada que lo arranca al encender el equipo.

    Es el equivalente ejecutable de la Documentación/01-Guía-de-Instalación.md, §3. Se lanza UNA vez,
    en el equipo servidor, antes de instalar los puestos.

    Antes de ejecutarlo hay que haber descomprimido el paquete del servicio (el api-win-x64 de la
    Documentación/00) en la carpeta que se indique con -Dir.

    Es idempotente: se puede volver a ejecutar sobre un servidor ya preparado. Lo que ya existe se
    respeta —la configuración y el certificado no se rehacen salvo que se pida— y lo que falta se
    crea. En particular, si ya hay configuración, las contraseñas de los roles NO se cambian: la
    configuración existente lleva la de judo_api y rotarla dejaría al servicio sin poder entrar.

    ATENCIÓN: a diferencia de la versión de macOS y Linux, este guion NO se ha podido probar en un
    Windows real. La lógica es la misma y los comandos son los estándar del sistema, pero la primera
    ejecución conviene hacerla con calma, leyendo lo que dice cada paso.

.EXAMPLE
    .\preparar-servidor.ps1 -Dir "C:\Program Files\JudoAdministracionServidor"

.EXAMPLE
    .\preparar-servidor.ps1 -InstalarPostgresql -InstalarTarea -Si
#>

[CmdletBinding()]
param(
    [string]   $Dir             = "C:\Program Files\JudoAdministracionServidor",
    [string]   $Bd              = "JudoAdministracion",
    [string]   $Nombre          = "judo-server",
    [string]   $Ip              = "192.168.2.3",
    [int]      $Puerto          = 8443,
    [string]   $Superusuario    = "postgres",
    [string]   $ClavePostgres,                       # contraseña del superusuario; se pide si falta
    [string]   $ClaveOwner,
    [string]   $ClaveApi,
    [string]   $ClavePfx,
    [switch]   $InstalarPostgresql,
    [switch]   $InstalarTarea,
    [switch]   $RegenerarCertificado,
    [switch]   $ForzarConfiguracion,
    [switch]   $ConfiarCertificado,
    [switch]   $SinEsquema,
    [switch]   $Si
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

# Se instala en Program Files y se registra una tarea del sistema: hace falta elevación.
$identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identidad)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fallo "Abre PowerShell como administrador y vuelve a ejecutarlo."
}

$raiz        = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$sqlRoles    = Join-Path $raiz "JudoAdministracion.Api\Despliegue\01_roles.sql"
$binario     = Join-Path $Dir "JudoAdministracion.Api.exe"
$config      = Join-Path $Dir "appsettings.Local.json"
$pfx         = Join-Path $Dir "$Nombre.pfx"
$crt         = Join-Path $Dir "$Nombre.crt"
$credenciales = Join-Path $env:USERPROFILE "judo-credenciales-servidor.txt"

Write-Host ""
Write-Host "Preparacion del servidor de JudoAdministracion" -ForegroundColor Cyan
Write-Host "   servidor   $Nombre ($Ip), puerto $Puerto"
Write-Host "   base       $Bd"
Write-Host "   carpeta    $Dir"

# ── 1. Comprobaciones previas ─────────────────────────────────────────────────────────────────────

Paso "1/9  Comprobaciones previas"

if (-not (Test-Path $sqlRoles)) { Fallo "No encuentro $sqlRoles. Ejecutalo desde el repositorio." }
Bien "guion de roles localizado"

if (-not (Test-Path $binario)) {
    Fallo "No encuentro el servicio en $Dir.`n        Descomprime ahi el paquete api-win-x64 (Documentacion/00) o indica otra carpeta con -Dir."
}
Bien "servicio encontrado en $Dir"

# ¿Servidor nuevo o ya configurado? Se decide antes de tocar la base de datos, porque de ello depende
# si las contraseñas de los roles se pueden cambiar o no.
$conservarConfig = (Test-Path $config) -and (-not $ForzarConfiguracion)
if ($conservarConfig) { Igual "hay configuracion previa: se conservara, contrasenas incluidas" }
else                  { Bien  "servidor nuevo: se generara la configuracion" }

# ── 2. PostgreSQL ─────────────────────────────────────────────────────────────────────────────────

Paso "2/9  PostgreSQL"

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
    if ($InstalarPostgresql) {
        Aviso "PostgreSQL no esta instalado; instalando con winget"
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Fallo "No hay winget. Instala PostgreSQL a mano (guia 01, 3.1) y vuelve a ejecutar."
        }
        winget install --id PostgreSQL.PostgreSQL.18 --accept-package-agreements --accept-source-agreements
        $psql = BuscarPsql
        if (-not $psql) { Fallo "La instalacion no ha dejado psql.exe donde se esperaba." }
        Aviso "winget instala con la contrasena de superusuario que pida su asistente; tenla a mano"
    }
    else {
        Fallo "PostgreSQL no esta instalado. Anade -InstalarPostgresql o instalalo a mano (guia 01, 3.1)."
    }
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

Paso "3/9  Base de datos `"$Bd`""

if ((PsqlValor -Consulta "SELECT 1 FROM pg_database WHERE datname = '$Bd';") -eq "1") {
    Igual "ya existe, no se toca"
}
else {
    # Las comillas dobles son imprescindibles: sin ellas PostgreSQL pasa el nombre a minusculas y la
    # cadena de conexion de la aplicacion, que pide "JudoAdministracion", no la encontraria.
    PsqlSuper -Argumentos @("-c", "CREATE DATABASE ""$Bd"" ENCODING 'UTF8' TEMPLATE template0;")
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

Paso "4/9  Roles y extensiones"

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

Paso "5/9  Certificado HTTPS"

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

if ($ConfiarCertificado) {
    # Necesario si este equipo va a ejecutar tambien la aplicacion de escritorio (el anfitrion):
    # si no confia en el certificado, no puede conectarse a su propio servidor.
    Import-Certificate -FilePath $crt -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
    Bien "certificado instalado como raiz de confianza de este equipo"
}

# ── 6. Configuración del servicio ─────────────────────────────────────────────────────────────────

Paso "6/9  Configuracion del servicio"

function EscribirConfiguracion {
    param([string]$Usuario, [string]$Clave, [bool]$Inicializar)

    $contenido = @"
{
    "//": [
        "Generado por Empaquetado/servidor/preparar-servidor.ps1.",
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
    # Sin BOM: el lector de configuracion de .NET lo admite, pero un JSON con BOM da problemas en
    # otras herramientas y no cuesta nada evitarlo.
    [IO.File]::WriteAllText($config, $contenido, (New-Object Text.UTF8Encoding($false)))
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

Paso "7/9  Esquema y datos basicos"

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

    # Para que Invoke-RestMethod valide el certificado hace falta confiar en el; si no se ha pedido
    # -ConfiarCertificado, se confia solo durante esta comprobacion y se deshace al terminar.
    $confianzaTemporal = $false
    if (-not $ConfiarCertificado) {
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

    & $psql -h localhost -U judo_api -d $Bd -c "CREATE TABLE comprobacion_permisos (x int);" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & $psql -h localhost -U judo_api -d $Bd -c "DROP TABLE comprobacion_permisos;" 2>&1 | Out-Null
        Aviso "judo_api PUEDE crear tablas y no deberia. Revisa los permisos del paso 4."
    }
    else { Bien "judo_api no puede alterar el esquema (correcto)" }
    $env:PGPASSWORD = $ClavePostgres
}

# ── 8. Arranque automático ────────────────────────────────────────────────────────────────────────

Paso "8/9  Arranque automatico"

if (-not $InstalarTarea) {
    Aviso "no solicitado (-InstalarTarea). El servicio no arrancara solo al encender el equipo"
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
}

# ── 9. Comprobación final y resumen ───────────────────────────────────────────────────────────────

Paso "9/9  Comprobacion"

if ($InstalarTarea) {
    if (-not $ConfiarCertificado) {
        Aviso "sin -ConfiarCertificado no se puede comprobar por HTTPS desde aqui; hazlo desde un puesto"
    }
    elseif (EsperarServicio -Segundos 20) { Bien "el servicio responde en https://localhost:$Puerto/api/estado" }
    else {
        Aviso "el servicio no responde todavia. Mira el estado de la tarea:"
        Aviso "  Get-ScheduledTaskInfo -TaskName JudoAdministracionApi"
    }
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
  judo_api         $ClaveApi      (con el que corre el servicio)

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
Write-Host "   Queda por hacer, segun la guia de instalacion:"
Write-Host "     - Cambiar la contrasena de admin@judo.com, que es 'admin123'   -> 3.9"
Write-Host "     - Dar de alta los usuarios de los puestos                      -> 3.9"
Write-Host "     - Abrir el $Puerto al 192.168.2.0/24 y cerrar el 5432          -> doc 02, 3.3"
Write-Host "     - Copiar $Nombre.crt a cada puesto e instalarlo                -> 4.2"
Write-Host ""
Write-Host "   El certificado que hay que repartir a los puestos:"
Write-Host "     $crt"
Write-Host ""
