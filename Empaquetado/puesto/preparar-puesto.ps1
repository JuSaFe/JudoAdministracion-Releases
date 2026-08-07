<#
.SYNOPSIS
    Deja un puesto de administración Windows listo para trabajar contra el servidor de la
    competición, y lo devuelve a como estaba al terminar el evento.

.DESCRIPTION
    La aplicación se instala con su instalador (Documentación/00); lo que hace este guion es lo que
    queda después y no trae el instalador, porque depende de la red y del servidor concretos:

      · instalar el certificado del servidor como raíz de confianza — sin esto la aplicación no conecta
      · asegurar la línea del archivo hosts que resuelve "judo-server"
      · la configuración de la aplicación, solo si este equipo se sale de lo normal
      · comprobar de punta a punta que el puesto llega al servidor

    La IP fija del puesto NO la pone este guion: eso es Empaquetado\red\configurar-red.ps1, que
    además guarda la configuración anterior para poder devolverla.

    ATENCIÓN: este guion NO se ha podido probar en un Windows real. La lógica es la misma que la de
    preparar-puesto.sh, que sí está probado. La primera vez, ejecútalo con -Simular.

.EXAMPLE
    .\preparar-puesto.ps1 -Certificado judo-server.crt

.EXAMPLE
    .\preparar-puesto.ps1 -Deshacer
#>

[CmdletBinding()]
param(
    [string] $Certificado,
    [string] $NombreServidor = "judo-server",
    [string] $IpServidor     = "192.168.2.3",
    [int]    $Puerto         = 8443,
    [string] $Dir            = "C:\Program Files\JudoAdministracion",
    [switch] $Anfitrion,
    [switch] $SinHosts,
    [switch] $Deshacer,
    [switch] $Simular,
    [switch] $Si
)

$ErrorActionPreference = "Stop"

$MARCA        = "# JudoAdministracion"
$MARCA_CONFIG = "Generado por Empaquetado/puesto/preparar-puesto"
$HOSTS        = "$env:SystemRoot\System32\drivers\etc\hosts"
$config       = Join-Path $Dir "appsettings.Local.json"

function Paso  ($t) { Write-Host ""; Write-Host "-- $t" -ForegroundColor Cyan }
function Bien  ($t) { Write-Host "   [ok] $t" -ForegroundColor Green }
function Aviso ($t) { Write-Host "   [!]  $t" -ForegroundColor Yellow }
function Igual ($t) { Write-Host "   [=]  $t" -ForegroundColor Green }
function Fallo ($t) { Write-Host "   [x]  $t" -ForegroundColor Red; exit 1 }

function Ejecutar {
    param([string]$Descripcion, [scriptblock]$Accion)
    if ($Simular) { Write-Host "   [simulado] $Descripcion" -ForegroundColor Yellow }
    else          { & $Accion }
}

function Confirmar ($pregunta) {
    if ($Si) { return $true }
    $r = Read-Host "   $pregunta [s/N]"
    return ($r -match '^[sSyY]$')
}

if (-not $Simular) {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fallo "Instalar un certificado en el almacen del equipo necesita administrador.
        Abre PowerShell como administrador y vuelve a ejecutarlo."
    }
}

# ── Archivo hosts ─────────────────────────────────────────────────────────────────────────────────
# La misma lógica y la misma marca que configurar-red.ps1, a propósito: cada guion se puede usar por
# separado, y quitar la línea con cualquiera de los dos deja el archivo igual.

function PonerHosts {
    if ((Test-Path $HOSTS) -and (Get-Content $HOSTS | Where-Object { $_ -like "*$MARCA*" })) {
        Igual "la linea de $NombreServidor ya esta en $HOSTS"
        return
    }
    if ($Simular) {
        Write-Host "   [simulado] anadiria a ${HOSTS}:  $IpServidor  $NombreServidor  $MARCA" -ForegroundColor Yellow
        return
    }
    Add-Content -Path $HOSTS -Value "$IpServidor`t$NombreServidor`t$MARCA" -Encoding ASCII
    Bien "$NombreServidor -> $IpServidor en $HOSTS"
}

