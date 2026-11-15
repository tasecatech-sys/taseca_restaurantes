/* ============================================================================
   TASECA · PRUEBA DE HUMO DE UNA INSTALACIÓN RECIÉN HECHA
   ----------------------------------------------------------------------------
   Cinco cosas que tienen que funcionar en cuanto la base está puesta. No
   comprueba que las tablas existan -eso ya lo dice el propio instalador al
   final- sino que el camino de un pedido FUNCIONA de verdad.

   Qué prueba, y por qué justamente eso: son los cinco fallos que ya se
   escaparon una vez a producción.

     1. Un pedido con un método de pago SIN recargo. Devolvía NULL en una
        columna NOT NULL y no se podía crear ningún pedido (migración 33).
     2. El mismo envío dos veces no duplica el pedido (migración 23).
     3. Un pedido para recoger (migración 32).
     4. El doble clic al avanzar no salta un estado (migración 35).
     5. Un pedido para recoger nunca pasa por «en camino».

   CÓMO CORRERLO

     Sobre la base que acabas de instalar:

         psql "<tu cadena de conexión>" -v ON_ERROR_STOP=1               -f database/PRUEBAS_INSTALACION.sql

     Tiene que salir «LAS 5 PRUEBAS PASARON» y ningún ERROR.

   OJO: ESTO SÍ ESCRIBE

     Crea dos pedidos de prueba y los deja. Es a propósito -así se puede
     mirar el tablero después- pero NO lo corras sobre una base con datos
     reales de un cliente.

   PROBARLO SIN SUPABASE, EN TU COMPUTADOR

     Con Docker, sobre un PostgreSQL limpio:

         docker run -d --name taseca-prueba -e POSTGRES_PASSWORD=prueba                 -e POSTGRES_DB=taseca_db postgres:16
         docker cp database/ANDAMIO_PRUEBA_LOCAL.sql taseca-prueba:/tmp/
         docker cp database/SUPABASE_INSTALAR.sql    taseca-prueba:/tmp/
         docker cp database/PRUEBAS_INSTALACION.sql  taseca-prueba:/tmp/
         docker exec taseca-prueba psql -U postgres -d taseca_db -v ON_ERROR_STOP=1                 -f /tmp/ANDAMIO_PRUEBA_LOCAL.sql
         docker exec taseca-prueba psql -U postgres -d taseca_db -v ON_ERROR_STOP=1                 -f /tmp/SUPABASE_INSTALAR.sql
         docker exec taseca-prueba psql -U postgres -d taseca_db -v ON_ERROR_STOP=1                 -f /tmp/PRUEBAS_INSTALACION.sql
         docker rm -f taseca-prueba

     El ANDAMIO monta lo que Supabase pone y un PostgreSQL pelado no: el
     esquema `storage` y los roles. Está explicado en ese archivo.

     En Git Bash, pon MSYS_NO_PATHCONV=1 delante o convierte /tmp a una
     ruta de Windows y no encuentra nada.
   ============================================================================ */

DO $$
DECLARE
  v_unidad INT; v_prod INT; v_usuario INT; v_id BIGINT; v_cod VARCHAR;
  v_estado TEXT; v_fallo TEXT; v_rec NUMERIC;
BEGIN
  -- La unidad y el producto TIENEN que casar: cada producto se vende solo
  -- en las unidades que lo tengan asignado.
  SELECT pu.unidad_id, pu.producto_id INTO v_unidad, v_prod
    FROM core.producto_unidades pu
    JOIN core.productos pr ON pr.id = pu.producto_id
   WHERE pr.precio > 0 AND pr.activo
   ORDER BY pu.unidad_id, pu.producto_id LIMIT 1;
  SELECT us.id INTO v_usuario FROM core.usuarios us JOIN core.roles r ON r.id = us.rol_id
   WHERE r.codigo = 'admin' AND us.activo ORDER BY us.id LIMIT 1;

  -- 1 - un domicilio en efectivo: metodo SIN recargo, que es el fallo de la 33
  CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
      p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2)),
      p_cliente_nombre => 'Prueba Instalador', p_cliente_telefono => '3001234567',
      p_direccion => 'Cra 1 # 2-3', p_clave => 'inst-1', p_pedido_id => v_id, p_codigo => v_cod);
  SELECT recargo_pago INTO v_rec FROM core.pedidos WHERE id = v_id;
  IF v_rec IS NULL THEN RAISE EXCEPTION '1 - recargo_pago quedo NULL: falta el arreglo de la 33'; END IF;
  RAISE NOTICE '1 - OK  pedido % con metodo sin recargo, recargo_pago=%', v_cod, v_rec;

  -- 2 - el mismo envio otra vez no debe duplicar
  CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'domicilio', p_metodo_pago => 'efectivo',
      p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2)),
      p_cliente_nombre => 'Prueba Instalador', p_cliente_telefono => '3001234567',
      p_direccion => 'Cra 1 # 2-3', p_clave => 'inst-1', p_pedido_id => v_id, p_codigo => v_cod);
  IF (SELECT count(*) FROM core.pedidos WHERE clave_envio = 'inst-1') <> 1 THEN
    RAISE EXCEPTION '2 - el mismo envio creo dos pedidos'; END IF;
  RAISE NOTICE '2 - OK  el mismo envio no duplica';

  -- 3 - un pedido para recoger
  CALL api.sp_crear_pedido(p_unidad_id => v_unidad, p_tipo => 'recoger', p_metodo_pago => 'nequi',
      p_items => jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)),
      p_cliente_nombre => 'Recoge Prueba', p_cliente_telefono => '3009998877',
      p_clave => 'inst-2', p_pedido_id => v_id, p_codigo => v_cod);
  RAISE NOTICE '3 - OK  pedido para recoger % creado', v_cod;

  -- 4 - doble clic al avanzar
  CALL api.sp_avanzar_estado_pedido(v_id, v_usuario, 'nuevo');
  BEGIN
    CALL api.sp_avanzar_estado_pedido(v_id, v_usuario, 'nuevo');
    v_fallo := NULL;
  EXCEPTION WHEN OTHERS THEN v_fallo := SQLERRM; END;
  SELECT e.codigo INTO v_estado FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id WHERE p.id = v_id;
  IF v_fallo IS NULL OR v_estado <> 'preparacion' THEN
    RAISE EXCEPTION '4 - el doble clic paso: quedo en %', v_estado; END IF;
  RAISE NOTICE '4 - OK  doble clic rechazado, sigue en %', v_estado;
  RAISE NOTICE '    aviso: %', v_fallo;

  -- 5 - recorrido completo del que recoge: nunca pasa por "en camino"
  LOOP
    BEGIN CALL api.sp_avanzar_estado_pedido(v_id, v_usuario); EXCEPTION WHEN OTHERS THEN EXIT; END;
    SELECT e.codigo INTO v_estado FROM core.pedidos p JOIN core.estados_pedido e ON e.id = p.estado_pedido_id WHERE p.id = v_id;
    IF v_estado = 'camino' THEN RAISE EXCEPTION '5 - un pedido para recoger paso por en camino'; END IF;
    EXIT WHEN v_estado = 'entregado';
  END LOOP;
  RAISE NOTICE '5 - OK  recoger llega a % sin pasar por en camino', v_estado;

  RAISE NOTICE '================ LAS 5 PRUEBAS PASARON ================';
END $$;
