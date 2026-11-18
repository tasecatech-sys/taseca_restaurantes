/* ============================================================================
   44 · PRUEBAS · LA VITRINA PÚBLICA, COLUMNA A COLUMNA

   Comprueba los permisos que deja la 44, sin cambiar de rol (usa
   has_*_privilege, que es lo que de verdad decide quién lee qué), y que
   rest.arranque sigue sirviendo al cliente anónimo.

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/44_pruebas_vitrina.sql

   Tiene que salir «LAS 5 PRUEBAS PASARON». No cambia datos.
   ============================================================================ */
DO $$
DECLARE
  v_cod TEXT;
  v_emp JSONB;
  v_fallos INT := 0;
  c_publicas CONSTANT TEXT[] := ARRAY['codigo','nombre_comercial','eslogan','lema',
      'descripcion','logo_url','logo_texto','logo_acento','iniciales',
      'color_primario','color_secundario'];
  col TEXT;
  v_todas BOOLEAN := TRUE;
BEGIN
  SELECT codigo INTO v_cod FROM core.empresas WHERE estado='activa' ORDER BY id LIMIT 1;

  /* 1 · anon lee TODAS las 11 columnas del directorio */
  FOREACH col IN ARRAY c_publicas LOOP
    IF NOT has_column_privilege('taseca_anon','rest.empresas',col,'SELECT') THEN
       v_todas := FALSE; RAISE NOTICE '    anon NO puede leer %', col;
    END IF;
  END LOOP;
  IF v_todas THEN RAISE NOTICE '1 · OK  anon lee las 11 columnas de marca del directorio';
  ELSE v_fallos := v_fallos+1; RAISE NOTICE '1 · FALLO: a anon le falta alguna columna pública';
  END IF;

  /* 2 · anon NO lee las sensibles */
  IF has_column_privilege('taseca_anon','rest.empresas','razon_social','SELECT')
     OR has_column_privilege('taseca_anon','rest.empresas','email','SELECT')
     OR has_column_privilege('taseca_anon','rest.empresas','nit','SELECT')
     OR has_column_privilege('taseca_anon','rest.empresas','cuentas','SELECT') THEN
     v_fallos := v_fallos+1; RAISE NOTICE '2 · FALLO: anon todavía lee alguna columna sensible';
  ELSE RAISE NOTICE '2 · OK  anon no lee razon_social, email, nit ni cuentas';
  END IF;

  /* 3 · taseca_app ya no lee la vista directamente (fuga entre inquilinos) */
  IF has_table_privilege('taseca_app','rest.empresas','SELECT')
     OR has_column_privilege('taseca_app','rest.empresas','razon_social','SELECT') THEN
     v_fallos := v_fallos+1; RAISE NOTICE '3 · FALLO: taseca_app todavía lee rest.empresas directo';
  ELSE RAISE NOTICE '3 · OK  taseca_app ya no lee la ficha de otras empresas por consulta directa';
  END IF;

  /* 4 · el portal del cliente (arranque, sin sesión) sigue recibiendo la
         ficha, sin los dos campos sensibles */
  PERFORM set_config('request.jwt.claims', '', true);
  v_emp := rest.arranque(v_cod) -> 'empresa';
  IF v_emp ->> 'nombre_comercial' IS NOT NULL
     AND NOT (v_emp ? 'razon_social') AND NOT (v_emp ? 'email') THEN
     RAISE NOTICE '4 · OK  arranque anónimo sigue sirviendo la ficha, sin razon_social ni email';
  ELSE v_fallos := v_fallos+1; RAISE NOTICE '4 · FALLO: arranque anónimo quedó mal';
  END IF;

  /* 5 · la proyección de 11 columnas del directorio es una consulta válida */
  PERFORM codigo, nombre_comercial, eslogan, lema, descripcion, logo_url,
          logo_texto, logo_acento, iniciales, color_primario, color_secundario
     FROM rest.empresas ORDER BY nombre_comercial;
  RAISE NOTICE '5 · OK  la proyección del directorio es consulta válida';

  RAISE NOTICE '=================================================';
  IF v_fallos = 0 THEN RAISE NOTICE 'LAS 5 PRUEBAS PASARON';
  ELSE RAISE EXCEPTION '% PRUEBA(S) FALLARON', v_fallos; END IF;
END $$;
