/* ============================================================================
   42 · PRUEBAS · EL ESCAPARATE NO FILTRA DE MÁS

   Aparte de la migración, como las demás. El editor de Supabase corre el
   archivo entero en UNA transacción; una prueba que se deshaga a sí misma se
   llevaría por delante lo que mira. Aquí no hace falta deshacer nada: sólo
   lee y simula el token con la GUC `request.jwt.claims`, que es de dónde
   core.fn_jwt_usuario() saca el usuario.

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/42_pruebas_escaparate.sql

   Tiene que salir «LAS 3 PRUEBAS PASARON».
   ============================================================================ */
DO $$
DECLARE
  v_cod  TEXT;
  v_uid  INT; v_emp INT; v_rol TEXT;
  v_emp_json JSONB;
  v_fallos INT := 0;
BEGIN
  SELECT codigo INTO v_cod FROM core.empresas WHERE estado='activa' ORDER BY id LIMIT 1;
  SELECT u.id, u.empresa_id, r.codigo INTO v_uid, v_emp, v_rol
    FROM core.usuarios u JOIN core.roles r ON r.id = u.rol_id
   WHERE r.codigo = 'admin' AND u.activo ORDER BY u.id LIMIT 1;

  /* 1 · anon ya no puede leer la vista directamente (el GET /empresas) */
  IF has_table_privilege('taseca_anon', 'rest.empresas', 'SELECT') THEN
     v_fallos := v_fallos+1; RAISE NOTICE '1 · FALLO: taseca_anon todavía puede SELECT sobre rest.empresas';
  ELSE RAISE NOTICE '1 · OK  anon no puede leer rest.empresas directamente';
  END IF;

  /* 2 · sin sesión (sin token): la ficha va SIN razon_social ni email, pero
         CON nit y modulos, que la vitrina sí necesita */
  PERFORM set_config('request.jwt.claims', '', true);
  v_emp_json := rest.arranque(v_cod) -> 'empresa';
  IF (v_emp_json ? 'razon_social') OR (v_emp_json ? 'email') THEN
     v_fallos := v_fallos+1; RAISE NOTICE '2 · FALLO: sin sesión todavía entrega razon_social o email';
  ELSIF NOT (v_emp_json ? 'nit') OR NOT (v_emp_json ? 'modulos') THEN
     v_fallos := v_fallos+1; RAISE NOTICE '2 · FALLO: sin sesión perdió nit o modulos (la vitrina los usa)';
  ELSE RAISE NOTICE '2 · OK  sin sesión: sin nombre legal ni correo; con nit y modulos';
  END IF;

  /* 3 · con sesión (el panel): la ficha vuelve completa, porque la
         configuración del panel edita razón social y correo */
  PERFORM set_config('request.jwt.claims',
      jsonb_build_object('usuario_id', v_uid, 'empresa_id', v_emp, 'rol', v_rol)::TEXT, true);
  v_emp_json := rest.arranque(v_cod) -> 'empresa';
  IF NOT (v_emp_json ? 'razon_social') OR NOT (v_emp_json ? 'email') THEN
     v_fallos := v_fallos+1; RAISE NOTICE '3 · FALLO: con sesión el panel ya no recibe razon_social/email';
  ELSE RAISE NOTICE '3 · OK  con sesión la ficha va completa';
  END IF;
  PERFORM set_config('request.jwt.claims', '', true);

  RAISE NOTICE '=================================================';
  IF v_fallos = 0 THEN RAISE NOTICE 'LAS 3 PRUEBAS PASARON';
  ELSE RAISE EXCEPTION '% PRUEBA(S) FALLARON', v_fallos; END IF;
END $$;
