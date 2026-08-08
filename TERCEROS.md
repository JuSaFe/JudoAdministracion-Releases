# Componentes de terceros

Bibliotecas que JudoAdministración incorpora y bajo qué licencia. Todas son permisivas y compatibles
con la distribución de este proyecto en los términos de su [licencia](LICENSE) — ninguna de ellas
obliga a publicar el programa como código abierto ni a permitir obras derivadas.

La única que **impone condiciones de uso** es QuestPDF; está detallada al final.

---

## 1. Paquetes NuGet

### Aplicación de escritorio (`JudoAdministracion.csproj`)

| Paquete | Versión | Licencia | Notas |
|---|---|---|---|
| Avalonia, Avalonia.Desktop, Avalonia.Themes.Fluent, Avalonia.Diagnostics | 11.3.6 | MIT | `Avalonia.Diagnostics` se excluye en Release |
| Avalonia.Fonts.Inter | 11.3.6 | MIT (paquete) · **SIL OFL 1.1** (tipografía Inter) | Redistribución libre; hay que conservar el aviso de copyright de la fuente |
| CommunityToolkit.Mvvm | 8.4.0 | MIT | |
| Microsoft.Extensions.DependencyInjection | 10.0.3 | MIT | |
| PDFtoImage | 5.3.0 | MIT | Empaqueta binarios nativos de **PDFium** (BSD‑3‑Clause, Google/Chromium). Redistribución libre conservando el aviso |

### Servicio / API (`JudoAdministracion.Api`)

| Paquete | Versión | Licencia |
|---|---|---|
| Microsoft.AspNetCore.Authentication.JwtBearer | 9.0.11 | MIT |

### Datos y generación de PDF (`JudoAdministracion.Datos`)

| Paquete | Versión | Licencia | Notas |
|---|---|---|---|
| BCrypt.Net-Next | 4.1.0 | MIT | |
| Dapper | 2.1.66 | Apache‑2.0 | Exige conservar el `NOTICE` y declarar los cambios si se modifica |
| Npgsql | 10.0.1 | PostgreSQL License | Equivalente a BSD de dos cláusulas |
| PDFsharp | 6.2.1 | MIT | |
| **QuestPDF** | 2026.7.1 | **Dual: Community MIT / Professional / Enterprise** | Ver §3 |

### Compartido (`JudoAdministracion.Shared`)

| Paquete | Versión | Licencia |
|---|---|---|
| CommunityToolkit.Mvvm | 8.4.0 | MIT |

## 2. Plataforma y herramientas

| Componente | Licencia | Cómo se usa |
|---|---|---|
| .NET 9 / ASP.NET Core | MIT | Runtime incluido en los paquetes autocontenidos |
| PostgreSQL 18 (mínimo 13) | PostgreSQL License | Se instala aparte en el servidor; **no** se redistribuye |
| Inno Setup 6 | Modificada de Inno Setup (permite uso comercial gratuito) | Solo genera el `.exe`; no se distribuye con la aplicación |
| appimagetool / `hdiutil` | LGPL / Apple | Solo empaquetado |

Ninguna herramienta de empaquetado forma parte del producto entregado.

## 3. QuestPDF — la única con condiciones de uso

Desde 2024 QuestPDF dejó de ser MIT puro y usa un **modelo de licencia dual**. La aplicación declara
la licencia Community en el arranque ([`App.axaml.cs`](App.axaml.cs)):

```csharp
QuestPDF.Settings.License = QuestPDF.Infrastructure.LicenseType.Community;
```

### Quién puede usar la licencia Community (gratuita)

- Particulares, incluso en proyectos comerciales, con ingresos brutos anuales **inferiores a 1.000.000 USD**.
- Empresas y organizaciones con **ingresos brutos anuales inferiores a 1.000.000 USD** (consolidados, último ejercicio cerrado).
- Entidades **benéficas o de interés público** (humanitarias, educativas, científicas, medioambientales).
- Instituciones **académicas** públicas o sin ánimo de lucro.
- Uso para aprendizaje, formación o evaluación técnica, sin límite de ingresos.
- Proyectos de código abierto bajo licencia aprobada por la OSI. **Esta vía NO aplica a este
  proyecto**: su licencia es de código visible con prohibición de obras derivadas, no una licencia
  OSI. La elegibilidad descansa por tanto en los criterios anteriores.

### Quién NO puede, y este es el punto a vigilar

> **Los organismos del sector público y las administraciones públicas quedan excluidos de la
> licencia Community con independencia de sus ingresos.** También las empresas cotizadas.

**Qué significa para este proyecto:** el desarrollo lo realiza un particular con ingresos muy por
debajo del umbral, así que la elegibilidad del autor está clara. Lo que conviene revisar es el lado
del despliegue: si una federación, un ayuntamiento, un consejo de deportes o cualquier entidad con
carácter público instala la aplicación para su actividad, hay que comprobar si encaja en la excepción
de entidad de interés público o si necesita licencia Professional. Las federaciones deportivas
españolas son entidades privadas que ejercen funciones públicas delegadas, así que la zona es gris y
merece una consulta a QuestPDF antes de un despliegue institucional.

### Alternativas si algún día no encaja

1. Adquirir la licencia **Professional** (de pago anual, según tramo de ingresos).
2. Sustituir QuestPDF por **PDFsharp** —MIT, sin condiciones y ya presente en el proyecto— en los
   informes de [`JudoAdministracion.Datos/Services/Pdf/`](JudoAdministracion.Datos/Services/Pdf/).
   Supone reescribir la maquetación de esos servicios, pero elimina la dependencia por completo.

Términos oficiales: <https://www.questpdf.com/license/>

## 4. Recursos gráficos

| Recurso | Situación |
|---|---|
| `Assets/Icons/judo.*` | Iconos propios del proyecto, cubiertos por la licencia MIT |
| `Assets/PdfTemplates/*.pdf` | Plantillas de cuadros de combate del proyecto |
| `Assets/Images/Logo_Federacion_*.png`, `Copas_FVJ.png` | **Marcas de terceros.** Propiedad de sus respectivas federaciones; la licencia MIT no otorga derechos sobre ellas |
| `Assets/Images/Mat*.png` | Ilustraciones de tatami del proyecto |

Quien reutilice este código en otro contexto debe **retirar o sustituir los logotipos federativos**.
