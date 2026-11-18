/* ============================================================================
   43 · CADA FUNCIÓN CON SU search_path FIJO

   QUÉ ES
   ------
   El linter de Supabase marca «function_search_path_mutable» en las funciones
   que no fijan su propio search_path. Son las de tipo INVOKER -corren con el
   search_path de quien las llama-: 36 de `core` (los triggers y los ayudantes)
   y 5 atajos de pgcrypto en `public`.

   El riesgo real aquí es bajo: todas son INVOKER (no escalan privilegios como
   lo haría una SECURITY DEFINER) y todas CALIFICAN lo suyo -escriben
   `core.tabla`, no `tabla`-. Pero fijarles el search_path es defensa en
   profundidad y, de paso, deja el linter en limpio.

   QUÉ SE HACE
   -----------
     · Las de `core`      → SET search_path = core, public
       Es lo que ya usan las funciones endurecidas del proyecto (rest.login,
       rest.arranque, core.fn_jwt_usuario…). Se comprobó que ninguna de estas
       36 referencia sin calificar nada de `extensions`, `api` ni `rest`: sólo
       objetos de `core` (calificados) y de `pg_catalog` (siempre visible). La
       criptografía la resuelven por el atajo en `public`.

     · Los atajos de pgcrypto en `public` (crypt, gen_salt, digest, hmac,
       gen_random_bytes) → SET search_path = ''
       Son envoltorios SQL que ya llaman a `extensions.crypt(...)` con el
       esquema puesto, así que el search_path no les cambia nada: el vacío es
       lo más seguro y lo que recomienda Supabase.

   POR QUÉ UN BUCLE Y NO 41 ALTER A MANO
   -------------------------------------
   Para no tipear 41 firmas (y equivocarse en una). Recorre las funciones que
   AÚN no tienen search_path y se lo pone según el esquema. Por eso es
   idempotente: la segunda vez no hay ninguna que tocar. Y una función que ya
   fije el suyo -las SECURITY DEFINER lo hacen siempre- no la toca.

   NO cambia ninguna lógica. Se puede ejecutar más de una vez.
   Requiere: las funciones ya creadas (02, 03, 04 y las migraciones).
   ============================================================================ */

DO $$
DECLARE
    r       RECORD;
    v_core  INT := 0;
    v_pub   INT := 0;
BEGIN
    /* core: triggers y ayudantes → core, public */
    FOR r IN
        SELECT p.oid,
               quote_ident(n.nspname) AS esq,
               quote_ident(p.proname) AS fn,
               pg_get_function_identity_arguments(p.oid) AS args
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'core'
           AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig,'{}')) c WHERE c LIKE 'search_path=%')
    LOOP
        EXECUTE format('ALTER FUNCTION %s.%s(%s) SET search_path = core, public', r.esq, r.fn, r.args);
        v_core := v_core + 1;
    END LOOP;

    /* public: sólo los 5 atajos de pgcrypto → '' (ya califican extensions.*) */
    FOR r IN
        SELECT p.oid,
               quote_ident(n.nspname) AS esq,
               quote_ident(p.proname) AS fn,
               pg_get_function_identity_arguments(p.oid) AS args
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname IN ('crypt','gen_salt','digest','hmac','gen_random_bytes')
           AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig,'{}')) c WHERE c LIKE 'search_path=%')
    LOOP
        EXECUTE format($q$ALTER FUNCTION %s.%s(%s) SET search_path = ''$q$, r.esq, r.fn, r.args);
        v_pub := v_pub + 1;
    END LOOP;

    RAISE NOTICE 'search_path fijado · core: % · atajos public: %', v_core, v_pub;
END $$;


/* ----------------------------------------------------------------------------
   REVISIÓN · no debe quedar ninguna de las nuestras sin search_path
   ---------------------------------------------------------------------------- */
DO $$
DECLARE v_faltan INT;
BEGIN
    SELECT count(*) INTO v_faltan
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE (n.nspname = 'core'
            OR (n.nspname='public' AND p.proname IN ('crypt','gen_salt','digest','hmac','gen_random_bytes')))
       AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig,'{}')) c WHERE c LIKE 'search_path=%');
    IF v_faltan > 0 THEN
        RAISE EXCEPTION 'Todavía quedan % función(es) sin search_path.', v_faltan;
    END IF;
    RAISE NOTICE 'OK · ninguna función de core ni los atajos de pgcrypto quedan con search_path mutable.';
END $$;
