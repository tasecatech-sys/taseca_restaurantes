@echo off
title TASECA - PostgREST contra la base en la nube (puerto 3001)
cd /d "%~dp0postgrest"
chcp 65001 >nul

echo.
echo   ============================================
echo      TASECA  -  API contra la nube (Supabase)
echo   ============================================
echo.

if not exist "nube.conf" (
  echo   Falta postgrest\nube.conf
  echo   Copia nube.conf.ejemplo como nube.conf y pega ahi la cadena
  echo   de conexion de Supabase ^(Connect - Session pooler^).
  echo.
  pause
  exit /b 1
)

findstr /c:"CAMBIA_ESTA_CONTRASE" nube.conf >nul
if not errorlevel 1 (
  echo   Falta la contrasena en postgrest\nube.conf
  echo.
  pause
  exit /b 1
)

rem postgrest.exe necesita libpq.dll, que viene con PostgreSQL
set "PATH=C:\Program Files\PostgreSQL\17\bin;C:\Program Files\PostgreSQL\18\bin;%PATH%"

echo   Conectando con Supabase...
echo   Cuando diga "Listening on port 3001" esta listo.
echo   Para apagarlo: cierra esta ventana.
echo.

postgrest.exe nube.conf

echo.
echo   Se detuvo. Mira el mensaje de arriba.
pause
