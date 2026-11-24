/* ============================================================================
   60 · PRUEBAS · GRUPOS DE CAMBIO ADMINISTRABLES

       psql "<conexión>" -v ON_ERROR_STOP=1 -f database/60_pruebas_grupos_de_cambio.sql

   Se deshace sola. Tiene que salir «TODAS LAS PRUEBAS DE GRUPOS DE CAMBIO PASARON».
   ============================================================================ */
\pset pager off
BEGIN;

CREATE TEMP TABLE resultados (n SERIAL, ok BOOLEAN, que TEXT, detalle TEXT);

CREATE FUNCTION pg_temp.anotar(p_ok BOOLEAN, p_que TEXT, p_detalle TEXT DEFAULT '') RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO resultados (ok, que, detalle) VALUES (COALESCE(p_ok, FALSE), p_que, p_detalle); $$;

/* Corre como la aplicación, con la sesión del usuario que se diga */
CREATE FUNCTION pg_temp.app(p_usuario INT, p_empresa INT, p_sql TEXT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v JSONB;
BEGIN
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'taseca_app', 'usuario_id', p_usuario, 'empresa_id', p_empresa)::TEXT, TRUE);
  SET LOCAL ROLE taseca_app;
  EXECUTE p_sql INTO v;
  RESET ROLE;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RETURN jsonb_build_object('error', SQLERRM);
END $$;

CREATE FUNCTION pg_temp.grupos(p_empresa INT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(codigo || '=' || COALESCE(grupo_cambio, '-'), ' ' ORDER BY codigo), '')
    FROM core.insumos WHERE empresa_id = p_empresa; $$;

DO $$
DECLARE
  v_emp INT; v_otra INT; v_uni INT; v_admin INT; v_mesero INT; v_cat_ins INT; v_cat_otra INT;
  v_bar INT := (SELECT id FROM core.areas_inventario WHERE codigo = 'bar');
  v_um  INT := (SELECT id FROM core.unidades_medida ORDER BY id LIMIT 1);
  v_a INT; v_b INT; v_c INT; v_ajeno INT; v_r JSONB; v_txt TEXT;
