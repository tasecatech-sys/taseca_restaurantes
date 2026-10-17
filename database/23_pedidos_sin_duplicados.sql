/* ============================================================================
   TASECA · 23 · UN ENVÍO, UN PEDIDO
   ----------------------------------------------------------------------------
   El cliente reportó pedidos duplicados «por demoras en el botón de pedir».
   Es exactamente eso: las escrituras viajan por XHR síncrono, así que al
   tocar «enviar» la pantalla se queda congelada un segundo o dos. Quien está
   atendiendo cree que no registró, vuelve a tocar, y los toques se encolan:
   entran dos pedidos iguales.

   En la pantalla se arregla con un candado en el botón. Pero eso sólo tapa el
   caso del doble toque: no cubre recargar la página, perder la red a mitad de
   camino ni un reintento del navegador. El candado de verdad va aquí.

   CÓMO FUNCIONA
     Cada ENVÍO lleva una clave que genera la pantalla (no el pedido: el
     envío). Si llega una clave que esta empresa ya usó, la base no crea nada
     y devuelve el pedido que se hizo la primera vez. Para quien atiende, es
     como si hubiera funcionado al primer toque.

     Es opcional: un envío sin clave se comporta como siempre, así que nada
     de lo que ya existe se rompe.

   No toca pedidos, ventas, pagos ni auditoría. Se puede ejecutar más de una
   vez sin efectos.
   Requiere: 00 … 17 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. MODELO
   ============================================================================ */

ALTER TABLE core.pedidos ADD COLUMN IF NOT EXISTS clave_envio VARCHAR(64);
COMMENT ON COLUMN core.pedidos.clave_envio IS
    'Identifica el ENVÍO que creó esta factura. Si llega repetido, se devuelve esta misma factura en vez de crear otra.';

/* Única por empresa, y sólo donde hay clave: los pedidos de siempre -y los
   que entren sin clave- no estorban. */
CREATE UNIQUE INDEX IF NOT EXISTS uq_pedidos_clave_envio
    ON core.pedidos (empresa_id, clave_envio)
 WHERE clave_envio IS NOT NULL;


/* ============================================================================
   2. CREAR UN PEDIDO, UNA SOLA VEZ

   Se borra la firma anterior para no dejar dos versiones conviviendo: todos
   los que la llaman usan parámetros por nombre.
   ============================================================================ */

DROP PROCEDURE IF EXISTS api.sp_crear_pedido(INTEGER, VARCHAR, VARCHAR, JSONB, INTEGER, VARCHAR, VARCHAR,
                                             VARCHAR, VARCHAR, VARCHAR, INTEGER, NUMERIC, BIGINT, VARCHAR);

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
    IF p_usuario_id IS NOT NULL THEN
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
END;
$$;

/* ============================================================================
   3. LA PUERTA DE LA APLICACIÓN
   ============================================================================ */

DROP FUNCTION IF EXISTS rest.crear_pedido(INTEGER, TEXT, TEXT, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC);

CREATE OR REPLACE FUNCTION rest.crear_pedido(
    p_unidad_id         INTEGER,
    p_tipo              TEXT,
    p_metodo_pago       TEXT,
    p_items             JSONB,
    p_mesa              TEXT    DEFAULT NULL,
    p_cliente_nombre    TEXT    DEFAULT NULL,
    p_cliente_telefono  TEXT    DEFAULT NULL,
    p_direccion         TEXT    DEFAULT NULL,
    p_indicaciones      TEXT    DEFAULT NULL,
    p_zona_id           INTEGER DEFAULT NULL,
    p_paga_con          NUMERIC DEFAULT NULL,
    p_clave             TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_id     BIGINT;
    v_codigo VARCHAR;
BEGIN
    CALL api.sp_crear_pedido(
        p_unidad_id => p_unidad_id, p_tipo => p_tipo, p_metodo_pago => p_metodo_pago, p_items => p_items,
        p_usuario_id => core.fn_jwt_usuario(), p_mesa => p_mesa,
        p_cliente_nombre => p_cliente_nombre, p_cliente_telefono => p_cliente_telefono,
        p_direccion => p_direccion, p_indicaciones => p_indicaciones, p_zona_id => p_zona_id,
        p_paga_con => p_paga_con, p_clave => NULLIF(trim(p_clave), ''),
        p_pedido_id => v_id, p_codigo => v_codigo);
    RETURN core.fn_pedido_json(v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION
    rest.crear_pedido(INTEGER, TEXT, TEXT, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC, TEXT)
    TO taseca_anon, taseca_app;


/* ============================================================================
   4. REVISIÓN
   ============================================================================ */

DO $$
DECLARE
    v_col BOOLEAN;
    v_idx BOOLEAN;
    v_fn  INTEGER;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_attribute
                    WHERE attrelid = 'core.pedidos'::regclass AND attname = 'clave_envio' AND NOT attisdropped)
      INTO v_col;
    SELECT EXISTS (SELECT 1 FROM pg_indexes
                    WHERE schemaname = 'core' AND indexname = 'uq_pedidos_clave_envio') INTO v_idx;
    SELECT count(*) INTO v_fn FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'rest' AND p.proname = 'crear_pedido';

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE 'Columna core.pedidos.clave_envio ... %', CASE WHEN v_col THEN 'sí' ELSE 'NO' END;
    RAISE NOTICE 'Índice único por empresa ........... %', CASE WHEN v_idx THEN 'sí' ELSE 'NO' END;
    RAISE NOTICE 'Versiones de rest.crear_pedido ..... % (tiene que ser 1)', v_fn;
    RAISE NOTICE '--------------------------------------------------';

    IF NOT v_col OR NOT v_idx THEN
        RAISE EXCEPTION 'El candado no quedó puesto: revisa el paso 1.';
    END IF;
    IF v_fn <> 1 THEN
        RAISE EXCEPTION 'Quedaron % versiones de rest.crear_pedido: la API no sabría cuál llamar.', v_fn;
    END IF;
END;
$$;
