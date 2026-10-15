/* ============================================================================
   TASECA · 21 · AUDITORÍA: UN PEDIDO Y SU INVENTARIO, DE PUNTA A PUNTA
   ----------------------------------------------------------------------------
   Responde a una sola pregunta, y la responde con hechos:

     ¿Desde que se crea un pedido hasta que su mercancía se descuenta del
     inventario, TODO sabe de qué empresa y de qué sucursal es?

   Dos partes:

     1. TUS DATOS DE VERDAD. Pasa api.fn_chequeo_integridad() sobre la base
        tal y como está. Si hay una sola relación cruzada, el script para y
        la señala.

     2. LA BASE PUESTA A PRUEBA. Monta dos empresas completas -cada una con
        su sucursal, su carta, su inventario y su gente- y además una segunda
        sucursal dentro de la primera. Después INTENTA cruzarlas por todos
        los caminos que existen: por la vía de la aplicación y escribiendo
        directo en las tablas. Cada intento tiene que fallar.

   Todo corre dentro de una transacción que termina en ROLLBACK: **no deja
   ningún dato**. No modifica pedidos, ventas, pagos ni auditoría.

   Dónde ejecutarlo:
     · Supabase → SQL Editor, pegar y Run.
     · DBeaver  → Alt+X y mirar la pestaña «Salida».
   Cada prueba escribe ✔. Si algo falla, el script se detiene y dice qué.

   Requiere: 00 … 17 instalados.
   ============================================================================ */

BEGIN;

