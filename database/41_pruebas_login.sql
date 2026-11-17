/* ============================================================================
   41 · PRUEBAS · EL LOGIN SE FRENA SOLO

   Aparte de la migración, como las demás: el editor de Supabase corre el
   archivo entero en UNA transacción, y una prueba que se deshaga a sí misma
   se llevaría por delante la función.

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/41_pruebas_login.sql

   Tiene que salir «LAS 5 PRUEBAS PASARON».

   OJO: crea un usuario de prueba desechable (zz_freno), lo usa y lo borra.
   ============================================================================ */
DO $$
DECLARE
  v_emp INT; v_rol INT; v_uid INT;
  v_r JSONB; v_fallos INT := 0;
  v_hash TEXT;
BEGIN
  SELECT id INTO v_emp FROM core.empresas WHERE estado='activa' ORDER BY id LIMIT 1;
  SELECT id INTO v_rol FROM core.roles WHERE codigo='admin' LIMIT 1;
  v_hash := core.fn_hash_pin('1234');

  INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash, activo)
  VALUES (v_emp, v_rol, 'ZZ Freno', 'zz_freno', v_hash, TRUE)
  RETURNING id INTO v_uid;

  /* 1 · con el PIN bueno entra y no deja contador */
  v_r := rest.login('zz_freno', '1234');
  IF v_r IS NULL OR v_r->>'token' IS NULL THEN
     v_fallos := v_fallos+1; RAISE NOTICE '1 · FALLO: el PIN correcto no entró';
  ELSIF (SELECT intentos_fallidos FROM core.usuarios WHERE id=v_uid) <> 0 THEN
     v_fallos := v_fallos+1; RAISE NOTICE '1 · FALLO: acertar dejó contador';
  ELSE RAISE NOTICE '1 · OK  el PIN correcto entra y el contador queda en 0';
  END IF;

  /* 2 · cuatro PIN malos NO bloquean todavía (el tope es 5) */
  FOR i IN 1..4 LOOP PERFORM rest.login('zz_freno', '0000'); END LOOP;
  IF (SELECT bloqueado_hasta FROM core.usuarios WHERE id=v_uid) IS NOT NULL THEN
     v_fallos := v_fallos+1; RAISE NOTICE '2 · FALLO: se bloqueó antes de los 5';
  ELSIF (SELECT intentos_fallidos FROM core.usuarios WHERE id=v_uid) <> 4 THEN
     v_fallos := v_fallos+1; RAISE NOTICE '2 · FALLO: el contador no es 4';
  ELSE RAISE NOTICE '2 · OK  cuatro fallos cuentan pero no bloquean';
  END IF;

  /* 3 · el quinto bloquea, y el sexto responde «bloqueado» sin mirar el PIN */
  PERFORM rest.login('zz_freno', '0000');                 -- el 5º
  IF (SELECT bloqueado_hasta FROM core.usuarios WHERE id=v_uid) IS NULL THEN
     v_fallos := v_fallos+1; RAISE NOTICE '3 · FALLO: el 5º fallo no bloqueó';
  ELSE
     v_r := rest.login('zz_freno', '1234');               -- aun con el PIN BUENO
     IF v_r IS NULL OR (v_r->>'bloqueado')::BOOLEAN IS NOT TRUE THEN
        v_fallos := v_fallos+1; RAISE NOTICE '3 · FALLO: bloqueado pero dejó pasar / no avisó';
     ELSIF v_r->>'token' IS NOT NULL THEN
        v_fallos := v_fallos+1; RAISE NOTICE '3 · FALLO: en bloqueo devolvió token';
     ELSE RAISE NOTICE '3 · OK  bloqueado: ni con el PIN bueno entra, y avisa (%min)', v_r->>'minutos';
     END IF;
  END IF;

  /* 4 · pasada la espera, el PIN bueno vuelve a entrar y limpia todo */
  UPDATE core.usuarios SET bloqueado_hasta = now() - INTERVAL '1 second' WHERE id=v_uid;
  v_r := rest.login('zz_freno', '1234');
  IF v_r IS NULL OR v_r->>'token' IS NULL THEN
     v_fallos := v_fallos+1; RAISE NOTICE '4 · FALLO: tras la espera el PIN bueno no entró';
  ELSIF (SELECT bloqueado_hasta FROM core.usuarios WHERE id=v_uid) IS NOT NULL
     OR (SELECT intentos_fallidos FROM core.usuarios WHERE id=v_uid) <> 0 THEN
     v_fallos := v_fallos+1; RAISE NOTICE '4 · FALLO: entró pero no limpió el freno';
  ELSE RAISE NOTICE '4 · OK  pasada la espera entra y borra el freno';
  END IF;

  /* 5 · un usuario que no existe no deja rastro de bloqueo (no se puede
         averiguar quién existe probando a ver quién se bloquea) */
  FOR i IN 1..6 LOOP PERFORM rest.login('zz_no_existe_jamas', '0000'); END LOOP;
  IF EXISTS (SELECT 1 FROM core.usuarios WHERE lower(usuario)='zz_no_existe_jamas') THEN
     v_fallos := v_fallos+1; RAISE NOTICE '5 · FALLO: se creó un usuario fantasma';
  ELSE RAISE NOTICE '5 · OK  un usuario inexistente no genera estado de bloqueo';
  END IF;

  DELETE FROM core.usuarios WHERE id=v_uid;

  RAISE NOTICE '=================================================';
  IF v_fallos=0 THEN RAISE NOTICE 'LAS 5 PRUEBAS PASARON';
  ELSE RAISE EXCEPTION '% PRUEBA(S) FALLARON', v_fallos; END IF;
END $$;