function QuitarHosts {
    if (-not (Test-Path $HOSTS)) { return }
    $lineas = Get-Content $HOSTS
    if (-not ($lineas | Where-Object { $_ -like "*$MARCA*" })) {
        Igual "no habia ninguna linea de JudoAdministracion en $HOSTS"
        return
    }
    if ($Simular) {
        Write-Host "   [simulado] quitaria de $HOSTS las lineas marcadas con $MARCA" -ForegroundColor Yellow
        return
    }
    $lineas | Where-Object { $_ -notlike "*$MARCA*" } | Set-Content -Path $HOSTS -Encoding ASCII
    Bien "linea de $NombreServidor quitada de $HOSTS"
}

# ── Certificado ───────────────────────────────────────────────────────────────────────────────────

function CertificadosInstalados {
    # Por asunto: es lo unico que se puede buscar cuando ya no tenemos el archivo delante.
    Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq "CN=$NombreServidor" }
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
#  DESHACER
# ══════════════════════════════════════════════════════════════════════════════════════════════════

if ($Deshacer) {
    Write-Host ""
    Write-Host "Devolver este puesto a como estaba" -ForegroundColor Cyan
    if ($Simular) { Aviso "modo simulacion: no se cambia nada" }

    if (-not (Confirmar "Quito el certificado de $NombreServidor y su configuracion?")) {
        Write-Host "   Cancelado."; exit 0
    }

    Paso "1/3  Certificado"
    $instalados = @(CertificadosInstalados)
    if ($instalados.Count -eq 0) {
        Igual "el certificado no estaba en el almacen del equipo"
    }
    else {
        foreach ($c in $instalados) {
            Ejecutar "quitar de Cert:\LocalMachine\Root el certificado $($c.Thumbprint)" {
                Remove-Item -Path "Cert:\LocalMachine\Root\$($c.Thumbprint)" -Force
            }
        }
        Bien "certificado de $NombreServidor retirado ($($instalados.Count))"
    }

    Paso "2/3  Configuracion de la aplicacion"
    if (Test-Path $config) {
        if ((Get-Content $config -Raw) -like "*$MARCA_CONFIG*") {
            Ejecutar "borrar $config" { Remove-Item $config -Force }
            Bien "appsettings.Local.json (el que puso este guion) eliminado"
        }
        else {
            Aviso "hay un appsettings.Local.json que NO escribio este guion: no lo toco"
            Aviso "  $config"
        }
    }
    else { Igual "no hay configuracion local que quitar" }

    Paso "3/3  Archivo hosts"
    if (-not $SinHosts) { QuitarHosts } else { Igual "sin tocar (-SinHosts)" }

    Write-Host ""
    Write-Host "Puesto limpio." -ForegroundColor Green
    Write-Host ""
    Write-Host "   La aplicacion sigue instalada; se desinstala desde Programas y caracteristicas."
    Write-Host ""
    Write-Host "   Falta devolver la red, que es lo que le importa a quien use este equipo:" -ForegroundColor Yellow
    Write-Host "     ..\red\configurar-red.ps1 -Deshacer"
    Write-Host ""
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
#  PREPARAR
# ══════════════════════════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "Preparacion de un puesto de administracion" -ForegroundColor Cyan
Write-Host "   servidor $NombreServidor ($IpServidor), puerto $Puerto"
if ($Anfitrion) { Write-Host "   este equipo es el ANFITRION" }
if ($Simular)   { Aviso "modo simulacion: no se cambia nada" }

# ── 1. Comprobaciones previas ─────────────────────────────────────────────────────────────────────

Paso "1/5  Comprobaciones previas"

if (-not $Certificado) {
    # Lo normal es traerlo en un USB y ejecutar el guion desde esa carpeta.
    foreach ($c in @(".\$NombreServidor.crt", ".\judo-server.crt")) {
        if (Test-Path $c) { $Certificado = $c; break }
    }
}

if (-not ($Certificado -and (Test-Path $Certificado))) {
    Fallo "No encuentro el certificado del servidor.
        Copialo desde el servidor ($NombreServidor.crt, NO el .pfx) e indicalo con
        -Certificado <ruta>. Se genera en la guia 01, 3.4."
}

try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
        (Resolve-Path $Certificado).Path)
}
catch {
    Fallo "$Certificado no se puede leer como certificado.
        Tiene que ser el .crt en base 64 (PEM) o en DER, no el .pfx."
}
Bien "certificado legible: $Certificado"

