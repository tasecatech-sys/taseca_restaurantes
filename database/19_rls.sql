/* ============================================================================
   TASECA · 19 · SEGURIDAD A NIVEL DE FILA (RLS) EN TODAS LAS TABLAS
   ----------------------------------------------------------------------------
   Enciende RLS en todas las tablas de `core`, sin políticas. Efecto:

     · Nadie puede leer ni escribir una tabla DIRECTAMENTE, aunque algún día
       alguien le dé permisos por error o exponga el esquema en la API.
     · El DUEÑO de la tabla queda exento (así funciona PostgreSQL), y el dueño
       es quien ejecuta las vistas de `api` y los procedimientos
       SECURITY DEFINER. O sea: la aplicación sigue funcionando igual.

   Es el segundo candado. El primero ya estaba: `07_seguridad.sql` no le da a
   `taseca_app` ni a `taseca_anon` ningún permiso sobre las tablas de `core`,
   y a la API sólo se publica el esquema `rest`.

   En Supabase esto además calla el aviso "esta consulta crea tablas sin
   habilitar la seguridad a nivel de fila".

   Se puede ejecutar más de una vez. Para revisarlo:

       SELECT * FROM api.fn_estado_rls() WHERE NOT rls;
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. ENCENDER RLS
   ============================================================================ */

DO $$
DECLARE
    t         RECORD;
    v_nuevas  INTEGER := 0;
    v_ya      INTEGER := 0;
BEGIN
    FOR t IN
        SELECT c.relname, c.relrowsecurity
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'core' AND c.relkind = 'r'
         ORDER BY c.relname
    LOOP
        IF t.relrowsecurity THEN
            v_ya := v_ya + 1;
        ELSE
            EXECUTE format('ALTER TABLE core.%I ENABLE ROW LEVEL SECURITY', t.relname);
            v_nuevas := v_nuevas + 1;
        END IF;
    END LOOP;

    RAISE NOTICE 'RLS encendida en % tabla(s); ya lo estaba en %.', v_nuevas, v_ya;
END;
$$;


/* ============================================================================
   2. CÓMO REVISARLO DESPUÉS

   Devuelve una fila por tabla de `core` diciendo si tiene RLS y si alguien
   más que el dueño tiene permisos sobre ella. Lo segundo no debería pasar:
   si aparece un rol, algo le dio acceso directo a una tabla.
   ============================================================================ */

CREATE OR REPLACE FUNCTION api.fn_estado_rls()
RETURNS TABLE (tabla TEXT, rls BOOLEAN, politicas INTEGER, con_permisos TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT c.relname::TEXT,
           c.relrowsecurity,
           (SELECT count(*)::INTEGER FROM pg_policy p WHERE p.polrelid = c.oid),
           COALESCE((SELECT string_agg(DISTINCT g.grantee, ', ')
                       FROM information_schema.role_table_grants g
                      WHERE g.table_schema = 'core'
                        AND g.table_name = c.relname
                        AND g.grantee NOT IN ('PUBLIC', c.relowner::REGROLE::TEXT)), '—')
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'core' AND c.relkind = 'r'
     ORDER BY c.relname;
$$;

COMMENT ON FUNCTION api.fn_estado_rls() IS
    'Una fila por tabla de core: si tiene RLS, cuántas políticas y qué roles (aparte del dueño) tienen permisos directos.';

REVOKE ALL ON FUNCTION api.fn_estado_rls() FROM PUBLIC;


/* ============================================================================
   3. REVISIÓN
   ============================================================================ */

DO $$
DECLARE
    v_sin_rls   INTEGER;
    v_con_perm  INTEGER;
BEGIN
    SELECT count(*) FILTER (WHERE NOT rls),
           count(*) FILTER (WHERE con_permisos <> '—')
      INTO v_sin_rls, v_con_perm
      FROM api.fn_estado_rls();

    IF v_sin_rls = 0 THEN
        RAISE NOTICE '✔ Todas las tablas de core tienen RLS';
    ELSE
        RAISE NOTICE '✗ Quedan % tabla(s) sin RLS', v_sin_rls;
    END IF;

    IF v_con_perm = 0 THEN
        RAISE NOTICE '✔ Ningún rol tiene permisos directos sobre las tablas de core';
    ELSE
        RAISE NOTICE '? % tabla(s) con permisos directos: SELECT * FROM api.fn_estado_rls() WHERE con_permisos <> ''—''', v_con_perm;
    END IF;
END;
$$;
