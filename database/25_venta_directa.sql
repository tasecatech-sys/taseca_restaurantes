/* ============================================================================
   TASECA · 25 · VENTA DIRECTA (MOSTRADOR)
   ----------------------------------------------------------------------------
   Lo que pidió el cliente: poder vender en el mostrador sin pasar por el flujo
   de siempre, pero sin perder el flujo cuando hace falta.

     · Una gaseosa, un empaquetado, un postre de vitrina → se cobra y se
       entrega. No tiene por qué pasar por cocina ni esperar a nadie.
     · Una hamburguesa pedida en el mostrador → se cobra igual, pero va a
       cocina como cualquier pedido y el cliente espera.

   QUIÉN DECIDE CUÁL ES CUÁL
     El PRODUCTO, no quien vende: cada plato de la carta lleva
     `requiere_preparacion`. Se configura una vez y el cajero no tiene que
     acordarse en cada venta. Por defecto es TRUE, así que todo lo que ya
     existe sigue comportándose igual que hoy.

     Una misma venta puede llevar de los dos: si algo hay que prepararlo, la
     factura entera entra al flujo; si no, nace entregada.

   EL COBRO
     Una venta directa nace COBRADA, con el método que elija el cajero. No
     contradice la regla de que los pagos se confirman en caja: es que aquí
     quien vende ES la caja, de cara al cliente. Por eso exige el permiso
     `pagos`, y el cobro se registra por la puerta de siempre
     (api.sp_actualizar_pago), que valida el método, deja constancia de quién
     cobró y lo escribe en el historial.

   No toca pedidos, ventas ni pagos anteriores. Se puede ejecutar más de una
   vez sin efectos.
   Requiere: 00 … 23 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. MODELO
   ============================================================================ */

ALTER TABLE core.productos ADD COLUMN IF NOT EXISTS requiere_preparacion BOOLEAN NOT NULL DEFAULT TRUE;
COMMENT ON COLUMN core.productos.requiere_preparacion IS
    'FALSE = se entrega en el acto (bebidas, empaquetados). TRUE = pasa por cocina. Por defecto TRUE.';

-- El tercer tipo de pedido, junto a mesa y domicilio
INSERT INTO core.tipos_pedido (codigo, nombre)
SELECT 'mostrador', 'Venta directa'
 WHERE NOT EXISTS (SELECT 1 FROM core.tipos_pedido WHERE codigo = 'mostrador');


/* ============================================================================
   2. UNA VENTA DIRECTA NO TIENE MESA, NI ZONA, NI DOMICILIO
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_pedidos_antes_insertar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_tipo    VARCHAR;
    v_empresa INTEGER;
BEGIN
    PERFORM core.fn_exigir_unidad_operativa(NEW.unidad_id);   -- inactiva = sin pedidos nuevos
    v_empresa := core.fn_empresa_de_unidad(NEW.unidad_id);

    IF NEW.empresa_id IS NULL THEN
        NEW.empresa_id := v_empresa;
    ELSIF NEW.empresa_id <> v_empresa THEN
        RAISE EXCEPTION 'La unidad % no pertenece a la empresa %.', NEW.unidad_id, NEW.empresa_id;
    END IF;

    NEW.codigo           := COALESCE(NEW.codigo, core.fn_siguiente_codigo_pedido(NEW.empresa_id));
    NEW.fecha_operativa  := COALESCE(NEW.fecha_operativa, core.fn_fecha_operativa(NEW.empresa_id, now()));
    NEW.estado_pedido_id := COALESCE(NEW.estado_pedido_id, core.fn_id_catalogo('estados_pedido', 'nuevo'));
    NEW.estado_pago_id   := COALESCE(NEW.estado_pago_id,   core.fn_id_catalogo('estados_pago', 'pendiente'));

    SELECT codigo INTO v_tipo FROM core.tipos_pedido WHERE id = NEW.tipo_pedido_id;

    /* Venta directa (mostrador): se cobra y se entrega en el acto, así que
       no tiene mesa, ni zona, ni domicilio. El cliente es opcional: quien
       compra una gaseosa en la barra no deja sus datos. */
    IF v_tipo = 'mostrador' THEN
        NEW.mesa_id           := NULL;
        NEW.zona_domicilio_id := NULL;
        NEW.costo_domicilio   := 0;
    ELSIF v_tipo = 'mesa' THEN
        IF NEW.mesa_id IS NULL THEN
            RAISE EXCEPTION 'Un pedido de mesa necesita la mesa.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM core.mesas WHERE id = NEW.mesa_id AND unidad_id = NEW.unidad_id) THEN
            RAISE EXCEPTION 'La mesa % no es de la unidad %.', NEW.mesa_id, NEW.unidad_id;
        END IF;
        NEW.zona_domicilio_id := NULL;
        NEW.costo_domicilio   := 0;
    ELSIF v_tipo = 'domicilio' THEN
        IF NEW.cliente_id IS NULL OR NEW.direccion_entrega IS NULL OR length(trim(NEW.direccion_entrega)) < 8 THEN
            RAISE EXCEPTION 'Un domicilio necesita cliente y dirección completa.';
        END IF;
        NEW.mesa_id := NULL;

        -- Zona: obligatoria sólo si la unidad tiene zonas activas
        IF NEW.zona_domicilio_id IS NULL THEN
            IF EXISTS (SELECT 1 FROM core.zonas_domicilio WHERE unidad_id = NEW.unidad_id AND activa) THEN
                RAISE EXCEPTION 'Selecciona la zona de entrega.';
            END IF;
            NEW.costo_domicilio := 0;
        ELSE
            SELECT z.costo INTO NEW.costo_domicilio
              FROM core.zonas_domicilio z
             WHERE z.id = NEW.zona_domicilio_id AND z.unidad_id = NEW.unidad_id AND z.activa;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'La zona % no es una zona activa de la unidad %.', NEW.zona_domicilio_id, NEW.unidad_id;
            END IF;
        END IF;
    END IF;

    IF NEW.cliente_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM core.clientes WHERE id = NEW.cliente_id AND empresa_id = NEW.empresa_id) THEN
        RAISE EXCEPTION 'El cliente no es de esta empresa.';
    END IF;

    RETURN NEW;
