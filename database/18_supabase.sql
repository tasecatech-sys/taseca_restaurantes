/* ============================================================================
   TASECA · 18 · ADAPTACIÓN A SUPABASE (base en la nube)
   ----------------------------------------------------------------------------
   Sirve para que la MISMA base funcione dentro de un proyecto de Supabase,
   cuya API (Data API) es el mismo PostgREST que usamos en local, pero con
   su propia portería y sus propios roles.

   Qué hay que hacer, en orden:

     1. Ejecutar ESTE archivo (18) PRIMERO, antes que ningún otro. Deja en
        `public` los atajos de cifrado que Supabase guarda en otro sitio; sin
        ellos, el script 02 falla con «function public.crypt does not exist».
        En esta primera vuelta avisará que faltan los roles: es normal.
     2. Ejecutar los scripts de siempre: 01 … 17. El 00 NO aplica: Supabase
        ya trae la base creada. Cuando pregunte por RLS, responde
        «Ejecuta y habilita RLS».
     3. Ejecutar ESTE archivo otra vez y leer la revisión del final.
     4. En el panel de Supabase, Settings → API → Exposed schemas: agregar
        «rest» (y dejarlo de primero si se quiere ahorrar una cabecera).
     5. En la aplicación, llenar js/backend.js con la dirección del proyecto
        y su clave publicable.

   Se ejecuta dos veces a propósito: la primera prepara el terreno y la
   segunda conecta los roles, que sólo existen después del 07 y el 09.

   NO se pega aquí ninguna contraseña de base de datos. Lo único secreto que
   se escribe es el JWT secret del proyecto, en el paso 3 de abajo, y se hace
   desde el editor SQL de Supabase, que ya es un sitio privado.

   Se puede ejecutar más de una vez.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. FUNCIONES DE CIFRADO (pgcrypto)

   En una instalación normal pgcrypto vive en `public`. Supabase lo instala en
   `extensions`, así que `public.crypt(...)` no existiría y el login fallaría.
   En vez de mover la extensión —de la que dependen cosas internas de
   Supabase— se dejan en `public` atajos que llaman a donde esté: los tres
   del PIN (crypt, gen_salt, gen_random_bytes) y los dos de la firma de los
   tokens (hmac, digest).
   ============================================================================ */

DO $$
DECLARE
    v_esquema TEXT;
BEGIN
    SELECT n.nspname INTO v_esquema
      FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = 'pgcrypto';

    IF v_esquema IS NULL THEN
        -- Aún no está instalada: se instala en public y no hacen falta atajos
        CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
        RAISE NOTICE 'pgcrypto instalada en public.';
        RETURN;
    END IF;

    IF v_esquema = 'public' THEN
        RAISE NOTICE 'pgcrypto ya está en public: no hacen falta atajos.';
        RETURN;
    END IF;

    EXECUTE format($f$
        CREATE OR REPLACE FUNCTION public.crypt(TEXT, TEXT) RETURNS TEXT
        LANGUAGE sql IMMUTABLE STRICT AS 'SELECT %I.crypt($1, $2)';
    $f$, v_esquema);

    EXECUTE format($f$
        CREATE OR REPLACE FUNCTION public.gen_salt(TEXT, INTEGER) RETURNS TEXT
        LANGUAGE sql VOLATILE STRICT AS 'SELECT %I.gen_salt($1, $2)';
    $f$, v_esquema);

    EXECUTE format($f$
        CREATE OR REPLACE FUNCTION public.gen_random_bytes(INTEGER) RETURNS BYTEA
        LANGUAGE sql VOLATILE STRICT AS 'SELECT %I.gen_random_bytes($1)';
    $f$, v_esquema);

    -- Firma de los tokens (core.fn_jwt_firmar)
    EXECUTE format($f$
        CREATE OR REPLACE FUNCTION public.hmac(BYTEA, BYTEA, TEXT) RETURNS BYTEA
        LANGUAGE sql IMMUTABLE STRICT AS 'SELECT %I.hmac($1, $2, $3)';
    $f$, v_esquema);

    EXECUTE format($f$
        CREATE OR REPLACE FUNCTION public.digest(BYTEA, TEXT) RETURNS BYTEA
        LANGUAGE sql IMMUTABLE STRICT AS 'SELECT %I.digest($1, $2)';
    $f$, v_esquema);

    RAISE NOTICE 'Atajos de pgcrypto creados en public (la extensión vive en %).', v_esquema;
END;
$$;


/* ============================================================================
   2. ROLES

   Supabase conecta con el rol `authenticator` y, según el token, cambia al
   rol que diga el campo `role`:

     · sin sesión (portal público) → anon        → tiene que poder lo de taseca_anon
     · con sesión (panel)          → taseca_app  → authenticator debe poder asumirlo

   Los roles taseca_app y taseca_anon los crean 07_seguridad.sql y
   09_postgrest.sql. Aquí sólo se conectan con los de Supabase.
   ============================================================================ */

