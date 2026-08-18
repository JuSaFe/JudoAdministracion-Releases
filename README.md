<!--
  PORTADA DEL REPOSITORIO PÚBLICO DE DESCARGAS.

  No se edita allí: el trabajo `publicar` de .github/workflows/instaladores.yml copia este archivo
  como README.md del repositorio público en cada release, junto con la licencia, la documentación y
  los guiones de instalación. Cualquier cambio hecho a mano en el otro repositorio se pierde en la
  siguiente publicación; se edita aquí.
-->

<div align="center">

<img src="Assets/Icons/judo-256.png" alt="JudoAdministración" width="128">

# JudoAdministración

**Gestión completa de competiciones de judo: inscripción, pesaje, sorteo, combates e informes.**

[![Descargar](https://img.shields.io/badge/Descargar-última%20versión-brightgreen?logo=github)](../../releases/latest)
[![Licencia](https://img.shields.io/badge/Licencia-Uso%20libre%20·%20sin%20derivados-green.svg)](LICENSE)
[![Windows · macOS · Linux](https://img.shields.io/badge/Windows%20·%20macOS%20·%20Linux-multiplataforma-informational)](#instalación)

</div>

---

## Qué es

Una aplicación de escritorio para dirigir una competición de judo de principio a fin, pensada para
usarse **en el pabellón el día del campeonato**: varios puestos de trabajo conectados a un servidor
local, sin depender de Internet.

Cubre el recorrido completo de un evento:

| Módulo | Qué hace |
|---|---|
| **Eventos** | Alta de campeonatos, categorías, tatamis y sistemas de competición. Exportación e importación |
| **Participantes** | Inscripción, edición, listados y resúmenes por club, categoría y peso |
| **Pesaje** | Registro de pesos, control de fallidos y reubicación automática de categoría |
| **Sorteo** | Emparejamiento por sistema (eliminatoria, liga, repesca, doble liga) y orden de salida |
| **Combates** | Cuadros por tatami, resultados y avance automático de rondas |
| **Informes** | Medallero, estadísticas, hojas de pesos, agenda de tatami y cuadros de combate en PDF |

Todo lo que se genera en papel (cuadros, actas, medalleros) sale en **PDF listo para imprimir**, con
vista previa dentro de la propia aplicación.

## Cómo funciona

```mermaid
flowchart LR
    subgraph puestos["Puestos · 192.168.2.5-.9"]
        APP["Aplicación de escritorio"]
    end
    subgraph servidor["Servidor · 192.168.2.3"]
        API["Servicio (API)"]
        DB[("PostgreSQL<br/>solo local")]
    end
    APP -->|HTTPS + WebSocket| API
    API --> DB
```

Un equipo hace de **servidor**: es el único que guarda los datos y el único que abre la base de
datos. El resto son **puestos** que se conectan a él por la red local. Los cambios aparecen al
instante en todos los puestos, y si dos personas editan lo mismo a la vez el conflicto se avisa en
lugar de perderse un dato.

## Instalación

Descarga el paquete de tu sistema desde la [**última versión**](../../releases/latest):

| Equipo | Qué instalar | Windows | macOS | Linux |
|---|---|---|---|---|
| **Servidor** | Servicio (API) | `.zip` | `.tar.gz` | `.tar.gz` |
| **Puestos** | Aplicación de escritorio | `.exe` | `.dmg` | `.AppImage` |

> El equipo servidor necesita **los dos** paquetes si además es el que dirige la competición.

Los paquetes son **autocontenidos**: no hace falta instalar .NET en ningún equipo. Sí hace falta
PostgreSQL 18, pero sólo en el servidor.

**Sigue la [Guía de instalación](Documentación/01-Guía-de-Instalación.md)**, que cubre el proceso
completo paso a paso. Los guiones de la carpeta `Empaquetado/` automatizan casi todo:

| Guion | Qué hace | Dónde se ejecuta |
|---|---|---|
| `Empaquetado/red/configurar-red.sh` (`.ps1`) | Direcciones IP fijas y archivo *hosts* | Todos los equipos |
| `Empaquetado/servidor/preparar-servidor.sh` (`.ps1`) | PostgreSQL, base de datos, roles, certificado y servicio | Servidor |
| `Empaquetado/puesto/preparar-puesto.sh` (`.ps1`) | Certificado de confianza y conexión al servidor | Puestos |

El del servidor **no hace falta descargarlo de aquí**: viene dentro del propio paquete del servicio,
junto al SQL de roles que necesita. Se ejecuta en la carpeta donde se haya descomprimido.

> **Windows.** PowerShell no ejecuta guiones `.ps1` con la directiva que trae de fábrica («la
> ejecución de scripts está deshabilitada en este sistema»). Los tres se lanzan igual, desde
> PowerShell abierto como administrador:
> `powershell -ExecutionPolicy Bypass -File .\preparar-servidor.ps1 -InstalarPostgresql -InstalarTarea`.
> Eso vale sólo para esa ejecución; no cambia la configuración del equipo.

## Documentación

| Documento | Contenido |
|---|---|
| [01 · Guía de instalación](Documentación/01-Guía-de-Instalación.md) | Puesta en marcha del servidor y de los puestos, paso a paso |
| [02 · Red y direccionamiento IP](Documentación/02-Red-y-Direccionamiento-IP.md) | Direcciones, puertos y cortafuegos |

## Soporte

¿Un fallo, una duda o una propuesta? Abre una
[**incidencia**](../../issues/new) describiendo qué ocurre, en qué sistema y con qué versión.

El desarrollo se lleva en un repositorio privado; este de aquí es el punto de descarga y el canal de
incidencias.

## Licencia

Software **de código propietario y uso gratuito**. Texto completo en **[LICENSE](LICENSE)**.

**Se permite**, gratis y sin límite de equipos, usuarios ni tiempo:

- Descargar, instalar y ejecutar el programa, incluso con fines profesionales o comerciales.
- Redistribuirlo **íntegro y sin modificar**, a título gratuito y conservando todos los avisos.

**No se permite** modificarlo, crear obras derivadas, distribuir versiones modificadas, republicarlo
en otro repositorio ni reutilizar partes de él en otros proyectos.

La **propiedad intelectual del programa es de Juan Cotolí San Félix**.

> **Marcas y logotipos.** Los escudos federativos que incluye la aplicación son propiedad de sus
> respectivas entidades y no están cubiertos por esta licencia.

Las bibliotecas de terceros que incorpora se rigen por sus propias licencias, detalladas en
[TERCEROS.md](TERCEROS.md).

---

<div align="center">
<sub>Hecho para el tatami. 🥋</sub>
</div>
