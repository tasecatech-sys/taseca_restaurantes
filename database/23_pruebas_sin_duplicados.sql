/* ============================================================================
   TASECA · 23 · PRUEBAS: UN ENVÍO, UN PEDIDO
   ----------------------------------------------------------------------------
   Ejecutar después de 23_pedidos_sin_duplicados.sql. Todo dentro de una
   transacción que termina en ROLLBACK: no deja ningún dato.

   Lo que se comprueba:
     1. El mismo envío dos veces deja UN pedido, y las dos veces responde el
        mismo. Ni dos facturas ni un error en la cara del mesero.
     2. El consecutivo no se gasta con el repetido.
     3. Dos envíos distintos siguen siendo dos pedidos: esto no bloquea a
        quien pide dos veces lo mismo a propósito.
     4. Sin clave, todo funciona como antes.
     5. La clave es de cada empresa: la misma en otra empresa sí crea pedido.

   En DBeaver: Alt+X y mira la pestaña «Salida». Cada prueba escribe ✔.
   ============================================================================ */

BEGIN;

DO $$
DECLARE
    v_admin  INTEGER;
    v_unidad INTEGER;
    v_prod   INTEGER;
    v_items  JSONB;
    v_p1 BIGINT; v_c1 VARCHAR;
    v_p2 BIGINT; v_c2 VARCHAR;
    v_p3 BIGINT; v_c3 VARCHAR;
    v_n   INTEGER;
    v_ult INTEGER;
    v_ult2 INTEGER;

    -- Para la prueba 5
    v_emp2 INTEGER; v_uni2 INTEGER; v_cat2 INTEGER; v_prod2 INTEGER; v_adm2 INTEGER;
    v_po BIGINT; v_co VARCHAR;
