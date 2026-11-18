/* ============================================================================
   43 · PRUEBAS · CADA FUNCIÓN CON SU search_path FIJO

   Dos cosas: que NINGUNA de las nuestras quedó con el search_path mutable, y
   -lo que de verdad importa- que fijarlo NO rompió la criptografía: que los
   atajos de pgcrypto (crypt, gen_salt), ahora con search_path '', siguen
   hasheando y verificando un PIN. Si esto pasa, el login sigue entrando.

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/43_pruebas_search_path.sql

   Tiene que salir «LAS 2 PRUEBAS PASARON». No cambia datos.
   ============================================================================ */
DO $$
DECLARE
  v_faltan INT;
  v_hash   TEXT;
  v_fallos INT := 0;
BEGIN
  /* 1 · ninguna función nuestra con search_path mutable */
  SELECT count(*) INTO v_faltan
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE (n.nspname = 'core'
          OR (n.nspname='public' AND p.proname IN ('crypt','gen_salt','digest','hmac','gen_random_bytes')))
     AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig,'{}')) c WHERE c LIKE 'search_path=%');
  IF v_faltan = 0 THEN
     RAISE NOTICE '1 · OK  ninguna función de core ni los atajos de pgcrypto quedan sin search_path';
  ELSE
     v_fallos := v_fallos+1; RAISE NOTICE '1 · FALLO: quedan % sin search_path', v_faltan;
  END IF;

  /* 2 · ida y vuelta de cripto con el search_path ya fijado: hashear un PIN y
         verificarlo. Usa core.fn_hash_pin -> public.crypt/gen_salt. */
  v_hash := core.fn_hash_pin('1234');
  IF v_hash IS NOT NULL AND public.crypt('1234', v_hash) = v_hash
                       AND public.crypt('0000', v_hash) <> v_hash THEN
     RAISE NOTICE '2 · OK  el PIN se hashea y se verifica con los atajos ya fijados';
  ELSE
     v_fallos := v_fallos+1; RAISE NOTICE '2 · FALLO: la criptografía del PIN no cuadra tras fijar search_path';
  END IF;

  RAISE NOTICE '=================================================';
  IF v_fallos = 0 THEN RAISE NOTICE 'LAS 2 PRUEBAS PASARON';
  ELSE RAISE EXCEPTION '% PRUEBA(S) FALLARON', v_fallos; END IF;
END $$;
