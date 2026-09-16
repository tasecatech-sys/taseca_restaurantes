@echo off
title TASECA - PostgREST (API de la base de datos)
cd /d "%~dp0postgrest"

echo.
echo   ================================================
echo      TASECA  -  PostgREST
echo   ================================================
echo.

if not exist "postgrest.exe" (
  echo   No se encontro postgrest\postgrest.exe
  goto fin
)

findstr /c:"password=CAMBIA_ESTA_CONTRASE" postgrest.conf >nul
if not errorlevel 1 (
  echo   Falta la contrasena en postgrest\postgrest.conf
  echo   Abre ese archivo y sigue los 3 pasos del inicio.
  goto fin
)

rem postgrest.exe necesita libpq.dll, que viene con PostgreSQL instalado en Windows
set "PGBIN="
if exist "C:\Program Files\PostgreSQL\18\bin\libpq.dll" set "PGBIN=C:\Program Files\PostgreSQL\18\bin"
if not defined PGBIN if exist "C:\Program Files\PostgreSQL\17\bin\libpq.dll" set "PGBIN=C:\Program Files\PostgreSQL\17\bin"
if not defined PGBIN if exist "C:\Program Files\PostgreSQL\16\bin\libpq.dll" set "PGBIN=C:\Program Files\PostgreSQL\16\bin"
if not defined PGBIN if exist "C:\Program Files\PostgreSQL\15\bin\libpq.dll" set "PGBIN=C:\Program Files\PostgreSQL\15\bin"
if not defined PGBIN (
  echo   No se encontro libpq.dll de PostgreSQL en C:\Program Files\PostgreSQL
  echo   Edita este archivo y escribe la ruta de la carpeta bin en PGBIN.
  goto fin
)
set "PATH=%PGBIN%;%PATH%"

echo   API:        http://localhost:3000
echo   Usando:     %PGBIN%\libpq.dll
echo.
echo   Deja esta ventana abierta. Para detener: Ctrl+C
echo   ------------------------------------------------
echo.

"%~dp0postgrest\postgrest.exe" "%~dp0postgrest\postgrest.conf"

echo.
echo   PostgREST se detuvo. Revisa el mensaje de arriba.

:fin
echo.
pause