BEGIN
    SELECT u.id INTO v_admin FROM core.usuarios u WHERE u.usuario = 'admin';
    /* Una unidad que tenga carta: la prueba no inventa productos, usa los que
       ya hay, igual que haría el mesero. */
    SELECT pu.unidad_id, pu.producto_id INTO v_unidad, v_prod
      FROM core.producto_unidades pu
      JOIN core.productos p ON p.id = pu.producto_id
      JOIN core.unidades  u ON u.id = pu.unidad_id
     WHERE p.activo AND u.estado = 'activa'
     ORDER BY pu.unidad_id, pu.producto_id
     LIMIT 1;
    ASSERT v_unidad IS NOT NULL, 'No hay ninguna unidad con carta: la prueba necesita al menos un producto';

    v_items := jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1));

    -- 1 · EL MISMO ENVÍO DOS VECES -----------------------------------------------------
    SELECT ultimo_numero INTO v_ult FROM core.consecutivos
     WHERE empresa_id = core.fn_empresa_de_unidad(v_unidad) AND tipo = 'pedido';

    CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => v_items, p_usuario_id => v_admin, p_mesa => '1',
         p_clave => 'envio-de-prueba-1', p_pedido_id => v_p1, p_codigo => v_c1);

    -- El mesero toca otra vez porque la pantalla se quedó pensando
    CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => v_items, p_usuario_id => v_admin, p_mesa => '1',
         p_clave => 'envio-de-prueba-1', p_pedido_id => v_p2, p_codigo => v_c2);

    ASSERT v_p1 = v_p2, format('El segundo toque creó otra factura (%s y %s)', v_p1, v_p2);
    ASSERT v_c1 = v_c2, format('Y con otro número (%s y %s)', v_c1, v_c2);
    SELECT count(*) INTO v_n FROM core.pedidos WHERE clave_envio = 'envio-de-prueba-1';
    ASSERT v_n = 1, format('Quedaron %s facturas con el mismo envío', v_n);
    RAISE NOTICE '✔ 1  El mismo envío dos veces deja una sola factura (%), y la segunda vez responde la misma', v_c1;

    -- 2 · EL CONSECUTIVO NO SE GASTA ---------------------------------------------------
    SELECT ultimo_numero INTO v_ult2 FROM core.consecutivos
     WHERE empresa_id = core.fn_empresa_de_unidad(v_unidad) AND tipo = 'pedido';
    ASSERT v_ult2 = v_ult + 1,
           format('La numeración avanzó %s veces por un solo pedido', v_ult2 - v_ult);
    RAISE NOTICE '✔ 2  El toque repetido no gasta un número de factura';

    -- 3 · DOS ENVÍOS DISTINTOS SIGUEN SIENDO DOS PEDIDOS -------------------------------
    CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => v_items, p_usuario_id => v_admin, p_mesa => '1',
         p_clave => 'envio-de-prueba-2', p_pedido_id => v_p3, p_codigo => v_c3);
    ASSERT v_p3 <> v_p1, 'Un envío distinto tiene que crear otra factura';
    RAISE NOTICE '✔ 3  Pedir dos veces lo mismo a propósito sigue creando dos facturas (% y %)', v_c1, v_c3;

    -- 4 · SIN CLAVE, COMO SIEMPRE ------------------------------------------------------
    CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => v_items, p_usuario_id => v_admin, p_mesa => '1',
         p_pedido_id => v_p1, p_codigo => v_c1);
    CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => v_items, p_usuario_id => v_admin, p_mesa => '1',
         p_pedido_id => v_p2, p_codigo => v_c2);
    ASSERT v_p1 <> v_p2, 'Sin clave no hay candado: tienen que ser dos facturas';
    RAISE NOTICE '✔ 4  Un envío sin clave se comporta como siempre: nada de lo viejo se rompe';

    -- 5 · LA CLAVE ES DE CADA EMPRESA --------------------------------------------------
    INSERT INTO core.empresas (codigo, nombre_comercial) VALUES ('empresa_dup', 'Duplicados') RETURNING id INTO v_emp2;
    INSERT INTO core.empresa_modulos (empresa_id, modulo_id, activo) SELECT v_emp2, id, TRUE FROM core.modulos;
    INSERT INTO core.consecutivos (empresa_id, tipo, ultimo_numero, digitos) VALUES (v_emp2, 'pedido', 0, 5);
    INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo)
    SELECT v_emp2, id, TRUE FROM core.metodos_pago WHERE codigo = 'efectivo';
    INSERT INTO core.unidades (empresa_id, tipo_negocio_id, nombre, nombre_corto)
    VALUES (v_emp2, (SELECT id FROM core.tipos_negocio ORDER BY id LIMIT 1), 'Dup · Sede', 'Dup')
    RETURNING id INTO v_uni2;
    INSERT INTO core.mesas (unidad_id, numero) VALUES (v_uni2, '1');
    INSERT INTO core.categorias (empresa_id, nombre) VALUES (v_emp2, 'Platos') RETURNING id INTO v_cat2;
    INSERT INTO core.productos (empresa_id, categoria_id, codigo, nombre, precio)
    VALUES (v_emp2, v_cat2, 'DUP-1', 'Plato', 10000) RETURNING id INTO v_prod2;
    INSERT INTO core.producto_unidades (producto_id, unidad_id) VALUES (v_prod2, v_uni2);
    INSERT INTO core.usuarios (empresa_id, rol_id, nombre, usuario, pin_hash)
    VALUES (v_emp2, (SELECT id FROM core.roles WHERE codigo = 'admin'), 'Admin Dup', 'dup.admin', core.fn_hash_pin('1111'))
    RETURNING id INTO v_adm2;

    CALL api.sp_crear_pedido(p_unidad_id => v_uni2, p_tipo => 'mesa', p_metodo_pago => 'efectivo',
         p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod2, 'cantidad', 1)),
         p_usuario_id => v_adm2, p_mesa => '1',
         p_clave => 'envio-de-prueba-1', p_pedido_id => v_po, p_codigo => v_co);

    ASSERT v_po IS NOT NULL, 'La misma clave en otra empresa tiene que crear su pedido';
    SELECT count(*) INTO v_n FROM core.pedidos WHERE clave_envio = 'envio-de-prueba-1';
    ASSERT v_n = 2, format('Se esperaban 2 facturas (una por empresa) y hay %s', v_n);
    RAISE NOTICE '✔ 5  La clave es de cada empresa: la misma en otra empresa crea su propia factura';
END;
$$;

ROLLBACK;
