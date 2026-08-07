<#
.SYNOPSIS
    Configura la red de un equipo Windows para la competición, y la deja como estaba al terminar.

.DESCRIPTION
    Pone la IP fija que le corresponde según su papel en el evento, la puerta de enlace, los DNS y la
    línea del archivo hosts que resuelve "judo-server". Antes de tocar nada guarda la configuración
    anterior, para que al acabar la competición se pueda devolver el equipo a como estaba —que es
    importante cuando el portátil es de alguien y esa misma tarde se lo lleva a su casa—.

    El plan de direcciones es el de Documentación/02-Red-y-Direccionamiento-IP.md.

    ATENCIÓN: este guion NO se ha podido probar en un Windows real. La lógica es la misma que la de
    configurar-red.sh, que sí está probado, y los comandos son los estándar del sistema. La primera
    vez, ejecútalo con -Simular para ver lo que haría.

.EXAMPLE
    .\configurar-red.ps1

.EXAMPLE
    .\configurar-red.ps1 -Rol puesto -Ip 192.168.2.6 -Si

.EXAMPLE
    .\configurar-red.ps1 -Deshacer
#>

[CmdletBinding()]
param(
    [ValidateSet("servidor", "puesto", "marcador", "pantalla")]
    [string] $Rol,
    [string] $Ip,
    [string] $Interfaz,                              # nombre del adaptador (Get-NetAdapter)
    [string] $Red            = "192.168.2",
    [string] $Puerta         = "192.168.2.1",
    [string] $DnsAlternativo = "8.8.8.8",
    [string] $NombreServidor = "judo-server",
    [string] $IpServidor     = "192.168.2.3",
    [string] $Estado         = "C:\ProgramData\JudoAdministracion\red-anterior.json",
    [switch] $SinHosts,
    [switch] $Deshacer,
    [switch] $Simular,
    [switch] $Si
)

$ErrorActionPreference = "Stop"

$MARCA = "# JudoAdministracion"
$HOSTS = "$env:SystemRoot\System32\drivers\etc\hosts"

function Paso  ($t) { Write-Host ""; Write-Host "-- $t" -ForegroundColor Cyan }
function Bien  ($t) { Write-Host "   [ok] $t" -ForegroundColor Green }
function Aviso ($t) { Write-Host "   [!]  $t" -ForegroundColor Yellow }
function Igual ($t) { Write-Host "   [=]  $t" -ForegroundColor Green }
function Fallo ($t) { Write-Host "   [x]  $t" -ForegroundColor Red; exit 1 }

# En modo simulación, todo lo que cambiaría el sistema pasa por aquí y solo se enseña.
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

function Responde ($direccion) {
    return (Test-Connection -ComputerName $direccion -Count 1 -Quiet -ErrorAction SilentlyContinue)
}

if (-not $Simular) {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fallo "Abre PowerShell como administrador y vuelve a ejecutarlo."
    }
}

# ── Rangos del plan de direcciones ────────────────────────────────────────────────────────────────

function RangoDesde ($r) { switch ($r) { "servidor" {3} "puesto" {5} "marcador" {10} "pantalla" {20} } }
function RangoHasta  ($r) { switch ($r) { "servidor" {3} "puesto" {9} "marcador" {19} "pantalla" {29} } }
function QueEs ($r) {
    switch ($r) {
        "servidor" { "Servidor: PostgreSQL y la API" }
        "puesto"   { "Puesto de administracion: la aplicacion de escritorio" }
        "marcador" { "Marcador de tatami" }
        "pantalla" { "Pantalla de visualizacion" }
    }
}

# ── Interfaces del equipo ─────────────────────────────────────────────────────────────────────────

