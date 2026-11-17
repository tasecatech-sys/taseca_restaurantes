/* ============================================================================
   40 · PRUEBAS · EL RECARGO SIGUE AL MÉTODO

   Va APARTE de la migración a propósito: el editor SQL de Supabase ejecuta
   todo el archivo en UNA transacción, así que una prueba que se deshaga a
   sí misma se llevaría por delante el procedimiento recién instalado.

   CÓMO CORRERLO

       psql "<tu cadena de conexión>" -v ON_ERROR_STOP=1             -f database/40_pruebas_recargo.sql

   Tiene que salir «LAS 4 PRUEBAS PASARON».

   Sobre una base SIN la migración 40 fallan A y B: así se ve el fallo que
   se vino a arreglar.

   OJO: ESTO SÍ ESCRIBE

   Crea cuatro pedidos de prueba y los deja cobrados, y pone el recargo de
   Nequi en $500 para esa empresa. NO lo corras sobre la base de un cliente
   con datos reales.
   ============================================================================ */
DO $$
DECLARE
  v_unidad INT; v_prod INT; v_usuario INT; v_emp INT;
  v_id BIGINT; v_cod VARCHAR;
  v_rec_antes NUMERIC; v_rec_despues NUMERIC;
  v_total_antes NUMERIC; v_total_despues NUMERIC;
  v_metodo TEXT; v_fallos INT := 0;
  r RECORD;