END;
$$;

/* ============================================================================
   3. LA CARTA DICE QUÉ SE PREPARA Y QUÉ NO

   Columna nueva al final: CREATE OR REPLACE VIEW sólo deja añadir.
   ============================================================================ */

CREATE OR REPLACE VIEW rest.carta AS
SELECT p.id AS producto_id, p.empresa_id, p.codigo, p.categoria_id, p.nombre, p.descripcion, p.precio,
       et.codigo AS etiqueta, p.imagen_url, p.orden, p.activo,
       COALESCE(jsonb_agg(jsonb_build_object('unidad_id', pu.unidad_id, 'agotado', pu.agotado)
                          ORDER BY pu.unidad_id) FILTER (WHERE pu.id IS NOT NULL), '[]') AS unidades,
       p.requiere_preparacion
  FROM core.productos p
  LEFT JOIN core.etiquetas_producto et ON et.id = p.etiqueta_id
  LEFT JOIN core.producto_unidades pu  ON pu.producto_id = p.id
 GROUP BY p.id, et.codigo;


/* ============================================================================
   4. GUARDAR UN PRODUCTO, CON SU MARCA

   Se borra la firma anterior para no dejar dos conviviendo: todos los que la
   llaman usan parámetros por nombre.
   ============================================================================ */

DROP PROCEDURE IF EXISTS api.sp_guardar_producto(INTEGER, INTEGER, VARCHAR, VARCHAR, NUMERIC, INTEGER[],
                                                 INTEGER, VARCHAR, VARCHAR, BOOLEAN, INTEGER, VARCHAR, INTEGER);

