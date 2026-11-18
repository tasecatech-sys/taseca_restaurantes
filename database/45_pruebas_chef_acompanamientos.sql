/* ============================================================================
   45 · PRUEBAS · EL MENÚ DEL CHEF CON ACOMPAÑAMIENTOS

   Se deshace sola al final (RAISE) para no dejar menús ni pedidos de prueba.
   Debe terminar con «LAS 4 PRUEBAS PASARON» justo antes del rollback.

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/45_pruebas_chef_acompanamientos.sql
   ============================================================================ */
DO $$
DECLARE
  v_emp INT; v_uni INT; v_usr INT;
  v_menu BIGINT; v_plato BIGINT; v_catS BIGINT; v_catB BIGINT;
  v_s1 BIGINT; v_s2 BIGINT; v_b1 BIGINT; v_b2 BIGINT;
  v_menu2 BIGINT; v_plato2 BIGINT;
  v_menuA BIGINT; v_catA BIGINT; v_a1 BIGINT;
  v_ped BIGINT; v_cod VARCHAR; v_n INT; v_fallos INT := 0;
  v_err TEXT;
BEGIN
  SELECT u.id, u.empresa_id INTO v_uni, v_emp
    FROM core.unidades u JOIN core.empresas e ON e.id=u.empresa_id
   WHERE e.estado='activa' AND u.estado='activa' ORDER BY u.id LIMIT 1;
  SELECT us.id INTO v_usr FROM core.usuarios us JOIN core.roles r ON r.id=us.rol_id
   WHERE us.empresa_id=v_emp AND r.codigo='admin' AND us.activo ORDER BY us.id LIMIT 1;
  -- método efectivo activo para esa empresa
  UPDATE core.empresa_metodos_pago SET activo=TRUE
   WHERE empresa_id=v_emp AND metodo_pago_id=core.fn_id_catalogo('metodos_pago','efectivo');

  /* ---- Menú del chef CON acompañamientos (fecha lejana para no chocar) ---- */
  CALL api.sp_guardar_menu_dia(v_uni, DATE '2099-01-05', 'chef', v_usr, 'Chef A', NULL, NULL, TRUE, 'Chef A', NULL, v_menu);
  UPDATE core.menus_dia SET pide_acompanamientos=TRUE WHERE id=v_menu;
  CALL api.sp_guardar_plato_dia(p_menu_dia_id=>v_menu, p_nombre=>'Plato ZZ', p_precio=>20000, p_usuario_id=>v_usr, p_plato_id=>v_plato);
  CALL api.sp_guardar_menu_categoria(p_menu_dia_id=>v_menu, p_nombre=>'Sopa',   p_usuario_id=>v_usr, p_max_seleccion=>1, p_obligatoria=>TRUE, p_categoria_id=>v_catS);
  CALL api.sp_guardar_menu_categoria(p_menu_dia_id=>v_menu, p_nombre=>'Bebida', p_usuario_id=>v_usr, p_max_seleccion=>1, p_obligatoria=>TRUE, p_categoria_id=>v_catB);
  CALL api.sp_guardar_menu_opcion(p_menu_categoria_id=>v_catS, p_nombre=>'Sancocho', p_usuario_id=>v_usr, p_opcion_id=>v_s1);
  CALL api.sp_guardar_menu_opcion(p_menu_categoria_id=>v_catS, p_nombre=>'Crema',    p_usuario_id=>v_usr, p_opcion_id=>v_s2);
  CALL api.sp_guardar_menu_opcion(p_menu_categoria_id=>v_catB, p_nombre=>'Jugo',     p_usuario_id=>v_usr, p_opcion_id=>v_b1);
  CALL api.sp_guardar_menu_opcion(p_menu_categoria_id=>v_catB, p_nombre=>'Té',       p_usuario_id=>v_usr, p_opcion_id=>v_b2);

  /* 1 · pedido del chef eligiendo sopa + bebida: guarda las 2 opciones */
  CALL api.sp_crear_pedido(v_uni, 'recoger', 'efectivo',
       jsonb_build_array(jsonb_build_object('plato_dia_id', v_plato, 'cantidad', 1,
            'opciones', jsonb_build_array(v_s1, v_b1))),
       NULL, NULL, 'Cliente ZZ', '3001112233', NULL, NULL, NULL, NULL, 'zz45-1', v_ped, v_cod);
  SELECT count(*) INTO v_n FROM core.pedido_item_opciones x
     JOIN core.pedido_items i ON i.id=x.pedido_item_id WHERE i.pedido_id=v_ped;
  IF v_n = 2 THEN RAISE NOTICE '1 · OK  el plato del chef guardó las 2 opciones elegidas';
  ELSE v_fallos:=v_fallos+1; RAISE NOTICE '1 · FALLO: guardó % opciones (esperaba 2)', v_n; END IF;

  /* 2 · pedido del chef SIN la bebida obligatoria: debe fallar */
  BEGIN
    CALL api.sp_crear_pedido(v_uni, 'recoger', 'efectivo',
         jsonb_build_array(jsonb_build_object('plato_dia_id', v_plato, 'cantidad', 1,
              'opciones', jsonb_build_array(v_s1))),
         NULL, NULL, 'Cliente ZZ', '3001112233', NULL, NULL, NULL, NULL, 'zz45-2', v_ped, v_cod);
    v_fallos:=v_fallos+1; RAISE NOTICE '2 · FALLO: dejó pedir sin elegir la bebida obligatoria';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE '%Te falta elegir%' THEN RAISE NOTICE '2 · OK  exigió la obligatoria (%)' , v_err;
    ELSE v_fallos:=v_fallos+1; RAISE NOTICE '2 · FALLO: falló por otra razón: %', v_err; END IF;
  END;

  /* 3 · Menú del chef SIN el flag: el plato se agrega sin exigir nada */
  CALL api.sp_guardar_menu_dia(v_uni, DATE '2099-01-06', 'chef', v_usr, 'Chef B', NULL, NULL, TRUE, 'Chef B', NULL, v_menu2);
  CALL api.sp_guardar_plato_dia(p_menu_dia_id=>v_menu2, p_nombre=>'Plato YY', p_precio=>20000, p_usuario_id=>v_usr, p_plato_id=>v_plato2);
  CALL api.sp_crear_pedido(v_uni, 'recoger', 'efectivo',
       jsonb_build_array(jsonb_build_object('plato_dia_id', v_plato2, 'cantidad', 1)),
       NULL, NULL, 'Cliente ZZ', '3001112233', NULL, NULL, NULL, NULL, 'zz45-3', v_ped, v_cod);
  SELECT count(*) INTO v_n FROM core.pedido_item_opciones x
     JOIN core.pedido_items i ON i.id=x.pedido_item_id WHERE i.pedido_id=v_ped;
  IF v_ped IS NOT NULL AND v_n = 0 THEN RAISE NOTICE '3 · OK  chef sin flag: entra sin opciones ni exigencia';
  ELSE v_fallos:=v_fallos+1; RAISE NOTICE '3 · FALLO: chef sin flag se comportó raro (ped=% opc=%)', v_ped, v_n; END IF;

  /* 4 · Armado (no-regresión): sigue exigiendo su categoría obligatoria */
  CALL api.sp_guardar_menu_dia(v_uni, DATE '2099-01-07', 'armado', v_usr, 'Armado', NULL, 15000, TRUE, 'Armado', NULL, v_menuA);
  CALL api.sp_guardar_menu_categoria(p_menu_dia_id=>v_menuA, p_nombre=>'Proteína', p_usuario_id=>v_usr, p_max_seleccion=>1, p_obligatoria=>TRUE, p_categoria_id=>v_catA);
  CALL api.sp_guardar_menu_opcion(p_menu_categoria_id=>v_catA, p_nombre=>'Pollo', p_usuario_id=>v_usr, p_opcion_id=>v_a1);
  BEGIN
    CALL api.sp_crear_pedido(v_uni, 'recoger', 'efectivo',
         jsonb_build_array(jsonb_build_object('menu_dia_id', v_menuA, 'cantidad', 1, 'opciones', jsonb_build_array())),
         NULL, NULL, 'Cliente ZZ', '3001112233', NULL, NULL, NULL, NULL, 'zz45-4', v_ped, v_cod);
    v_fallos:=v_fallos+1; RAISE NOTICE '4 · FALLO: armado dejó pedir sin elegir la obligatoria';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    IF v_err LIKE '%Te falta elegir%' THEN RAISE NOTICE '4 · OK  armado sigue exigiendo su obligatoria';
    ELSE v_fallos:=v_fallos+1; RAISE NOTICE '4 · FALLO: armado falló por otra razón: %', v_err; END IF;
  END;

  RAISE NOTICE '=================================================';
  IF v_fallos=0 THEN RAISE NOTICE 'LAS 4 PRUEBAS PASARON';
  ELSE RAISE NOTICE '% PRUEBA(S) FALLARON', v_fallos; END IF;

  RAISE EXCEPTION 'FIN_PRUEBAS_45 (se deshace a propósito)';
END $$;
