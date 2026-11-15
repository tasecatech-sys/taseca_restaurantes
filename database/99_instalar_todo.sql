/* ============================================================================
   TASECA · 99 · INSTALAR TODO DE UNA VEZ (sólo desde psql)
   ----------------------------------------------------------------------------
   DBeaver no entiende \i ni \connect: allí ejecuta los archivos 00 … 08 uno
   por uno (ver README.md). Desde una terminal, en esta carpeta:

     psql -h localhost -p 5435 -U postgres -f 99_instalar_todo.sql

   Se detiene en el primer error.
   ============================================================================ */

\set ON_ERROR_STOP on
\encoding UTF8

\echo '== 00 · Base de datos'
\i 00_crear_base_datos.sql

\connect taseca_db

\echo '== 01 · Estructura'
\i 01_estructura.sql
\echo '== 02 · Funciones'
\i 02_funciones.sql
\echo '== 03 · Triggers'
\i 03_triggers.sql
\echo '== 04 · Procedimientos'
\i 04_procedimientos.sql
\echo '== 05 · Vistas'
\i 05_vistas.sql
\echo '== 06 · Datos iniciales'
\i 06_datos_iniciales.sql
\echo '== 07 · Seguridad'
\i 07_seguridad.sql
\echo '== 08 · Pruebas (se deshacen con ROLLBACK)'
\i 08_pruebas.sql
\echo '== 09 · API REST para PostgREST'
\i 09_postgrest.sql
\echo '== 10 · Optimización para producción'
\i 10_optimizacion.sql
\echo '== 11 · Fase 2: carta y menú del día'
\i 11_fase2_carta_menu.sql
\echo '== 11 · Pruebas de carta y menú (se deshacen con ROLLBACK)'
\i 11_pruebas_carta_menu.sql
\echo '== 12 · Fase 2: usuarios y unidades'
\i 12_fase2_usuarios_unidades.sql
\echo '== 12 · Pruebas de usuarios y unidades (se deshacen con ROLLBACK)'
\i 12_pruebas_usuarios_unidades.sql
\echo '== 13 · Fase 2: stock, entradas y cierres'
\i 13_fase2_inventario.sql
\echo '== 13 · Pruebas de inventario (se deshacen con ROLLBACK)'
\i 13_pruebas_inventario.sql
\echo '== 14 · Fase 2: base de caja, gastos y cruce de caja'
\i 14_fase2_caja_gastos.sql
\echo '== 14 · Pruebas de caja y gastos (se deshacen con ROLLBACK)'
\i 14_pruebas_caja_gastos.sql
\echo '== 15 · Fase 2: configuración, ajustes y panel de Taseca'
\i 15_fase2_configuracion_plataforma.sql
\echo '== 15 · Pruebas de configuración y plataforma (se deshacen con ROLLBACK)'
\i 15_pruebas_configuracion_plataforma.sql
\echo '== 16 · Todos los pagos se confirman en caja'
\i 16_pagos_en_caja.sql
\echo '== 16 · Pruebas de pagos en caja (se deshacen con ROLLBACK)'
\i 16_pruebas_pagos_en_caja.sql
\echo '== 17 · Integridad multiempresa (chequeo + red de seguridad)'
\i 17_integridad_multiempresa.sql
\echo '== 17 · Pruebas de integridad (se deshacen con ROLLBACK)'
\i 17_pruebas_integridad.sql
\echo '== 23 · Un envío, un pedido (candado contra duplicados)'
\i 23_pedidos_sin_duplicados.sql
\echo '== 23 · Pruebas de duplicados (se deshacen con ROLLBACK)'
\i 23_pruebas_sin_duplicados.sql
\echo '== 24 · Abrir el panel en un solo viaje'
\i 24_arranque_en_un_viaje.sql
\echo '== 25 · Venta directa (mostrador)'
\i 25_venta_directa.sql
\echo '== 25 · Pruebas de venta directa (se deshacen con ROLLBACK)'
\i 25_pruebas_venta_directa.sql
\echo '== 26 · Al anular, qué vuelve y qué se pierde'
\i 26_anulacion_por_item.sql
\echo '== 26 · Pruebas de anulación por ítem (se deshacen con ROLLBACK)'
\i 26_pruebas_anulacion_por_item.sql
\echo '== 22 · Red de seguridad completa en el camino de un pedido'
\i 22_relaciones_empresa_completas.sql
\echo '== 21 · Auditoría: un pedido y su inventario (se deshace con ROLLBACK)'
\i 21_auditoria_pedido_inventario.sql
\echo '== 20 · Motivo de marca de cada empresa'
\i 20_motivo_marca.sql
\echo '== 20 · Pruebas del motivo de marca (se deshacen con ROLLBACK)'
\i 20_pruebas_motivo_marca.sql
-- Lo de después de la 20. Mismo orden que en el instalador de Supabase:
-- se apoyan unas en otras y la 19 se queda la última, porque enciende RLS
-- sobre todas las tablas y estas añaden columnas.
--
-- La 27 (fotos en Storage) NO está: necesita el esquema `storage`, que es
-- de Supabase. En un PostgreSQL normal no existe y el script fallaría. Las
-- fotos de la carta sólo funcionan en la instalación de Supabase.
--
-- La 33 tampoco: era el parche del fallo de la 30 para las bases ya
-- instaladas, y la 30 ya nace corregida.
\echo '== 28 · Cuánto gasta cada plato de cada insumo'
\i 28_recetas_cantidad.sql
\echo '== 29 · Nequi, Daviplata y Bre-B, cada una por su lado'
\i 29_billeteras_separadas.sql
\echo '== 30 · El recargo por método de pago'
\i 30_recargo_por_metodo.sql
\echo '== 31 · Cada empresa elige si se ve clara u oscura'
\i 31_modo_claro.sql
\echo '== 32 · Recoger el pedido en el local'
\i 32_recoger_en_sitio.sql

\echo '== 19 · Seguridad a nivel de fila en todas las tablas'
\i 19_rls.sql

\echo '== Listo: taseca_db instalada.'