function ElegirInterfaz {
    # Se enseñan también las desconectadas: el cable de la competición puede no estar puesto todavía.
    $adaptadores = @(Get-NetAdapter -Physical | Where-Object { $_.Status -ne "Disabled" } |
                     Sort-Object -Property @{ Expression = { $_.Status -eq "Up" } } -Descending)

    if ($adaptadores.Count -eq 0) { Fallo "No encuentro ningun adaptador de red." }
    if ($adaptadores.Count -eq 1) {
        Bien "unico adaptador: $($adaptadores[0].Name)"
        return $adaptadores[0]
    }

    Write-Host "   Que interfaz de red hay que configurar?"
    Write-Host ""
    for ($i = 0; $i -lt $adaptadores.Count; $i++) {
        $a = $adaptadores[$i]
        Write-Host ("     {0}) {1,-22} {2,-12} {3}" -f ($i + 1), $a.Name, $a.Status, $a.InterfaceDescription)
    }
    Write-Host ""
    Aviso "para lo critico, cable antes que Wi-Fi (doc 02, 6)"
    Write-Host ""

    while ($true) {
        $e = Read-Host "   Numero [1-$($adaptadores.Count)]"
        if ($e -match '^\d+$' -and [int]$e -ge 1 -and [int]$e -le $adaptadores.Count) {
            return $adaptadores[[int]$e - 1]
        }
        Write-Host "   No es un numero de la lista."
    }
}

# ── Estado anterior ───────────────────────────────────────────────────────────────────────────────

function GuardarEstado ($adaptador) {
    $indice = $adaptador.ifIndex
    $ipv4   = Get-NetIPInterface -InterfaceIndex $indice -AddressFamily IPv4
    $anterior = [ordered]@{
        interfaz = $adaptador.Name
        indice   = $indice
        metodo   = if ($ipv4.Dhcp -eq "Enabled") { "dhcp" } else { "manual" }
        ip       = ""
        prefijo  = 24
        puerta   = ""
        dns      = @()
    }

    if ($anterior.metodo -eq "manual") {
        $dir = Get-NetIPAddress -InterfaceIndex $indice -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($dir) { $anterior.ip = $dir.IPAddress; $anterior.prefijo = $dir.PrefixLength }
        $ruta = Get-NetRoute -InterfaceIndex $indice -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($ruta) { $anterior.puerta = $ruta.NextHop }
    }

    # Los DNS se guardan siempre: se pueden haber puesto a mano aunque la IP venga por DHCP.
    $dns = Get-DnsClientServerAddress -InterfaceIndex $indice -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($dns) { $anterior.dns = @($dns.ServerAddresses) }

    if ($Simular) {
        Write-Host "   [simulado] guardaria en ${Estado}:" -ForegroundColor Yellow
        Write-Host "              $($anterior | ConvertTo-Json -Compress)"
        return
    }

    $carpeta = Split-Path $Estado -Parent
    if (-not (Test-Path $carpeta)) { New-Item -ItemType Directory -Path $carpeta -Force | Out-Null }
    $anterior | ConvertTo-Json | Set-Content -Path $Estado -Encoding UTF8
    Bien "configuracion anterior guardada ($($anterior.metodo)) en $Estado"
}

function LimpiarIPv4 ($indice) {
    # Hay que quitar la ruta por defecto y la dirección antes de poner otras, o New-NetIPAddress
    # falla diciendo que el objeto ya existe.
    Remove-NetRoute -InterfaceIndex $indice -DestinationPrefix "0.0.0.0/0" `
        -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetIPAddress -InterfaceIndex $indice -AddressFamily IPv4 `
        -Confirm:$false -ErrorAction SilentlyContinue
}