CREATE OR REPLACE PROCEDURE api.sp_guardar_producto(
    p_empresa_id    INTEGER,
    p_categoria_id  INTEGER,
    p_codigo        VARCHAR,
    p_nombre        VARCHAR,
    p_precio        NUMERIC,
    p_unidades      INTEGER[],
    p_usuario_id    INTEGER,
    p_descripcion   VARCHAR DEFAULT NULL,
    p_etiqueta      VARCHAR DEFAULT NULL,
    p_activo        BOOLEAN DEFAULT TRUE,
    p_orden         INTEGER DEFAULT NULL,
    p_imagen_url    VARCHAR DEFAULT NULL,
    p_requiere_preparacion BOOLEAN DEFAULT NULL,
    INOUT p_producto_id INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_etiqueta INTEGER := CASE WHEN NULLIF(trim(p_etiqueta), '') IS NULL THEN NULL
                               ELSE core.fn_id_catalogo('etiquetas_producto', trim(p_etiqueta)) END;
    v_codigo   VARCHAR := NULLIF(upper(trim(COALESCE(p_codigo, ''))), '');
    v_nombre   VARCHAR := trim(COALESCE(p_nombre, ''));
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'carta');
    PERFORM core.fn_exigir_unidades(p_usuario_id, p_empresa_id, p_unidades);

    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'El producto necesita un nombre.';
    END IF;
    IF p_precio IS NULL OR p_precio < 0 THEN
        RAISE EXCEPTION 'El precio de "%" no es válido.', v_nombre;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM core.categorias WHERE id = p_categoria_id AND empresa_id = p_empresa_id) THEN
        RAISE EXCEPTION 'El producto "%" necesita una categoría de esta empresa.', v_nombre;
    END IF;
    IF v_codigo IS NOT NULL AND EXISTS (SELECT 1 FROM core.productos
                                         WHERE empresa_id = p_empresa_id AND codigo = v_codigo
                                           AND id IS DISTINCT FROM p_producto_id) THEN
        RAISE EXCEPTION 'Ya hay otro producto con el código %.', v_codigo;
    END IF;

    IF p_producto_id IS NULL THEN
        INSERT INTO core.productos (empresa_id, categoria_id, etiqueta_id, codigo, nombre, descripcion,
                                    precio, imagen_url, activo, orden, requiere_preparacion)
        VALUES (p_empresa_id, p_categoria_id, v_etiqueta,
                COALESCE(v_codigo, 'TMP-' || left(md5(random()::TEXT || clock_timestamp()::TEXT), 24)),
                v_nombre, NULLIF(trim(p_descripcion), ''), p_precio, NULLIF(trim(p_imagen_url), ''),
                COALESCE(p_activo, TRUE),
                COALESCE(p_orden, (SELECT COALESCE(max(orden), 0) + 10 FROM core.productos WHERE empresa_id = p_empresa_id)),
                COALESCE(p_requiere_preparacion, TRUE))
        RETURNING id INTO p_producto_id;

        IF v_codigo IS NULL THEN
            UPDATE core.productos SET codigo = 'P' || lpad(p_producto_id::TEXT, 4, '0') WHERE id = p_producto_id;
        END IF;
    ELSE
        UPDATE core.productos
           SET categoria_id = p_categoria_id, etiqueta_id = v_etiqueta, codigo = COALESCE(v_codigo, codigo),
               nombre = v_nombre, descripcion = NULLIF(trim(p_descripcion), ''), precio = p_precio,
               imagen_url = NULLIF(trim(p_imagen_url), ''), activo = COALESCE(p_activo, activo),
               orden = COALESCE(p_orden, orden),
               requiere_preparacion = COALESCE(p_requiere_preparacion, requiere_preparacion)
         WHERE id = p_producto_id AND empresa_id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese producto ya no existe. Recarga la página.';
        END IF;
    END IF;

    DELETE FROM core.producto_unidades
     WHERE producto_id = p_producto_id
       AND unidad_id <> ALL (p_unidades)
       AND core.fn_usuario_en_unidad(p_usuario_id, unidad_id);
    INSERT INTO core.producto_unidades (producto_id, unidad_id)
    SELECT p_producto_id, x FROM unnest(p_unidades) x
    ON CONFLICT (producto_id, unidad_id) DO NOTHING;
END;
$$;

/* ============================================================================
   5. CREAR LA VENTA
   ============================================================================ */

DROP PROCEDURE IF EXISTS api.sp_crear_pedido(INTEGER, VARCHAR, VARCHAR, JSONB, INTEGER, VARCHAR, VARCHAR,
                                             VARCHAR, VARCHAR, VARCHAR, INTEGER, NUMERIC, VARCHAR, BIGINT, VARCHAR);