BEGIN
  SELECT pu.unidad_id, pu.producto_id INTO v_unidad, v_prod
    FROM core.producto_unidades pu JOIN core.productos pr ON pr.id = pu.producto_id
   WHERE pr.precio > 0 AND pr.activo ORDER BY pu.unidad_id, pu.producto_id LIMIT 1;
  SELECT us.id INTO v_usuario FROM core.usuarios us JOIN core.roles r2 ON r2.id = us.rol_id
   WHERE r2.codigo = 'admin' AND us.activo ORDER BY us.id LIMIT 1;
  SELECT empresa_id INTO v_emp FROM core.unidades WHERE id = v_unidad;

  /* Como en producción: Nequi recarga $500, efectivo no recarga. */
  UPDATE core.empresa_metodos_pago SET recargo = 500, recargo_tipo = 'fijo', activo = TRUE
   WHERE empresa_id = v_emp AND metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'nequi');
  UPDATE core.empresa_metodos_pago SET recargo = 0, activo = TRUE
   WHERE empresa_id = v_emp AND metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'efectivo');

  /* ---------------------------------------------------------------- A
     Entra como NEQUI (+500) y el cliente paga en EFECTIVO.
     Lo que debe pasar: el total baja 500.
     ---------------------------------------------------------------- */
  CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'domicilio', p_metodo_pago => 'nequi',
      p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2)),
      p_cliente_nombre => 'Recargo A', p_cliente_telefono => '3001110000',
      p_direccion => 'Cra 9 # 9-9', p_clave => 'recA-' || clock_timestamp()::TEXT,
      p_pedido_id => v_id, p_codigo => v_cod);
  UPDATE core.pedidos p SET recargo_pago = core.fn_recargo_pago(p.empresa_id, p.metodo_pago_id,
             COALESCE((SELECT SUM(i.precio_unitario * i.cantidad) FROM core.pedido_items i
                        WHERE i.pedido_id = p.id), 0) + p.costo_domicilio)
   WHERE p.id = v_id;

  SELECT recargo_pago INTO v_rec_antes FROM core.pedidos WHERE id = v_id;
  SELECT total INTO v_total_antes FROM api.v_pedidos WHERE pedido_id = v_id;
  RAISE NOTICE 'A · pedido % entra como NEQUI    · recargo=% · total=%', v_cod, v_rec_antes, v_total_antes;

  IF v_rec_antes <> 500 THEN
    RAISE EXCEPTION 'A · la prueba no sirve: el pedido no nació con los 500 de Nequi (nació con %)', v_rec_antes;
  END IF;

  CALL api.sp_actualizar_pago(v_id, 'confirmado', v_usuario, NULL, 'efectivo');

  SELECT recargo_pago INTO v_rec_despues FROM core.pedidos WHERE id = v_id;
  SELECT total, metodo_pago INTO v_total_despues, v_metodo FROM api.v_pedidos WHERE pedido_id = v_id;
  RAISE NOTICE 'A · se cobra en %         · recargo=% · total=%', v_metodo, v_rec_despues, v_total_despues;

  IF v_rec_despues = 0 AND v_total_despues = v_total_antes - 500 THEN
    RAISE NOTICE 'A · BIEN  el recargo de Nequi se quitó.';
  ELSE
    v_fallos := v_fallos + 1;
    RAISE NOTICE 'A · FALLO al cliente se le cobran % de Nequi que no debe.', v_rec_despues;
  END IF;

  /* ---------------------------------------------------------------- B
     Al revés: entra como EFECTIVO (sin recargo) y paga por NEQUI.
     Lo que debe pasar: el total sube 500, o el negocio los pierde.
     ---------------------------------------------------------------- */
  CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
      p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2)),
      p_cliente_nombre => 'Recargo B', p_cliente_telefono => '3002220000',
      p_direccion => 'Cra 8 # 8-8', p_clave => 'recB-' || clock_timestamp()::TEXT,
      p_pedido_id => v_id, p_codigo => v_cod);
  UPDATE core.pedidos p SET recargo_pago = core.fn_recargo_pago(p.empresa_id, p.metodo_pago_id,
             COALESCE((SELECT SUM(i.precio_unitario * i.cantidad) FROM core.pedido_items i
                        WHERE i.pedido_id = p.id), 0) + p.costo_domicilio)
   WHERE p.id = v_id;

  SELECT total INTO v_total_antes FROM api.v_pedidos WHERE pedido_id = v_id;
  RAISE NOTICE 'B · pedido % entra como EFECTIVO · total=%', v_cod, v_total_antes;

  CALL api.sp_actualizar_pago(v_id, 'confirmado', v_usuario, NULL, 'nequi');

  SELECT recargo_pago INTO v_rec_despues FROM core.pedidos WHERE id = v_id;
  SELECT total, metodo_pago INTO v_total_despues, v_metodo FROM api.v_pedidos WHERE pedido_id = v_id;
  RAISE NOTICE 'B · se cobra en %             · recargo=% · total=%', v_metodo, v_rec_despues, v_total_despues;

  IF v_rec_despues = 500 AND v_total_despues = v_total_antes + 500 THEN
    RAISE NOTICE 'B · BIEN  el recargo de Nequi se puso.';
  ELSE
    v_fallos := v_fallos + 1;
    RAISE NOTICE 'B · FALLO el negocio paga los 500 de Nequi de su bolsillo.';
  END IF;

  RAISE NOTICE '    historial de %:', v_cod;
  FOR r IN SELECT descripcion FROM core.pedido_historial WHERE pedido_id = v_id ORDER BY id LOOP
    RAISE NOTICE '       · %', r.descripcion;
  END LOOP;

  /* ---------------------------------------------------------------- C
     Confirmar SIN cambiar de método no puede mover una factura.
     ---------------------------------------------------------------- */
  CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'domicilio', p_metodo_pago => 'nequi',
      p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)),
      p_cliente_nombre => 'Recargo C', p_cliente_telefono => '3003330000',
      p_direccion => 'Cra 7 # 7-7', p_clave => 'recC-' || clock_timestamp()::TEXT,
      p_pedido_id => v_id, p_codigo => v_cod);
  UPDATE core.pedidos p SET recargo_pago = core.fn_recargo_pago(p.empresa_id, p.metodo_pago_id,
             COALESCE((SELECT SUM(i.precio_unitario * i.cantidad) FROM core.pedido_items i
                        WHERE i.pedido_id = p.id), 0) + p.costo_domicilio)
   WHERE p.id = v_id;
  SELECT total INTO v_total_antes FROM api.v_pedidos WHERE pedido_id = v_id;

  CALL api.sp_actualizar_pago(v_id, 'confirmado', v_usuario, NULL, 'nequi');
  SELECT total INTO v_total_despues FROM api.v_pedidos WHERE pedido_id = v_id;

  IF v_total_despues = v_total_antes THEN
    RAISE NOTICE 'C · BIEN  confirmar con el mismo método no movió el total (%).', v_total_despues;
  ELSE
    v_fallos := v_fallos + 1;
    RAISE NOTICE 'C · FALLO el total se movió de % a % sin cambiar de método.', v_total_antes, v_total_despues;
  END IF;

  /* ---------------------------------------------------------------- D
     Confirmar sin decir método tampoco.
     ---------------------------------------------------------------- */
  CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'domicilio', p_metodo_pago => 'nequi',
      p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)),
      p_cliente_nombre => 'Recargo D', p_cliente_telefono => '3004440000',
      p_direccion => 'Cra 6 # 6-6', p_clave => 'recD-' || clock_timestamp()::TEXT,
      p_pedido_id => v_id, p_codigo => v_cod);
  UPDATE core.pedidos p SET recargo_pago = core.fn_recargo_pago(p.empresa_id, p.metodo_pago_id,
             COALESCE((SELECT SUM(i.precio_unitario * i.cantidad) FROM core.pedido_items i
                        WHERE i.pedido_id = p.id), 0) + p.costo_domicilio)
   WHERE p.id = v_id;
  SELECT total INTO v_total_antes FROM api.v_pedidos WHERE pedido_id = v_id;

  CALL api.sp_actualizar_pago(v_id, 'confirmado', v_usuario, NULL, NULL);
  SELECT total INTO v_total_despues FROM api.v_pedidos WHERE pedido_id = v_id;

  IF v_total_despues = v_total_antes THEN
    RAISE NOTICE 'D · BIEN  confirmar sin decir método no movió el total (%).', v_total_despues;
  ELSE
    v_fallos := v_fallos + 1;
    RAISE NOTICE 'D · FALLO el total se movió de % a %.', v_total_antes, v_total_despues;
  END IF;

  RAISE NOTICE '=================================================';
  IF v_fallos = 0 THEN
    RAISE NOTICE 'LAS 4 PRUEBAS PASARON';
  ELSE
    RAISE NOTICE '% PRUEBA(S) FALLARON', v_fallos;
  END IF;
END $$;
