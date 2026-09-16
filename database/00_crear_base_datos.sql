/* ============================================================================
   TASECA · PLATAFORMA MULTIEMPRESA DE RESTAURANTES
   00 · CREAR LA BASE DE DATOS
   ----------------------------------------------------------------------------
   Ejecutar UNA sola vez, conectado a la base "postgres" (no a taseca_db).

   En DBeaver:
     1. Conexión a localhost:5435, base de datos "postgres".
     2. Abrir este archivo y ejecutarlo con Alt+X (Ejecutar script).
     3. Crear una conexión nueva a la base "taseca_db" y ejecutar desde ahí
        los archivos 01 … 08 en orden (o 99_instalar_todo.sql desde psql).

   CREATE DATABASE no puede ir dentro de una transacción: por eso vive en un
   archivo aparte.

   Orden alfabético en español (ñ, tildes) con ICU. Requiere PostgreSQL 15
   o superior. En una versión anterior, borra las dos líneas de ICU.
   ============================================================================ */

CREATE DATABASE taseca_db
    WITH ENCODING = 'UTF8'
         TEMPLATE = template0
         LOCALE_PROVIDER = icu
         ICU_LOCALE = 'es-CO'
         LOCALE = 'C'
         CONNECTION LIMIT = -1;

COMMENT ON DATABASE taseca_db IS
    'Taseca · plataforma multiempresa de restaurantes (entorno de pruebas local).';