CREATE OR REPLACE PROCEDURE api.sp_crear_pedido(
    p_unidad_id         INTEGER,
    p_tipo              VARCHAR,
    p_metodo_pago       VARCHAR,
    p_items             JSONB,
    p_usuario_id        INTEGER DEFAULT NULL,
    p_mesa              VARCHAR DEFAULT NULL,
    p_cliente_nombre    VARCHAR DEFAULT NULL,
    p_cliente_telefono  VARCHAR DEFAULT NULL,
    p_direccion         VARCHAR DEFAULT NULL,
    p_indicaciones      VARCHAR DEFAULT NULL,
    p_zona_id           INTEGER DEFAULT NULL,
    p_paga_con          NUMERIC DEFAULT NULL,
    p_clave             VARCHAR DEFAULT NULL,
    INOUT p_pedido_id   BIGINT  DEFAULT NULL,
    INOUT p_codigo      VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_empresa   INTEGER := core.fn_empresa_de_unidad(p_unidad_id);
    v_metodo    INTEGER := core.fn_id_catalogo('metodos_pago', p_metodo_pago);
    v_tipo      INTEGER := core.fn_id_catalogo('tipos_pedido', p_tipo);
    v_cliente   BIGINT;
    v_mesa      INTEGER;
    v_linea     JSONB;
    v_item      BIGINT;
    v_minimo    NUMERIC;
    v_falta     TEXT;
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    END IF;

    /* ¿Este mismo envío ya entró? Entonces no es un pedido nuevo: es el
       mismo toque que llegó dos veces -el mesero tocó otra vez porque la
       pantalla se quedó pensando, o se recargó la página-. Se devuelve el
       que ya existe y no se crea ninguno. */
    IF p_clave IS NOT NULL THEN
        SELECT id, codigo INTO p_pedido_id, p_codigo
          FROM core.pedidos
         WHERE empresa_id = v_empresa AND clave_envio = p_clave;
        IF FOUND THEN
            RETURN;
        END IF;
    END IF;

    PERFORM core.fn_preparar_operacion(p_usuario_id, NULL, p_unidad_id);
    IF p_tipo = 'mostrador' THEN
        /* Una venta directa nace COBRADA, y eso sólo lo hace quien está en
           caja. No es una excepción a «los pagos se confirman en caja»: es
           que aquí quien vende ES la caja, de cara al cliente. */
        IF p_usuario_id IS NULL THEN
            RAISE EXCEPTION 'Una venta directa la registra quien está en caja: hace falta iniciar sesión.';
        END IF;
        PERFORM core.fn_exigir_permiso(p_usuario_id, 'pagos');
    ELSIF p_usuario_id IS NOT NULL THEN
        PERFORM core.fn_exigir_alguno(p_usuario_id, ARRAY['pedidos_mesa', 'pedidos_gestionar']);
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'El pedido está vacío.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago
                    WHERE empresa_id = v_empresa AND metodo_pago_id = v_metodo AND activo) THEN
        RAISE EXCEPTION 'El método de pago "%" no está disponible.', p_metodo_pago;
    END IF;

    IF p_tipo = 'domicilio' THEN
        IF length(trim(COALESCE(p_cliente_nombre, ''))) < 3 THEN
            RAISE EXCEPTION 'Escribe tu nombre completo.';
        END IF;
        IF regexp_replace(COALESCE(p_cliente_telefono, ''), '\D', '', 'g') !~ '^[0-9]{7,10}$' THEN
            RAISE EXCEPTION 'El celular debe tener entre 7 y 10 dígitos.';
        END IF;
        INSERT INTO core.clientes (empresa_id, nombre, telefono)
        VALUES (v_empresa, trim(p_cliente_nombre), regexp_replace(p_cliente_telefono, '\D', '', 'g'))
        ON CONFLICT (empresa_id, telefono) DO UPDATE SET nombre = EXCLUDED.nombre
        RETURNING id INTO v_cliente;
    ELSIF p_tipo = 'mesa' THEN
        SELECT id INTO v_mesa FROM core.mesas
         WHERE unidad_id = p_unidad_id AND numero = trim(p_mesa) AND activa;
        IF v_mesa IS NULL THEN
            RAISE EXCEPTION 'La mesa "%" no existe en esta unidad.', p_mesa;
        END IF;
    END IF;

    BEGIN
        INSERT INTO core.pedidos (unidad_id, tipo_pedido_id, metodo_pago_id, mesa_id, cliente_id,
                                  zona_domicilio_id, direccion_entrega, indicaciones, paga_con, tomado_por_id,
                                  clave_envio)
        VALUES (p_unidad_id, v_tipo, v_metodo, v_mesa, v_cliente, p_zona_id,
                NULLIF(trim(p_direccion), ''), NULLIF(trim(p_indicaciones), ''), p_paga_con, p_usuario_id,
                p_clave)
        RETURNING id, codigo INTO p_pedido_id, p_codigo;
    EXCEPTION WHEN unique_violation THEN
        /* Dos envíos idénticos a la vez: uno entró primero. El segundo se
           lleva el mismo pedido, no un error ni una factura repetida. */
        SELECT id, codigo INTO p_pedido_id, p_codigo
          FROM core.pedidos
         WHERE empresa_id = v_empresa AND clave_envio = p_clave;
        IF FOUND THEN
            RETURN;
        END IF;
        RAISE;   -- era otra cosa (el consecutivo, por ejemplo)
    END;

    FOR v_linea IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        INSERT INTO core.pedido_items (pedido_id, producto_id, plato_dia_id, menu_dia_id, cantidad, notas)
        VALUES (p_pedido_id,
                (v_linea ->> 'producto_id')::INTEGER,
                (v_linea ->> 'plato_dia_id')::BIGINT,
                (v_linea ->> 'menu_dia_id')::BIGINT,
                COALESCE((v_linea ->> 'cantidad')::INTEGER, 1),
                NULLIF(trim(v_linea ->> 'notas'), ''))
        RETURNING id INTO v_item;

        IF v_linea ? 'menu_dia_id' THEN
            INSERT INTO core.pedido_item_opciones (pedido_item_id, menu_opcion_id)
            SELECT v_item, x::BIGINT FROM jsonb_array_elements_text(COALESCE(v_linea -> 'opciones', '[]')) x;

            -- Toda categoría obligatoria con opciones activas debe tener al menos una elegida
            SELECT string_agg(c.nombre, ', ' ORDER BY c.orden) INTO v_falta
              FROM core.menu_categorias c
             WHERE c.menu_dia_id = (v_linea ->> 'menu_dia_id')::BIGINT
               AND c.activa AND c.obligatoria
               AND EXISTS (SELECT 1 FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id AND o.activa)
               AND NOT EXISTS (SELECT 1 FROM core.pedido_item_opciones x
                                 JOIN core.menu_opciones o ON o.id = x.menu_opcion_id
                                WHERE x.pedido_item_id = v_item AND o.menu_categoria_id = c.id);
            IF v_falta IS NOT NULL THEN
                RAISE EXCEPTION 'Te falta elegir: %.', v_falta;
            END IF;
        END IF;
    END LOOP;

    SELECT pedido_minimo INTO v_minimo FROM core.zonas_domicilio WHERE id = p_zona_id;
    IF v_minimo IS NOT NULL AND core.fn_subtotal_pedido(p_pedido_id) < v_minimo THEN
        RAISE EXCEPTION 'El pedido mínimo para esta zona es %.', v_minimo;
    END IF;

    /* ---- VENTA DIRECTA: lo que la distingue de un pedido normal ----------
       1. Si NADA de lo que lleva hay que prepararlo -una gaseosa, un
          empaquetado- la venta nace ENTREGADA: no tiene por qué pasar por
          cocina ni esperar a nadie.
       2. Si algo sí hay que prepararlo, queda como un pedido cualquiera y
          la cocina lo ve. El cliente ya pagó y espera.
       3. En los dos casos el cobro se registra en el acto, por la puerta de
          siempre (api.sp_actualizar_pago), que valida el método, deja quién
          cobró y lo escribe en el historial.
       El orden importa: primero entregar y después cobrar. Al revés, el
       propio candado de «un pago confirmado no cambia» bloquearía el paso. */
    IF p_tipo = 'mostrador' THEN
        IF NOT EXISTS (
            SELECT 1 FROM core.pedido_items i
              JOIN core.productos pr ON pr.id = i.producto_id
             WHERE i.pedido_id = p_pedido_id AND pr.requiere_preparacion
        ) AND NOT EXISTS (
            -- Los platos del día y los menús armados siempre se preparan
            SELECT 1 FROM core.pedido_items i
             WHERE i.pedido_id = p_pedido_id
               AND (i.plato_dia_id IS NOT NULL OR i.menu_dia_id IS NOT NULL)
        ) THEN
            UPDATE core.pedidos
               SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'entregado')
             WHERE id = p_pedido_id;
        END IF;

        CALL api.sp_actualizar_pago(p_pedido_id, 'confirmado', p_usuario_id, NULL, p_metodo_pago);
    END IF;
END;
$$;

/* ============================================================================
   6. REVISIÓN
   ============================================================================ */

DO $$
DECLARE
    v_col BOOLEAN;
    v_tipo BOOLEAN;
    v_n INTEGER;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'core.productos'::regclass
                      AND attname = 'requiere_preparacion' AND NOT attisdropped) INTO v_col;
    SELECT EXISTS (SELECT 1 FROM core.tipos_pedido WHERE codigo = 'mostrador') INTO v_tipo;
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname IN ('sp_crear_pedido', 'sp_guardar_producto');

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE 'Marca requiere_preparacion ......... %', CASE WHEN v_col THEN 'sí' ELSE 'NO' END;
    RAISE NOTICE 'Tipo de pedido «mostrador» ......... %', CASE WHEN v_tipo THEN 'sí' ELSE 'NO' END;
    RAISE NOTICE 'Procedimientos (tienen que ser 2) .. %', v_n;
    RAISE NOTICE '--------------------------------------------------';

    IF NOT v_col OR NOT v_tipo THEN
        RAISE EXCEPTION 'La venta directa no quedó instalada: revisa el paso 1.';
    END IF;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'Quedaron % versiones de los procedimientos: la API no sabría cuál llamar.', v_n;
    END IF;
END;
$$;