BEGIN
  INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_t60', 'T60') RETURNING id INTO v_emp;
  INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_t60b', 'T60 otra') RETURNING id INTO v_otra;
  INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo) SELECT v_emp, id, TRUE FROM core.modulos;
  INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
  VALUES (v_emp, (SELECT id FROM core.tipos_negocio ORDER BY id LIMIT 1), 'T60 · Sede', 'T60') RETURNING id INTO v_uni;
  INSERT INTO core.categorias_insumo (empresa_id, nombre) VALUES (v_emp, 'Bebidas') RETURNING id INTO v_cat_ins;
  INSERT INTO core.categorias_insumo (empresa_id, nombre) VALUES (v_otra, 'Bebidas') RETURNING id INTO v_cat_otra;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre)
  VALUES (v_emp, v_cat_ins, v_bar, v_um, 'T60A', 'Postobón 1.5') RETURNING id INTO v_a;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre)
  VALUES (v_emp, v_cat_ins, v_bar, v_um, 'T60B', 'Coca-Cola 1.5') RETURNING id INTO v_b;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre)
  VALUES (v_emp, v_cat_ins, v_bar, v_um, 'T60C', 'Ginger 1.5') RETURNING id INTO v_c;
  INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre)
  VALUES (v_otra, v_cat_otra, v_bar, v_um, 'T60X', 'Ajena') RETURNING id INTO v_ajeno;
  INSERT INTO core.insumo_unidades (insumo_id, unidad_id) SELECT x, v_uni FROM unnest(ARRAY[v_a, v_b, v_c]) x;

  INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
  VALUES (v_emp, (SELECT id FROM core.roles WHERE codigo = 'admin'), 'Admin T60', 't60.admin', core.fn_hash_pin('1111'))
  RETURNING id INTO v_admin;
  INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
  VALUES (v_emp, (SELECT id FROM core.roles WHERE codigo = 'mesero'), 'Mesero T60', 't60.mesero', core.fn_hash_pin('2222'))
  RETURNING id INTO v_mesero;

  /* 1 · Crear el grupo con dos integrantes */
  v_r := pg_temp.app(v_admin, v_emp, format($s$SELECT rest.guardar_grupo_cambio('{"nombre":"  Gaseosa   1.5 ","insumos":[%s,%s]}')$s$, v_a, v_b));
  v_txt := pg_temp.grupos(v_emp);
  PERFORM pg_temp.anotar(v_txt = 'T60A=Gaseosa 1.5 T60B=Gaseosa 1.5 T60C=-', 'crear el grupo (con los espacios de más limpios)', COALESCE(v_r ->> 'error', v_txt));

  /* 2 · Un segundo grupo con el mismo nombre (otras mayúsculas) no se deja */
  v_r := pg_temp.app(v_admin, v_emp, format($s$SELECT rest.guardar_grupo_cambio('{"nombre":"GASEOSA 1.5","insumos":[%s]}')$s$, v_c));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%Ya hay un grupo «Gaseosa 1.5»%' AND pg_temp.grupos(v_emp) LIKE '%T60C=-%',
                         'no nacen dos grupos que se ven iguales', v_r::TEXT);

  /* 3 · Editar: agregar a Ginger y renombrar, en un golpe */
  v_r := pg_temp.app(v_admin, v_emp, format($s$SELECT rest.guardar_grupo_cambio('{"nombre":"Gaseosas 1.5 L","anterior":"Gaseosa 1.5","insumos":[%s,%s,%s]}')$s$, v_a, v_b, v_c));
  v_txt := pg_temp.grupos(v_emp);
  PERFORM pg_temp.anotar(v_txt = 'T60A=Gaseosas 1.5 L T60B=Gaseosas 1.5 L T60C=Gaseosas 1.5 L', 'renombrar y sumar a Ginger', COALESCE(v_r ->> 'error', v_txt));

  /* 4 · Cambiar sólo mayúsculas del propio grupo sí se deja */
  v_r := pg_temp.app(v_admin, v_emp, format($s$SELECT rest.guardar_grupo_cambio('{"nombre":"GASEOSAS 1.5 L","anterior":"Gaseosas 1.5 L","insumos":[%s,%s,%s]}')$s$, v_a, v_b, v_c));
  PERFORM pg_temp.anotar(v_r ->> 'error' IS NULL AND pg_temp.grupos(v_emp) LIKE 'T60A=GASEOSAS 1.5 L%', 'corregir las mayúsculas del mismo grupo', v_r::TEXT);

  /* 5 · Sacar a Coca-Cola del grupo */
  v_r := pg_temp.app(v_admin, v_emp, format($s$SELECT rest.guardar_grupo_cambio('{"nombre":"GASEOSAS 1.5 L","anterior":"GASEOSAS 1.5 L","insumos":[%s,%s]}')$s$, v_a, v_c));
  v_txt := pg_temp.grupos(v_emp);
  PERFORM pg_temp.anotar(v_txt = 'T60A=GASEOSAS 1.5 L T60B=- T60C=GASEOSAS 1.5 L', 'sacar uno del grupo', COALESCE(v_r ->> 'error', v_txt));

  /* 6 · Pasar a Ginger a otro grupo: deja el primero */
  v_r := pg_temp.app(v_admin, v_emp, format($s$SELECT rest.guardar_grupo_cambio('{"nombre":"Jugos","insumos":[%s,%s]}')$s$, v_b, v_c));
  v_txt := pg_temp.grupos(v_emp);
  PERFORM pg_temp.anotar(v_txt = 'T60A=GASEOSAS 1.5 L T60B=Jugos T60C=Jugos', 'un insumo está en un solo grupo', COALESCE(v_r ->> 'error', v_txt));

  /* 7 · Desde el editor del insumo: un nombre con otras mayúsculas se lleva al que existe */
  v_r := pg_temp.app(v_admin, v_emp, format($s$SELECT rest.guardar_insumo('{"insumo_id":%s,"codigo":"T60B","nombre":"Coca-Cola 1.5","categoria":"Bebidas","area":"bar",
            "unidad":"unidad","unidades":[%s],"grupo_cambio":"gaseosas   1.5 l"}')$s$, v_b, v_uni));
  v_txt := pg_temp.grupos(v_emp);
  PERFORM pg_temp.anotar(v_txt LIKE '%T60B=GASEOSAS 1.5 L%', 'el editor usa el nombre que ya existe', COALESCE(v_r ->> 'error', v_txt));

  /* 8 · Quitar el grupo: sin integrantes desaparece */
  v_r := pg_temp.app(v_admin, v_emp, $s$SELECT rest.guardar_grupo_cambio('{"nombre":"Jugos","anterior":"Jugos","insumos":[]}')$s$);
  PERFORM pg_temp.anotar(pg_temp.grupos(v_emp) NOT LIKE '%Jugos%', 'quitar el grupo', COALESCE(v_r ->> 'error', pg_temp.grupos(v_emp)));

  /* 9 · Seguridad: un insumo de otra empresa no entra; sin permiso de stock, nada */
  v_r := pg_temp.app(v_admin, v_emp, format($s$SELECT rest.guardar_grupo_cambio('{"nombre":"Robo","insumos":[%s]}')$s$, v_ajeno));
  PERFORM pg_temp.anotar(v_r ->> 'error' LIKE '%no existe%' AND (SELECT grupo_cambio FROM core.insumos WHERE id = v_ajeno) IS NULL,
                         'no se puede meter un insumo de otra empresa', v_r::TEXT);
  v_r := pg_temp.app(v_mesero, v_emp, format($s$SELECT rest.guardar_grupo_cambio('{"nombre":"Mesero","insumos":[%s]}')$s$, v_a));
  PERFORM pg_temp.anotar(v_r ? 'error' AND pg_temp.grupos(v_emp) NOT LIKE '%Mesero%', 'un mesero no maneja grupos', v_r::TEXT);
END $$;

SELECT CASE WHEN ok THEN '✔' ELSE '✘ FALLA' END AS r, que, detalle FROM resultados ORDER BY ok, n;

DO $$
DECLARE v_mal INT; v_total INT;
BEGIN
  SELECT count(*) FILTER (WHERE NOT ok), count(*) INTO v_mal, v_total FROM resultados;
  IF v_mal = 0 THEN RAISE NOTICE 'TODAS LAS PRUEBAS DE GRUPOS DE CAMBIO PASARON (% comprobaciones)', v_total;
  ELSE RAISE NOTICE '% DE % COMPROBACIONES FALLARON', v_mal, v_total; END IF;
END $$;

ROLLBACK;