function AplicarEstatica ($indice, $direccion) {
    Ejecutar "Set-NetIPInterface -InterfaceIndex $indice -Dhcp Disabled" {
        Set-NetIPInterface -InterfaceIndex $indice -Dhcp Disabled
        LimpiarIPv4 $indice
    }
    Ejecutar "New-NetIPAddress -IPAddress $direccion -PrefixLength 24 -DefaultGateway $Puerta" {
        New-NetIPAddress -InterfaceIndex $indice -IPAddress $direccion `
            -PrefixLength 24 -DefaultGateway $Puerta | Out-Null
    }
    Ejecutar "Set-DnsClientServerAddress -ServerAddresses $Puerta,$DnsAlternativo" {
        Set-DnsClientServerAddress -InterfaceIndex $indice -ServerAddresses $Puerta, $DnsAlternativo
    }
}

function RestaurarEstado ($anterior) {
    $indice = $anterior.indice
    if ($anterior.metodo -eq "manual" -and $anterior.ip) {
        Ejecutar "volver a la IP fija anterior $($anterior.ip)" {
            Set-NetIPInterface -InterfaceIndex $indice -Dhcp Disabled
            LimpiarIPv4 $indice
            if ($anterior.puerta) {
                New-NetIPAddress -InterfaceIndex $indice -IPAddress $anterior.ip `
                    -PrefixLength $anterior.prefijo -DefaultGateway $anterior.puerta | Out-Null
            } else {
                New-NetIPAddress -InterfaceIndex $indice -IPAddress $anterior.ip `
                    -PrefixLength $anterior.prefijo | Out-Null
            }
        }
    }
    else {
        Ejecutar "volver a automatico (DHCP)" {
            LimpiarIPv4 $indice
            Set-NetIPInterface -InterfaceIndex $indice -Dhcp Enabled
        }
    }

    if ($anterior.dns -and @($anterior.dns).Count -gt 0) {
        Ejecutar "devolver los DNS anteriores: $($anterior.dns -join ', ')" {
            Set-DnsClientServerAddress -InterfaceIndex $indice -ServerAddresses @($anterior.dns)
        }
    }
    else {
        Ejecutar "quitar los DNS puestos a mano (volver a los del DHCP)" {
            Set-DnsClientServerAddress -InterfaceIndex $indice -ResetServerAddresses
        }
    }
}

# ── Archivo hosts ─────────────────────────────────────────────────────────────────────────────────

function PonerHosts {
    QuitarHosts -Silencioso
    if ($Simular) {
        Write-Host "   [simulado] anadiria a ${HOSTS}:  $IpServidor  $NombreServidor  $MARCA" -ForegroundColor Yellow
        return
    }
    Add-Content -Path $HOSTS -Value "$IpServidor`t$NombreServidor`t$MARCA" -Encoding ASCII
    Bien "$NombreServidor -> $IpServidor en $HOSTS"
}

function QuitarHosts {
    param([switch]$Silencioso)
    if (-not (Test-Path $HOSTS)) { return }
    $lineas = Get-Content $HOSTS
    if (-not ($lineas | Where-Object { $_ -like "*$MARCA*" })) {
        if (-not $Silencioso) { Igual "no habia ninguna linea de JudoAdministracion en $HOSTS" }
        return
    }
    if ($Simular) {
        Write-Host "   [simulado] quitaria de $HOSTS las lineas marcadas con $MARCA" -ForegroundColor Yellow
        return
    }
    # Solo las lineas con nuestra marca; el resto del archivo no se toca.
    $lineas | Where-Object { $_ -notlike "*$MARCA*" } | Set-Content -Path $HOSTS -Encoding ASCII
    if (-not $Silencioso) { Bien "linea de $NombreServidor quitada de $HOSTS" }
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
#  DESHACER
# ══════════════════════════════════════════════════════════════════════════════════════════════════

if ($Deshacer) {
    Write-Host ""
    Write-Host "Devolver la red de este equipo a como estaba" -ForegroundColor Cyan
    if ($Simular) { Aviso "modo simulacion: no se cambia nada" }

    Paso "1/3  Configuracion anterior"

    if (Test-Path $Estado) {
        $anterior = Get-Content $Estado -Raw | ConvertFrom-Json
        Bien "encontrada: interfaz '$($anterior.interfaz)', estaba en $($anterior.metodo)"
        if ($anterior.metodo -eq "manual") { Bien "IP anterior $($anterior.ip), puerta $($anterior.puerta)" }
    }
    else {
        Aviso "no hay $Estado: no se como estaba este equipo"
        Aviso "lo mejor que puedo hacer es dejar la interfaz en automatico (DHCP)"
        $adaptador = if ($Interfaz) { Get-NetAdapter -Name $Interfaz } else { ElegirInterfaz }
        $anterior = [ordered]@{
            interfaz = $adaptador.Name; indice = $adaptador.ifIndex
            metodo = "dhcp"; ip = ""; prefijo = 24; puerta = ""; dns = @()
        }
    }

    if (-not (Confirmar "Restauro la interfaz '$($anterior.interfaz)'?")) { Write-Host "   Cancelado."; exit 0 }

    Paso "2/3  Restaurando la interfaz"
    RestaurarEstado $anterior
    Bien "interfaz '$($anterior.interfaz)' devuelta a $($anterior.metodo)"

    Paso "3/3  Archivo hosts"
    QuitarHosts

    if ((Test-Path $Estado) -and (-not $Simular)) {
        Remove-Item $Estado -Force
        Bien "$Estado eliminado"
    }

    Write-Host ""
    Write-Host "Red restaurada." -ForegroundColor Green
    Write-Host ""
    Write-Host "   Comprueba que el equipo vuelve a navegar:"
    Write-Host "     Test-NetConnection 8.8.8.8"
    Write-Host "     Get-NetIPConfiguration -InterfaceAlias '$($anterior.interfaz)'"
    Write-Host ""
    Write-Host "   El certificado del servidor, si se instalo, se quita con:"
    Write-Host "     Empaquetado\puesto\preparar-puesto.ps1 -Deshacer"
    Write-Host ""
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
#  CONFIGURAR
# ══════════════════════════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "Configuracion de red para la competicion" -ForegroundColor Cyan
Write-Host "   red $Red.0/24 - puerta $Puerta - servidor $NombreServidor ($IpServidor)"
if ($Simular) { Aviso "modo simulacion: no se cambia nada" }

# ── 1. Interfaz ───────────────────────────────────────────────────────────────────────────────────

Paso "1/6  Interfaz de red"

$adaptador = if ($Interfaz) { Get-NetAdapter -Name $Interfaz } else { ElegirInterfaz }
Bien "elegida: $($adaptador.Name) ($($adaptador.InterfaceDescription))"
if ($adaptador.Status -ne "Up") { Aviso "esta interfaz esta $($adaptador.Status): conecta el cable" }

# ── 2. Rol ────────────────────────────────────────────────────────────────────────────────────────

Paso "2/6  Papel de este equipo en la competicion"

if (-not $Rol) {
    Write-Host "   Que va a ser este equipo?"
    Write-Host ""
    Write-Host ("     1) {0,-30} {1}" -f "$Red.5 - $Red.9",   (QueEs "puesto"))
    Write-Host ("     2) {0,-30} {1}" -f "$Red.3",            (QueEs "servidor"))
    Write-Host ("     3) {0,-30} {1}" -f "$Red.10 - $Red.19", (QueEs "marcador"))
    Write-Host ("     4) {0,-30} {1}" -f "$Red.20 - $Red.29", (QueEs "pantalla"))
    Write-Host ""
    switch (Read-Host "   Numero [1-4]") {
        "1" { $Rol = "puesto" }
        "2" { $Rol = "servidor" }
        "3" { $Rol = "marcador" }
        "4" { $Rol = "pantalla" }
        default { Fallo "No es un numero de la lista." }
    }
}
Bien (QueEs $Rol)

# ── 3. Dirección ──────────────────────────────────────────────────────────────────────────────────

Paso "3/6  Direccion IP"

$primero = RangoDesde $Rol
$ultimo  = RangoHasta $Rol

# El escaneo solo dice algo si ya estamos en esa red; si no, todas parecerian libres.
$enLaRed = [bool](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.IPAddress -like "$Red.*" })

if (-not $Ip) {
    if ($primero -eq $ultimo) {
        $Ip = "$Red.$primero"
        Bien "al rol $Rol le corresponde $Ip"
    }
    else {
        Write-Host "   Direcciones del rango de ${Rol}:"
        Write-Host ""
        if (-not $enLaRed) { Aviso "este equipo no esta aun en $Red.0/24: no puedo ver cuales estan ocupadas" }
        $sugerida = ""
        foreach ($n in $primero..$ultimo) {
            $candidata = "$Red.$n"
            if ($enLaRed -and (Responde $candidata)) {
                Write-Host ("     {0,-16} responde: OCUPADA" -f $candidata)
            }
            elseif ($enLaRed) {
                Write-Host ("     {0,-16} libre" -f $candidata)
                if (-not $sugerida) { $sugerida = $candidata }
            }
            else { Write-Host ("     {0,-16}" -f $candidata) }
        }
        Write-Host ""
        if (-not $sugerida) { $sugerida = "$Red.$primero" }
        $r = Read-Host "   IP para este equipo [$sugerida]"
        $Ip = if ($r) { $r } else { $sugerida }
    }
}

if ($Ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { Fallo "'$Ip' no parece una direccion IP." }

$ultimoOcteto = [int]($Ip.Split(".")[3])
if ($Ip.Substring(0, $Ip.LastIndexOf(".")) -ne $Red) {
    Aviso "$Ip no esta en la red $Red.0/24 del plan de direcciones"
}
elseif ($ultimoOcteto -lt $primero -or $ultimoOcteto -gt $ultimo) {
    Aviso "$Ip queda fuera del rango de $Rol ($Red.$primero - $Red.$ultimo)"
    Aviso "revisa el plan de direcciones (doc 02, 1) antes de seguir"
}

if ($enLaRed -and (Responde $Ip)) {
    Aviso "$Ip ya responde: hay otro equipo usandola"
    Aviso "dos equipos con la misma IP funcionan a ratos, y es el fallo mas dificil de diagnosticar"
    if (-not (Confirmar "Seguir de todas formas?")) { Write-Host "   Cancelado."; exit 0 }
}
Bien "se usara $Ip"

# ── 4. Confirmación ───────────────────────────────────────────────────────────────────────────────

Paso "4/6  Resumen"

Write-Host "     interfaz          $($adaptador.Name)"
Write-Host "     direccion IP      $Ip"
Write-Host "     mascara           255.255.255.0"
Write-Host "     puerta de enlace  $Puerta"
Write-Host "     DNS               $Puerta, $DnsAlternativo"
if (-not $SinHosts) { Write-Host "     hosts             $NombreServidor -> $IpServidor" }
Write-Host ""
Aviso "se perdera la conexion un momento al aplicar los cambios"
if (-not (Confirmar "Aplico esta configuracion?")) { Write-Host "   Cancelado."; exit 0 }

# ── 5. Aplicar ────────────────────────────────────────────────────────────────────────────────────

Paso "5/6  Aplicando"

GuardarEstado $adaptador
AplicarEstatica $adaptador.ifIndex $Ip
Bien "interfaz '$($adaptador.Name)' con IP fija $Ip"

if (-not $SinHosts) { PonerHosts } else { Igual "archivo hosts sin tocar (-SinHosts)" }

# ── 6. Verificación ───────────────────────────────────────────────────────────────────────────────

Paso "6/6  Comprobacion"

if ($Simular) {
    Aviso "en simulacion no hay nada que comprobar"
}
else {
    Start-Sleep -Seconds 3      # dar tiempo a que la interfaz se levante con la configuracion nueva

    if (Responde $Puerta) { Bien "llego a la puerta de enlace $Puerta" }
    else { Aviso "no llego a ${Puerta}: revisa el cable y que el router sea el de la competicion" }

    if ($Ip -ne $IpServidor) {
        if (Responde $IpServidor) { Bien "llego al servidor $IpServidor" }
        else { Aviso "no llego al servidor $IpServidor (esta encendido?)" }

        if (-not $SinHosts) {
            if (Responde $NombreServidor) { Bien "el nombre $NombreServidor resuelve" }
            else { Aviso "$NombreServidor no resuelve: revisa $HOSTS" }
        }
    }
}

Write-Host ""
Write-Host "Red configurada." -ForegroundColor Green
Write-Host ""
Write-Host "   Al acabar la competicion, devuelve el equipo a como estaba:" -ForegroundColor Yellow
Write-Host "     .\configurar-red.ps1 -Deshacer"
Write-Host ""
if ($Rol -eq "puesto") {
    Write-Host "   Ahora, la parte de la aplicacion en este puesto (certificado y comprobaciones):"
    Write-Host "     ..\puesto\preparar-puesto.ps1 -Certificado judo-server.crt"
    Write-Host ""
}