DO $$
DECLARE
    v_rol TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
        RAISE NOTICE 'No existe el rol authenticator: esto no parece un proyecto de Supabase. Se salta el paso 2.';
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taseca_app') THEN
        RAISE NOTICE 'Todavía no existen los roles de Taseca (los crean 07 y 09).';
        RAISE NOTICE 'Sigue con los scripts 01 … 17 y vuelve a ejecutar este archivo al final.';
        RETURN;
    END IF;

    -- El panel entra como taseca_app
    EXECUTE 'GRANT taseca_app TO authenticator';

    -- El portal público entra como anon y necesita lo que puede taseca_anon
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        EXECUTE 'GRANT taseca_anon TO anon';
    END IF;

    -- Por si alguna herramienta entra directamente como taseca_anon
    EXECUTE 'GRANT taseca_anon TO authenticator';

    /* Quien instala (el editor SQL entra como `postgres`, que en Supabase NO
       es superusuario) también tiene que poder asumir los roles: es lo que
       hacen las pruebas con SET LOCAL ROLE, y hace falta para mantenimiento. */
    FOREACH v_rol IN ARRAY ARRAY['taseca_app', 'taseca_anon', 'taseca_lectura'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_rol) THEN
            EXECUTE format('GRANT %I TO %I', v_rol, current_user);
        END IF;
    END LOOP;

    RAISE NOTICE 'Roles conectados: authenticator puede asumir taseca_app y taseca_anon; anon hereda taseca_anon.';
    RAISE NOTICE 'El usuario % también puede asumirlos (lo necesitan las pruebas).', current_user;
END;
$$;


/* ============================================================================
   3. TOKENS (JWT)

   La base firma sus propios tokens al entrar (rest.login). Para que la
   portería de Supabase los acepte, hay que firmarlos con la MISMA clave del
   proyecto: el «JWT secret» que aparece en
       Settings → API → JWT Settings (clave heredada, HS256).

   Pega esa clave abajo, ejecuta sólo esta sentencia y borra la clave de la
   pantalla. Queda guardada en core.jwt_config, que nadie puede leer desde la
   API: ni taseca_app ni anon tienen permiso sobre esa tabla.

   Mientras no se haga, la aplicación podrá leer el portal público pero nadie
   podrá iniciar sesión.
   ============================================================================ */

-- UPDATE core.jwt_config
--    SET secreto = 'PEGA-AQUI-EL-JWT-SECRET-DEL-PROYECTO'
--  WHERE id = (SELECT max(id) FROM core.jwt_config);


/* ============================================================================
   4. TAREAS PROGRAMADAS (opcional, recomendado)

   Supabase incluye pg_cron. Con esto la auditoría no crece sin control y los
   reportes se refrescan solos. Ejecuta este bloque una vez.
   ============================================================================ */

-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('taseca-purgar-auditoria', '30 4 * * *', $$CALL api.sp_purgar_auditoria(365)$$);
-- SELECT cron.schedule('taseca-refrescar-reportes', '0 5 * * *', $$CALL api.sp_refrescar_reportes()$$);


/* ============================================================================
   5. REVISIÓN FINAL
   ============================================================================ */

DO $$
DECLARE
    v_secreto TEXT;
    v_falta   BOOLEAN := FALSE;
BEGIN
    RAISE NOTICE '--- Revisión de la instalación en Supabase ---';

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taseca_app') THEN
        RAISE NOTICE '· Primera vuelta: faltan los scripts 01 … 17. Vuelve a ejecutar este archivo al terminarlos.';
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator')
       AND pg_has_role('authenticator', 'taseca_app', 'MEMBER') THEN
        RAISE NOTICE '✔ authenticator puede asumir taseca_app';
    ELSE
        RAISE NOTICE '✗ authenticator NO puede asumir taseca_app (revisa el paso 2)';
        v_falta := TRUE;
    END IF;

    SELECT secreto INTO v_secreto FROM core.jwt_config ORDER BY id DESC LIMIT 1;
    -- (si el 09 no se ha ejecutado, core.jwt_config no existe y el bloque
    --  entero se salta con el aviso de "primera vuelta" de arriba)
    IF v_secreto IS NULL OR length(v_secreto) < 32 THEN
        RAISE NOTICE '✗ Falta el JWT secret del proyecto (paso 3): nadie podrá iniciar sesión';
        v_falta := TRUE;
    ELSIF v_secreto ~ '^[0-9a-f]{64}$' THEN
        RAISE NOTICE '? El secreto guardado parece el generado por la propia base, no el de Supabase.';
        RAISE NOTICE '  Si el login falla con "JWSError", ese es el motivo (paso 3).';
    ELSE
        RAISE NOTICE '✔ Hay un JWT secret guardado (% caracteres)', length(v_secreto);
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'rest' AND p.proname = 'login') THEN
        RAISE NOTICE '✔ El esquema rest está instalado';
    ELSE
        RAISE NOTICE '✗ Falta el esquema rest: ejecuta 09_postgrest.sql';
        v_falta := TRUE;
    END IF;

    RAISE NOTICE '--- Falta a mano: Settings → API → Exposed schemas → agregar «rest» ---';
    IF v_falta THEN
        RAISE NOTICE 'Quedan cosas por hacer: mira las líneas con ✗.';
    ELSE
        RAISE NOTICE 'Todo listo del lado de la base.';
    END IF;
END;
$$;
