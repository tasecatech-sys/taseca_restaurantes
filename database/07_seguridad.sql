/* ============================================================================
   TASECA · 07 · SEGURIDAD (roles y permisos de base de datos)
   ----------------------------------------------------------------------------
   Principio: la aplicación NUNCA toca las tablas.

     taseca_app      rol de la aplicación: lee las vistas de api y ejecuta
                     sus procedimientos y funciones. Sin acceso a core.
     taseca_lectura  reportes / analistas: sólo SELECT sobre las vistas.

   Ambos son NOLOGIN (grupos). El usuario real con contraseña se crea aparte
   y se mete en el grupo (ver el final del archivo). Las contraseñas no se
   dejan escritas en los scripts.

   Los procedimientos y las funciones de core que usan las vistas son
   SECURITY DEFINER: corren con los privilegios de su dueño, por eso el rol
   de la aplicación no necesita permisos sobre las tablas.
   ============================================================================ */

SET search_path = core, public;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taseca_app') THEN
        CREATE ROLE taseca_app NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taseca_lectura') THEN
        CREATE ROLE taseca_lectura NOLOGIN;
    END IF;
END;
$$;

COMMENT ON ROLE taseca_app     IS 'Aplicación Taseca: vistas y procedimientos del esquema api. Sin acceso a core.';
COMMENT ON ROLE taseca_lectura IS 'Reportes: sólo lectura de las vistas del esquema api.';


/* ---------------------------------------------------------------------------
   1. Nadie accede a core por defecto
   --------------------------------------------------------------------------- */
REVOKE ALL ON SCHEMA core FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA core FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA core FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA core FROM PUBLIC;
REVOKE ALL ON SCHEMA api FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS  IN SCHEMA api FROM PUBLIC;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA api FROM PUBLIC;


/* ---------------------------------------------------------------------------
   2. Las funciones de core que usan las vistas corren como su dueño
   Una vista consulta las tablas con los permisos de su dueño, pero una
   función llamada dentro de la vista corre con los del que consulta. Sin
   esto, taseca_app no podría leer ni una vista que calcule la jornada.
   Las funciones de trigger se excluyen: corren dentro de procedimientos que
   ya son SECURITY DEFINER.
   --------------------------------------------------------------------------- */
DO $$
DECLARE
    f RECORD;
BEGIN
    FOR f IN
        SELECT p.oid::regprocedure AS firma
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'core'
           AND p.prokind = 'f'
           AND p.prorettype <> 'trigger'::regtype
    LOOP
        EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = core, public', f.firma);
    END LOOP;
END;
$$;


/* ---------------------------------------------------------------------------
   3. Rol de la aplicación
   --------------------------------------------------------------------------- */
GRANT USAGE   ON SCHEMA api TO taseca_app, taseca_lectura;
GRANT SELECT  ON ALL TABLES IN SCHEMA api TO taseca_app, taseca_lectura;   -- vistas y vistas materializadas
GRANT EXECUTE ON ALL FUNCTIONS  IN SCHEMA api TO taseca_app;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA api TO taseca_app;

/* Las vistas llaman funciones de cálculo de core, y PostgreSQL revisa el
   permiso de EJECUTAR contra quien consulta. Se conceden sólo esas, de
   solo lectura. USAGE sobre core permite nombrarlas; no da acceso a
   ninguna tabla (siguen revocadas). */
GRANT USAGE ON SCHEMA core TO taseca_app, taseca_lectura;
GRANT EXECUTE ON FUNCTION
    core.fn_fecha_operativa(INTEGER, TIMESTAMPTZ),
    core.fn_empresa_tiene_modulo(INTEGER, TEXT),
    core.fn_vendidos_plato(BIGINT),
    core.fn_normalizar_codigo_pedido(INTEGER, TEXT),
    core.fn_empresa_de_unidad(INTEGER)
TO taseca_app, taseca_lectura;

-- Lo que se cree después en api hereda los mismos permisos
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT SELECT  ON TABLES     TO taseca_app, taseca_lectura;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT EXECUTE ON FUNCTIONS  TO taseca_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT EXECUTE ON ROUTINES   TO taseca_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA api REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA core REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Refrescar reportes es tarea programada, no de la aplicación ni de los analistas
REVOKE EXECUTE ON PROCEDURE api.sp_refrescar_reportes() FROM taseca_app;


/* ---------------------------------------------------------------------------
   4. Usuario con contraseña para conectar la aplicación
   Descomenta, pon una contraseña fuerte y ejecútalo a mano. No lo guardes
   con la contraseña escrita en el repositorio.
   --------------------------------------------------------------------------- */
-- CREATE ROLE app_taseca LOGIN PASSWORD 'CAMBIA_ESTA_CONTRASEÑA' IN ROLE taseca_app;
-- CREATE ROLE reportes_taseca LOGIN PASSWORD 'CAMBIA_ESTA_CONTRASEÑA' IN ROLE taseca_lectura;