# Que sirva para este nombre: si se emitio sin el, la aplicacion lo rechazara y el error aparecera
# mucho mas tarde, al abrirla.
$nombres = @()
try { $nombres = @($cert.DnsNameList | ForEach-Object { $_.Unicode }) } catch { }
if ($nombres -contains $NombreServidor) {
    Bien "sirve para el nombre $NombreServidor"
}
else {
    Aviso "el certificado no parece incluir $NombreServidor entre sus nombres"
    Aviso "nombres que trae: $($nombres -join ', ')"
    Aviso "si es asi, la aplicacion rechazara la conexion; hay que reemitirlo (guia 01, 3.4)"
    if (-not (Confirmar "Seguir de todas formas?")) { Write-Host "   Cancelado."; exit 0 }
}
Bien "valido hasta $($cert.NotAfter.ToString('yyyy-MM-dd'))"

if (Test-Path (Join-Path $Dir "JudoAdministracion.exe")) {
    Bien "aplicacion instalada en $Dir"
    $appInstalada = $true
}
else {
    Aviso "no encuentro la aplicacion en $Dir"
    Aviso "el certificado se puede instalar igual; la aplicacion, despues (guia 01, 4.1)"
    $appInstalada = $false
}

# ── 2. Certificado ────────────────────────────────────────────────────────────────────────────────

Paso "2/5  Certificado en el almacen del equipo"

if (@(CertificadosInstalados).Count -gt 0) {
    Igual "ya habia un certificado de $NombreServidor instalado; se anade el nuevo"
    Aviso "si el servidor se reinstalo, quita el viejo con -Deshacer antes"
}