CREATE FUNCTION pg_temp.esperar_error(p_sql TEXT, p_contiene TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM ILIKE '%' || p_contiene || '%' THEN
            RAISE NOTICE '      ✔ bloqueado: %', SQLERRM;
            RETURN;
        END IF;
        RAISE EXCEPTION 'Falló con otro error: «%» (se esperaba «%»)', SQLERRM, p_contiene;
    END;
    RAISE EXCEPTION 'DEBIÓ FALLAR Y NO FALLÓ: %', p_sql;
END;
$$;

/* Token simulado, el mismo que usan las demás pruebas. */
CREATE FUNCTION pg_temp.token(p_usuario TEXT, p_empresa INTEGER DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_id INTEGER;
    v_empresa INTEGER;
BEGIN
    SELECT id, empresa_id INTO v_id, v_empresa FROM core.usuarios WHERE usuario = p_usuario;
    PERFORM set_config('request.jwt.claims',
                       jsonb_build_object('role', 'taseca_app', 'usuario_id', v_id,
                                          'empresa_id', CASE WHEN p_empresa = -1 THEN NULL ELSE COALESCE(p_empresa, v_empresa) END)::TEXT, TRUE);
END;
$$;

CREATE FUNCTION pg_temp.app(p_sql TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v JSONB;
BEGIN
    SET LOCAL ROLE taseca_app;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
END;
$$;


/* ============================================================================
   PARTE 1 · TUS DATOS DE VERDAD
   ============================================================================ */

DO $$
DECLARE
    v_err INTEGER; v_avi INTEGER; r RECORD;
BEGIN
    SELECT count(*) FILTER (WHERE gravedad = 'ERROR' AND filas > 0),
           count(*) FILTER (WHERE gravedad = 'AVISO' AND filas > 0)
      INTO v_err, v_avi
      FROM api.fn_chequeo_integridad();

    FOR r IN SELECT * FROM api.fn_chequeo_integridad() WHERE filas > 0 ORDER BY gravedad, tabla LOOP
        RAISE NOTICE '      % · % · % → % fila(s): %', r.gravedad, r.tabla, r.chequeo, r.filas, r.ejemplo;
    END LOOP;

    ASSERT v_err = 0, format('Hay %s relación(es) cruzada(s) en tus datos: mira el detalle de arriba', v_err);
    RAISE NOTICE '✔ 1  Tus datos: 0 relaciones cruzadas (avisos informativos, que no son fallos: %)', v_avi;
END;
$$;


/* ============================================================================
   PARTE 2 · LA BASE PUESTA A PRUEBA
   ============================================================================ */

DO $$
DECLARE
    -- Empresa A, con DOS sucursales; empresa B, con una
    v_ea INTEGER; v_ua1 INTEGER; v_ua2 INTEGER;
    v_eb INTEGER; v_ub  INTEGER;

    v_cat_a INTEGER; v_cat_b INTEGER;
    v_pa    INTEGER; v_pb    INTEGER;   -- productos
    v_ia    INTEGER; v_ib    INTEGER;   -- insumos
    v_iua1  INTEGER; v_iua2  INTEGER; v_iub INTEGER;  -- insumo en cada sucursal
    v_mesa_a1 INTEGER; v_mesa_a2 INTEGER; v_zona_a2 INTEGER;
    v_admin_a INTEGER; v_admin_b INTEGER; v_caja_b INTEGER;

    v_ped_a1 BIGINT; v_ped_a2 BIGINT; v_ped_b BIGINT;
    v_cod_a1 VARCHAR; v_cod_a2 VARCHAR; v_cod_b VARCHAR;
    v_cierre BIGINT;
    v_r JSONB; v_n NUMERIC; v_i INTEGER; v_hoy DATE;
    v_area INTEGER := (SELECT id FROM core.areas_inventario ORDER BY id LIMIT 1);
    v_um   INTEGER := (SELECT id FROM core.unidades_medida  ORDER BY id LIMIT 1);
    v_tipo INTEGER := (SELECT id FROM core.tipos_negocio     ORDER BY id LIMIT 1);
    v_rol  INTEGER := (SELECT id FROM core.roles WHERE codigo = 'admin');
    v_rolc INTEGER := (SELECT id FROM core.roles WHERE codigo = 'caja');
BEGIN
    /* ---------- Las dos empresas, completas ---------- */
    INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_aud_a', 'Auditoría A') RETURNING id INTO v_ea;
    INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_aud_b', 'Auditoría B') RETURNING id INTO v_eb;

    INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
    VALUES (v_ea, v_tipo, 'A · Sede Norte', 'A-Norte') RETURNING id INTO v_ua1;
    INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
    VALUES (v_ea, v_tipo, 'A · Sede Sur', 'A-Sur') RETURNING id INTO v_ua2;
    INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
    VALUES (v_eb, v_tipo, 'B · Sede Única', 'B-Única') RETURNING id INTO v_ub;

    INSERT INTO core.mesas (unidad_id, numero) VALUES (v_ua1, '1') RETURNING id INTO v_mesa_a1;
    INSERT INTO core.mesas (unidad_id, numero) VALUES (v_ua2, '1') RETURNING id INTO v_mesa_a2;
    INSERT INTO core.mesas (unidad_id, numero) VALUES (v_ub, '1');
    INSERT INTO core.zonas_domicilio (unidad_id, nombre) VALUES (v_ua2, 'Zona Sur') RETURNING id INTO v_zona_a2;

    -- Todos los módulos: sin ellos sus usuarios no tendrían ningún permiso
    INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo) SELECT v_ea, id, TRUE FROM core.modulos;
    INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo) SELECT v_eb, id, TRUE FROM core.modulos;

    INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos) VALUES (v_ea, 'pedido', 0, 5);
    INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos) VALUES (v_eb, 'pedido', 0, 5);

    INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo)
    SELECT v_ea, id, codigo = 'efectivo' FROM core.metodos_pago;
    INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo)
    SELECT v_eb, id, TRUE FROM core.metodos_pago WHERE codigo = 'efectivo';

    -- Carta: el MISMO plato en las dos empresas, para que nada se distinga por el nombre
    INSERT INTO core.categorias (empresa_id, nombre) VALUES (v_ea, 'Platos') RETURNING id INTO v_cat_a;
    INSERT INTO core.categorias (empresa_id, nombre) VALUES (v_eb, 'Platos') RETURNING id INTO v_cat_b;
    INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio)
    VALUES (v_ea, v_cat_a, 'AUD-1', 'Bandeja', 20000) RETURNING id INTO v_pa;
    INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio)
    VALUES (v_eb, v_cat_b, 'AUD-1', 'Bandeja', 20000) RETURNING id INTO v_pb;

    -- El producto de A se vende en las DOS sucursales de A; el de B sólo en B
    INSERT INTO core.producto_unidades (producto_id, unidad_id) VALUES (v_pa, v_ua1), (v_pa, v_ua2), (v_pb, v_ub);

    -- Inventario: el mismo insumo de nombre en las dos empresas
    INSERT INTO core.categorias_insumo (empresa_id, nombre) VALUES (v_ea, 'Carnes');
    INSERT INTO core.categorias_insumo (empresa_id, nombre) VALUES (v_eb, 'Carnes');
    INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre)
    VALUES (v_ea, (SELECT id FROM core.categorias_insumo WHERE empresa_id = v_ea), v_area, v_um, 'AUD-I1', 'Carne')
    RETURNING id INTO v_ia;
    INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre)
    VALUES (v_eb, (SELECT id FROM core.categorias_insumo WHERE empresa_id = v_eb), v_area, v_um, 'AUD-I1', 'Carne')
    RETURNING id INTO v_ib;

    INSERT INTO core.insumo_unidades (insumo_id, unidad_id) VALUES (v_ia, v_ua1) RETURNING id INTO v_iua1;
    INSERT INTO core.insumo_unidades (insumo_id, unidad_id) VALUES (v_ia, v_ua2) RETURNING id INTO v_iua2;
    INSERT INTO core.insumo_unidades (insumo_id, unidad_id) VALUES (v_ib, v_ub)  RETURNING id INTO v_iub;

    -- Receta: cada Bandeja gasta 1 Carne
    INSERT INTO core.producto_insumos (producto_id, insumo_id, cantidad) VALUES (v_pa, v_ia, 1), (v_pb, v_ib, 1);

    -- Gente
    INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
    VALUES (v_ea, v_rol, 'Admin A', 'aud.admin.a', core.fn_hash_pin('1111')) RETURNING id INTO v_admin_a;
    INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
    VALUES (v_eb, v_rol, 'Admin B', 'aud.admin.b', core.fn_hash_pin('2222')) RETURNING id INTO v_admin_b;
    INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
    VALUES (v_eb, v_rolc, 'Caja B', 'aud.caja.b', core.fn_hash_pin('3333')) RETURNING id INTO v_caja_b;
    INSERT INTO core.usuario_unidades (usuario_id, unidad_id) VALUES (v_admin_a, v_ua1), (v_admin_a, v_ua2),
                                                                     (v_admin_b, v_ub), (v_caja_b, v_ub);

    v_hoy := core.fn_fecha_operativa(v_ea, now());

    -- ========================================================================
    -- 2 · UN PEDIDO NACE CON LA EMPRESA DE SU SUCURSAL
    -- ========================================================================
    CALL api.sp_crear_pedido(p_unidad_id => v_ua1, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_pa, 'cantidad', 2)),
         p_usuario_id => v_admin_a, p_mesa => '1', p_pedido_id => v_ped_a1, p_codigo => v_cod_a1);

    ASSERT (SELECT empresa_id FROM core.pedidos WHERE id = v_ped_a1) = v_ea, 'La empresa sale de la unidad';
    ASSERT (SELECT unidad_id  FROM core.pedidos WHERE id = v_ped_a1) = v_ua1, 'Y la sucursal es la que se pidió';
    -- Una vez creada, ni la empresa ni la sucursal se le pueden cambiar a mano
    PERFORM pg_temp.esperar_error(
        format('UPDATE core.pedidos SET empresa_id = %s WHERE id = %s', v_eb, v_ped_a1),
        'no puede cambiar de empresa, unidad');
    PERFORM pg_temp.esperar_error(
        format('UPDATE core.pedidos SET unidad_id = %s WHERE id = %s', v_ub, v_ped_a1),
        'no puede cambiar de empresa, unidad');
    -- Y naciendo torcida tampoco: la empresa tiene que ser la de su unidad
    PERFORM pg_temp.esperar_error(
        format($q$INSERT INTO core.pedidos (empresa_id, unidad_id, codigo, tipo_pedido_id, estado_pedido_id, estado_pago_id, metodo_pago_id, fecha_operativa)
               VALUES (%s, %s, 'X0001',
                       (SELECT id FROM core.tipos_pedido WHERE codigo = 'mesa'),
                       (SELECT id FROM core.estados_pedido WHERE codigo = 'nuevo'),
                       (SELECT id FROM core.estados_pago WHERE codigo = 'pendiente'),
                       (SELECT id FROM core.metodos_pago WHERE codigo = 'efectivo'), '%s')$q$,
               v_eb, v_ua1, v_hoy),
        'no pertenece a la empresa');
    RAISE NOTICE '✔ 2  La factura hereda la empresa de su sucursal, y ni naciendo ni después se le puede cambiar';

    -- ========================================================================
    -- 3 · MESA, ZONA Y CLIENTE TIENEN QUE SER DE ESA MISMA SUCURSAL
    -- ========================================================================
    PERFORM pg_temp.esperar_error(
        format('UPDATE core.pedidos SET mesa_id = %s WHERE id = %s', v_mesa_a2, v_ped_a1),
        'mesa es de otra unidad');
    PERFORM pg_temp.esperar_error(
        format('UPDATE core.pedidos SET zona_domicilio_id = %s WHERE id = %s', v_zona_a2, v_ped_a1),
        'zona de domicilio es de otra unidad');
    -- La mesa «1» existe en las dos sucursales: el procedimiento busca la de SU unidad
    CALL api.sp_crear_pedido(p_unidad_id => v_ua2, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_pa, 'cantidad', 1)),
         p_usuario_id => v_admin_a, p_mesa => '1', p_pedido_id => v_ped_a2, p_codigo => v_cod_a2);
    ASSERT (SELECT mesa_id FROM core.pedidos WHERE id = v_ped_a2) = v_mesa_a2,
           'Dos sucursales con mesa «1»: cada pedido tiene que coger la suya';

    INSERT INTO core.clientes (empresa_id, nombre, telefono) VALUES (v_eb, 'Cliente de B', '3000000000');
    PERFORM pg_temp.esperar_error(
        format('UPDATE core.pedidos SET cliente_id = (SELECT id FROM core.clientes WHERE empresa_id = %s) WHERE id = %s', v_eb, v_ped_a1),
        'cliente es de otra empresa');
    RAISE NOTICE '✔ 3  Mesa, zona y cliente: de la sucursal y la empresa de la factura, nunca de otra';

    -- ========================================================================
    -- 4 · LA CARTA DEL PEDIDO ES LA DE ESA SUCURSAL
    -- ========================================================================
    -- Producto de la otra empresa (mismo código y mismo nombre)
    PERFORM pg_temp.esperar_error(
        format($q$CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
               p_items => '[{"producto_id": %s, "cantidad": 1}]'::JSONB, p_usuario_id => %s, p_mesa => '1')$q$,
               v_ua1, v_pb, v_admin_a),
        'no se vende en la unidad');
    -- Producto de la MISMA empresa pero retirado de esa sucursal
    DELETE FROM core.producto_unidades WHERE producto_id = v_pa AND unidad_id = v_ua2;
    PERFORM pg_temp.esperar_error(
        format($q$CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
               p_items => '[{"producto_id": %s, "cantidad": 1}]'::JSONB, p_usuario_id => %s, p_mesa => '1')$q$,
               v_ua2, v_pa, v_admin_a),
        'no se vende en la unidad');
    INSERT INTO core.producto_unidades (producto_id, unidad_id) VALUES (v_pa, v_ua2);
    -- Y por debajo de la aplicación tampoco
    PERFORM pg_temp.esperar_error(
        format('INSERT INTO core.pedido_items (pedido_id, producto_id, nombre, precio_unitario, cantidad) VALUES (%s, %s, ''Bandeja'', 20000, 1)',
               v_ped_a1, v_pb),
        'no se vende en la unidad');
    RAISE NOTICE '✔ 4  Un pedido sólo lleva productos de su empresa Y de su sucursal, por la aplicación y por debajo';

    -- ========================================================================
    -- 5 · EL MÉTODO DE PAGO ES DE LA EMPRESA
    -- ========================================================================
    PERFORM pg_temp.esperar_error(
        format($q$CALL api.sp_crear_pedido(p_unidad_id => %s, p_tipo => 'mesa', p_metodo_pago => 'datafono',
               p_items => '[{"producto_id": %s, "cantidad": 1}]'::JSONB, p_usuario_id => %s, p_mesa => '1')$q$,
               v_ua1, v_pa, v_admin_a),
        'no está disponible');
    RAISE NOTICE '✔ 5  No se cobra con un método que esa empresa no tiene habilitado';

    -- ========================================================================
    -- 6 · LA NUMERACIÓN ES DE CADA EMPRESA
    -- ========================================================================
    CALL api.sp_crear_pedido(p_unidad_id => v_ub, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_pb, 'cantidad', 1)),
         p_usuario_id => v_admin_b, p_mesa => '1', p_pedido_id => v_ped_b, p_codigo => v_cod_b);

    ASSERT v_cod_a1 = '00001' AND v_cod_b = '00001',
           format('Cada empresa numera desde 00001 (salió A=%s B=%s)', v_cod_a1, v_cod_b);
    ASSERT v_cod_a2 = '00002', format('Las dos sucursales de A comparten numeración (salió %s)', v_cod_a2);
    RAISE NOTICE '✔ 6  La numeración es por empresa: A y B tienen su 00001 y no chocan';

    -- ========================================================================
    -- 7 · OPERAR UN PEDIDO AJENO
    -- ========================================================================
    PERFORM pg_temp.esperar_error(
        format('CALL api.sp_avanzar_estado_pedido(%s, %s)', v_ped_a1, v_admin_b),
        'no trabaja en la unidad');
    PERFORM pg_temp.esperar_error(
        format('CALL api.sp_cancelar_pedido(%s, ''Prueba'', %s)', v_ped_a1, v_admin_b),
        'no trabaja en la unidad');
    PERFORM pg_temp.esperar_error(
        format('CALL api.sp_actualizar_pago(%s, ''confirmado'', %s, NULL, ''efectivo'')', v_ped_a1, v_caja_b),
        'no trabaja en la unidad');
    RAISE NOTICE '✔ 7  Nadie de otra empresa avanza, cancela ni cobra una factura que no es suya';

    -- ========================================================================
    -- 8 · EL INVENTARIO DESCUENTA POR SUCURSAL, NO POR EMPRESA
    -- ========================================================================
    /* A-Norte vendió 2 Bandejas, A-Sur 1, B 1. El mismo insumo, con el mismo
       nombre, existe en las tres sucursales.

       Cada factura la entrega la gente de SU empresa: el historial que deja el
       cambio de estado va firmado, y desde el script 22 ese movimiento tampoco
       lo puede firmar alguien de otra empresa. */
    PERFORM core.fn_fijar_usuario(v_admin_a);
    UPDATE core.pedidos SET estado_pedido_id = (SELECT id FROM core.estados_pedido WHERE codigo = 'entregado')
     WHERE id IN (v_ped_a1, v_ped_a2);
    PERFORM core.fn_fijar_usuario(v_admin_b);
    UPDATE core.pedidos SET estado_pedido_id = (SELECT id FROM core.estados_pedido WHERE codigo = 'entregado')
     WHERE id = v_ped_b;
    PERFORM core.fn_fijar_usuario(v_admin_a);

    ASSERT core.fn_z_insumo(v_iua1, v_hoy - 1, v_hoy) = 2,
           format('A-Norte vendió 2 (salió %s)', core.fn_z_insumo(v_iua1, v_hoy - 1, v_hoy));
    ASSERT core.fn_z_insumo(v_iua2, v_hoy - 1, v_hoy) = 1,
           format('A-Sur vendió 1 (salió %s)', core.fn_z_insumo(v_iua2, v_hoy - 1, v_hoy));
    ASSERT core.fn_z_insumo(v_iub,  v_hoy - 1, v_hoy) = 1,
           format('B vendió 1 (salió %s)', core.fn_z_insumo(v_iub, v_hoy - 1, v_hoy));
    RAISE NOTICE '✔ 8  Lo vendido se descuenta en la sucursal que lo vendió: 2 en A-Norte, 1 en A-Sur, 1 en B';

    -- ========================================================================
    -- 9 · LA RECETA NO PUEDE UNIR DOS EMPRESAS
    -- ========================================================================
    PERFORM pg_temp.esperar_error(
        format('INSERT INTO core.producto_insumos (producto_id, insumo_id, cantidad) VALUES (%s, %s, 1)', v_pa, v_ib),
        'empresa');
    PERFORM pg_temp.esperar_error(
        format('INSERT INTO core.insumo_unidades (insumo_id, unidad_id) VALUES (%s, %s)', v_ib, v_ua1),
        'empresa');
    PERFORM pg_temp.esperar_error(
        format('INSERT INTO core.producto_unidades (producto_id, unidad_id) VALUES (%s, %s)', v_pb, v_ua1),
        'empresa');
    RAISE NOTICE '✔ 9  Una receta no une producto e insumo de empresas distintas, ni se cuelan en la sucursal de otra';

    -- ========================================================================
    -- 10 · ENTRADAS, CONTEOS Y CAJA, CADA UNO EN SU SUCURSAL
    -- ========================================================================
    INSERT INTO core.entradas_inventario (insumo_unidad_id, tipo_entrada_id, fecha_operativa, cantidad, usuario_id)
    VALUES (v_iua1, (SELECT id FROM core.tipos_entrada WHERE codigo = 'compra'), v_hoy, 10, v_admin_a);

    -- Una entrada de A firmada por alguien de B
    PERFORM pg_temp.esperar_error(
        format($q$INSERT INTO core.entradas_inventario (insumo_unidad_id, tipo_entrada_id, fecha_operativa, cantidad, usuario_id)
               VALUES (%s, (SELECT id FROM core.tipos_entrada WHERE codigo = 'compra'), '%s', 5, %s)$q$,
               v_iua1, v_hoy, v_admin_b),
        'no es de la empresa de la unidad');
    -- Un retorno de una factura de otra sucursal
    PERFORM pg_temp.esperar_error(
        format($q$INSERT INTO core.entradas_inventario (insumo_unidad_id, tipo_entrada_id, fecha_operativa, cantidad, pedido_id, usuario_id)
               VALUES (%s, (SELECT id FROM core.tipos_entrada WHERE codigo = 'retorno_anulacion'), '%s', 1, %s, %s)$q$,
               v_iua1, v_hoy, v_ped_a2, v_admin_a),
        'otra unidad');

    -- Conteo de cierre con un insumo de otra sucursal
    INSERT INTO core.cierres_inventario (unidad_id, area_id, estado_cierre_id, fecha_operativa, registrado_por_id)
    VALUES (v_ua1, v_area, (SELECT id FROM core.estados_cierre WHERE codigo = 'borrador'), v_hoy, v_admin_a)
    RETURNING id INTO v_cierre;
    PERFORM pg_temp.esperar_error(
        format('INSERT INTO core.cierre_detalles (cierre_id, insumo_unidad_id, saldo_fisico) VALUES (%s, %s, 1)',
               v_cierre, v_iua2),
        'no es de la unidad ni del área de este cierre');

    -- Base de caja de A firmada por alguien de B
    PERFORM pg_temp.esperar_error(
        format($q$INSERT INTO core.bases_caja (unidad_id, fecha_operativa, monto, usuario_id) VALUES (%s, '%s', 100000, %s)$q$,
               v_ua1, v_hoy, v_admin_b),
        'no es de la empresa de la unidad');
    RAISE NOTICE '✔ 10 Entradas, conteos de cierre y base de caja se quedan en su sucursal y en su empresa';

    -- ========================================================================
    -- 11 · EL CRUCE DE INVENTARIO SEPARA LAS SUCURSALES
    -- ========================================================================
    INSERT INTO core.cierre_detalles (cierre_id, insumo_unidad_id, saldo_fisico) VALUES (v_cierre, v_iua1, 8);
    SELECT ventas, entradas, unidad_id INTO v_n, v_i, v_ua1
      FROM api.v_cruce_inventario WHERE cierre_id = v_cierre AND insumo = 'Carne';
    ASSERT v_n = 2, format('El cruce de A-Norte cuenta sus 2 ventas, no las 4 de todos (salió %s)', v_n);
    ASSERT v_i = 10, format('Y sus 10 de entrada (salió %s)', v_i);
    RAISE NOTICE '✔ 11 El cruce de inventario de una sucursal sólo mira lo que entró y salió en ELLA';

    -- ========================================================================
    -- 12 · CADA EMPRESA LEE LO SUYO
    -- ========================================================================
    PERFORM pg_temp.token('aud.admin.b');
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.pedidos')::TEXT::INTEGER = 1,
           'El Admin de B sólo ve la factura de B';
    ASSERT pg_temp.app(format('SELECT to_jsonb(count(*)) FROM rest.pedidos WHERE pedido_id = %s', v_ped_a1))::TEXT::INTEGER = 0,
           'Y la de A no existe para él';
    ASSERT pg_temp.app('SELECT to_jsonb(count(*)) FROM rest.stock')::TEXT::INTEGER = 1,
           'Su inventario es el suyo';
    -- Aunque el token diga que es de la empresa A
    PERFORM pg_temp.token('aud.admin.b', v_ea);
    PERFORM pg_temp.esperar_error(
        format($q$SELECT pg_temp.app('SELECT rest.avanzar_estado(%s)')$q$, v_ped_a1),
        'no trabaja en la unidad');
    RAISE NOTICE '✔ 12 Cada empresa lee y mueve lo suyo, aunque el token diga otra cosa';

    -- ========================================================================
    -- 13 · NADA DEL CAMINO DEL PEDIDO LO FIRMA ALGUIEN DE OTRA EMPRESA
    --      (las cinco tablas que cerró database/22_relaciones_empresa_completas.sql;
    --       sin ese script esta prueba falla, y eso es justo lo que avisa)
    -- ========================================================================
    PERFORM pg_temp.esperar_error(
        format($q$INSERT INTO core.cierres_inventario (unidad_id, area_id, estado_cierre_id, fecha_operativa, registrado_por_id)
               VALUES (%s, %s, (SELECT id FROM core.estados_cierre WHERE codigo = 'borrador'), '%s', %s)$q$,
               v_ua1, v_area, v_hoy, v_admin_b),
        'no es de la empresa de la unidad');
    PERFORM pg_temp.esperar_error(
        format($q$INSERT INTO core.menus_dia (unidad_id, tipo_menu_id, fecha, creado_por_id)
               VALUES (%s, (SELECT id FROM core.tipos_menu ORDER BY id LIMIT 1), '%s', %s)$q$,
               v_ua1, v_hoy + 30, v_admin_b),
        'no es de la empresa de la unidad');
    PERFORM pg_temp.esperar_error(
        format('INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id) VALUES (%s, ''prueba'', %s)',
               v_ped_a1, v_admin_b),
        'otra empresa');
    PERFORM pg_temp.esperar_error(
        format($q$INSERT INTO core.comprobantes_pago (pedido_id, estado_pago_id, referencia, revisado_por_id)
               VALUES (%s, (SELECT id FROM core.estados_pago WHERE codigo = 'reportado'), 'REF-1', %s)$q$,
               v_ped_a1, v_admin_b),
        'otra empresa');
    PERFORM pg_temp.esperar_error(
        format($q$INSERT INTO core.anulaciones (pedido_id, motivo, usuario_id, jornada_original, jornada_retorno)
               VALUES (%s, 'prueba', %s, '%s', '%s')$q$,
               v_ped_a1, v_admin_b, v_hoy, v_hoy),
        'otra empresa');
    RAISE NOTICE '✔ 13 Cierres, menús, historial, comprobantes y anulaciones: nadie de otra empresa los firma';
END;
$$;

ROLLBACK;
