@echo off
rem ---------------------------------------------------------------------------------------------
rem  Lanzador de preparar-servidor.ps1 para Windows.
rem
rem  Existe por una sola razon: Windows no ejecuta guiones .ps1 con la directiva que trae de
rem  fabrica (Restricted en cliente, RemoteSigned en servidor; y ademas un .ps1 recien
rem  descomprimido de un .zip descargado lleva la marca de Internet, que RemoteSigned tambien
rem  rechaza). Un doble clic sobre el .ps1 no hace nada util y en PowerShell sale
rem  "la ejecucion de scripts esta deshabilitada en este sistema".
rem
rem  -ExecutionPolicy Bypass afecta SOLO a esta invocacion: no cambia la directiva del equipo, que
rem  es lo que no hay que hacer en un equipo prestado. -File pasa los parametros tal cual, asi que
rem  todo lo que acepta el .ps1 vale aqui:
rem
rem      preparar-servidor.cmd -InstalarPostgresql -InstalarTarea
rem
rem  Hay que ejecutarlo COMO ADMINISTRADOR (boton derecho -> Ejecutar como administrador): instala
rem  en Program Files y registra una tarea del sistema. El propio .ps1 lo comprueba y avisa.
rem ---------------------------------------------------------------------------------------------

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0preparar-servidor.ps1" %*
set CODIGO=%ERRORLEVEL%

rem Si se ha abierto con doble clic, la ventana se cerraria sin dar tiempo a leer el resumen ni el
rem error. CMDCMDLINE lleva /c en ese caso y no cuando se ha lanzado desde una consola ya abierta.
echo %CMDCMDLINE% | find /i "/c" >nul && pause

exit /b %CODIGO%