# En LocalMachine y no en CurrentUser: la aplicacion puede acabar ejecutandose con otra cuenta, y
# .NET consulta el almacen del equipo.
Ejecutar "Import-Certificate -FilePath $Certificado -CertStoreLocation Cert:\LocalMachine\Root" {
    Import-Certificate -FilePath (Resolve-Path $Certificado).Path `
        -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
}
Bien "instalado como raiz de confianza de este equipo"

# ── 3. Archivo hosts ──────────────────────────────────────────────────────────────────────────────

Paso "3/5  Nombre del servidor"

if ($SinHosts)      { Igual "archivo hosts sin tocar (-SinHosts)" }
elseif ($Anfitrion) { Igual "el anfitrion conecta por localhost: no necesita la linea de hosts" }
else                { PonerHosts }

# ── 4. Configuración de la aplicación ─────────────────────────────────────────────────────────────

Paso "4/5  Configuracion de la aplicacion"

# Un puesto normal NO necesita archivo de configuracion: el appsettings.json que trae el paquete ya
# apunta a https://judo-server:8443 y sin credenciales de base de datos, que es exactamente lo que
# tiene que ser. Solo se escribe cuando este equipo se sale de eso.
$urlApi = if ($Anfitrion) { "https://localhost:$Puerto" } else { "https://${NombreServidor}:$Puerto" }
$haceFalta = $Anfitrion -or ($NombreServidor -ne "judo-server") -or ($Puerto -ne 8443)

if (-not $haceFalta) {
    Igual "no hace falta: el paquete ya viene apuntando a $urlApi"
}
elseif (-not $appInstalada) {
    Aviso "haria falta escribir appsettings.Local.json con ApiBaseUrl=$urlApi,"
    Aviso "pero la aplicacion no esta instalada. Vuelve a ejecutar el guion despues."
}
elseif ((Test-Path $config) -and -not ((Get-Content $config -Raw) -like "*$MARCA_CONFIG*")) {
    Aviso "ya hay un appsettings.Local.json que no escribio este guion: no lo toco"
    Aviso "comprueba a mano que ApiBaseUrl sea $urlApi"
}
elseif ($Simular) {
    Write-Host "   [simulado] escribiria $config con ApiBaseUrl=$urlApi" -ForegroundColor Yellow
}
else {
    $contenido = @"
{
    "//": [
        "$MARCA_CONFIG.ps1",
        "ApiBaseUrl: donde escucha el servidor de la competicion.",
        "ConnectionString vacia: un puesto de la red NO habla con PostgreSQL.",
        "Ver Documentacion/01-Guia-de-Instalacion.md, 4.4."
    ],
    "ApiBaseUrl": "$urlApi",
    "ConnectionString": ""
}
"@
    [IO.File]::WriteAllText($config, $contenido, (New-Object Text.UTF8Encoding($false)))
    Bien "escrita con ApiBaseUrl=$urlApi"
    if ($Anfitrion) {
        Aviso "el anfitrion necesita ademas ConnectionString mientras queden pantallas sin migrar;"
        Aviso "ponla a mano (guia 01, 5)"
    }
}

# ── 5. Comprobación de punta a punta ──────────────────────────────────────────────────────────────

Paso "5/5  Llega este puesto al servidor?"

# Estas comprobaciones se hacen tambien en simulacion: no cambian nada, y son lo mas util del guion
# —sirven para diagnosticar un puesto ya montado sin tocarle nada—.
if ($Simular) {
    Aviso "en simulacion el certificado no esta instalado todavia: es normal que la"
    Aviso "comprobacion 4 diga que no es de confianza"
}

$destino = if ($Anfitrion) { "localhost" } else { $NombreServidor }

# En este orden a proposito: cada comprobacion que falla dice en que capa esta el problema, en lugar
# de dejar un "no conecta" genérico. Es la lista de la guia 01, 6.
if (-not $Anfitrion) {
    if (Test-Connection -ComputerName $IpServidor -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        Bien "1. llego al servidor $IpServidor"
    }
    else { Aviso "1. no llego a ${IpServidor}: revisa la red (configurar-red.ps1) y el cable" }

    if (Test-Connection -ComputerName $NombreServidor -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        Bien "2. el nombre $NombreServidor resuelve"
    }
    else { Aviso "2. $NombreServidor no resuelve: falta la linea de $HOSTS" }
}

$puertoAbierto = (Test-NetConnection -ComputerName $destino -Port $Puerto `
                    -InformationLevel Quiet -WarningAction SilentlyContinue)
if ($puertoAbierto) { Bien "3. el puerto $Puerto esta abierto" }
else {
    Aviso "3. el puerto $Puerto no responde: el servicio no esta arrancado, o lo cierra el"
    Aviso "   cortafuegos del servidor (doc 02, 3.3)"
}

# La prueba de fuego: HTTPS validando el certificado. Si responde, el paso 2 esta bien hecho y la
# aplicacion va a poder conectar.
$listo = $false
try {
    $r = Invoke-RestMethod "https://${destino}:$Puerto/api/estado" -TimeoutSec 8
    if ($r.estado -eq "ok") {
        Bien "4. HTTPS de confianza: el servidor responde estado=ok"
        $listo = $true
    }
}
catch {
    Aviso "4. la conexion HTTPS falla"
    if ($puertoAbierto) {
        Aviso "   el servidor responde en el puerto, pero su certificado no es de confianza aqui,"
        Aviso "   o se emitio para otro nombre. Revisa el paso 2."
    }
    else { Aviso "   el servidor no responde en https://${destino}:$Puerto" }
}

if ($listo) {
    Write-Host ""
    Write-Host "   Este puesto esta listo." -ForegroundColor Green
}

Write-Host ""
Write-Host "   Al acabar la competicion, este puesto se limpia con:"
Write-Host "     .\preparar-puesto.ps1 -Deshacer"
Write-Host "     ..\red\configurar-red.ps1 -Deshacer"
Write-Host ""
