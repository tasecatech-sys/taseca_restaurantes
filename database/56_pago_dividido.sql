/* ============================================================================
   TASECA · 56 · PAGO DIVIDIDO
   ----------------------------------------------------------------------------
   Lo que pasa en caja: el cliente paga una parte en efectivo y otra por
   transferencia (o datáfono, o Nequi…). Hasta hoy un pedido tenía UN método
   de pago y el cruce de caja lo sumaba entero a esa columna: con una cuenta
   de 50.000 pagada 20.000 en billete y 30.000 por Nequi, el cajón esperaba
   50.000 en efectivo o ninguno.

   QUÉ SE HACE
     · core.pedido_pagos: las partes de un pago dividido, una fila por
       método. Sólo existen para los pedidos divididos; los demás siguen
       igual, con su método en core.pedidos.
     · El pedido dividido queda con el método «mixto» (Pago dividido). Es
       un método del catálogo que NO se habilita en ninguna empresa: no se
       elige, sólo lo pone este procedimiento.
     · El cruce de caja (rest.informe_caja) suma cada parte en la columna
       de SU método: los 20.000 al cajón, los 30.000 a transferencias.

   EL RECARGO VA SOBRE LA PARTE
     Cada parte es un pedazo de la cuenta (subtotal + domicilio). Si su
     método tiene recargo, se calcula sobre ESE pedazo -el 5% del datáfono
     sobre lo que se paga con datáfono, no sobre toda la cuenta- y se le
     suma. El recargo del pedido es la suma de los de sus partes, así que
     el total de api.v_pedidos sigue siendo subtotal + domicilio + recargo
     y nada más tiene que cambiar para leerlo.

   POR DÓNDE ENTRA
     · rest.confirmar_pago_dividido: caja cobra un pedido de «Por cobrar»
       (mesa, domicilio, para recoger) en varias partes.
     · rest.vender_con_pago_dividido: la venta de mostrador, que nace
       cobrada, en varias partes.

   Un pago confirmado sigue siendo definitivo: las partes no se editan ni
   se borran. Si hubo un error, se anula la factura, como siempre.

   Requiere: 00 … 55 instalados. Se puede ejecutar más de una vez.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. EL MÉTODO «PAGO DIVIDIDO»
   ============================================================================ */

INSERT INTO core.metodos_pago (codigo, nombre, grupo_caja)
SELECT 'mixto', 'Pago dividido', 'otros'
 WHERE NOT EXISTS (SELECT 1 FROM core.metodos_pago WHERE codigo = 'mixto');


/* ============================================================================
   2. LAS PARTES
   ============================================================================ */

CREATE TABLE IF NOT EXISTS core.pedido_pagos (
    id              BIGSERIAL PRIMARY KEY,
    pedido_id       BIGINT        NOT NULL REFERENCES core.pedidos (id)      ON DELETE CASCADE,
    metodo_pago_id  INTEGER       NOT NULL REFERENCES core.metodos_pago (id) ON DELETE RESTRICT,
    base            NUMERIC(12,2) NOT NULL CHECK (base > 0),
    recargo         NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (recargo >= 0),
    usuario_id      INTEGER       REFERENCES core.usuarios (id) ON DELETE RESTRICT,
    creado_en       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT uq_pedido_pagos UNIQUE (pedido_id, metodo_pago_id)
);
COMMENT ON TABLE core.pedido_pagos IS
    'Partes de un pago dividido. Lo recibido por cada método = base + recargo.';
COMMENT ON COLUMN core.pedido_pagos.base IS
    'El pedazo de la cuenta (subtotal + domicilio) que se paga con este método.';
COMMENT ON COLUMN core.pedido_pagos.recargo IS
    'Recargo del método calculado sobre `base`, congelado al cobrar.';

CREATE INDEX IF NOT EXISTS ix_pedido_pagos_metodo ON core.pedido_pagos (metodo_pago_id);

-- Igual que el resto de core: sin políticas, sólo el dueño la toca (ver 19)
ALTER TABLE core.pedido_pagos ENABLE ROW LEVEL SECURITY;

/* Un pago confirmado no cambia: las partes no se editan ni se borran. La
   limpieza de pruebas (taseca.borrado_pruebas) es la única excepción. */
CREATE OR REPLACE FUNCTION core.tg_pedido_pagos_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
BEGIN
    IF current_setting('taseca.borrado_pruebas', TRUE) = 'si' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    RAISE EXCEPTION 'Las partes de un pago confirmado no se modifican ni se borran: si hubo un error, se anula la factura.';
END;
$$;

DROP TRIGGER IF EXISTS trg_pedido_pagos_inmutable ON core.pedido_pagos;
CREATE TRIGGER trg_pedido_pagos_inmutable
    BEFORE UPDATE OR DELETE ON core.pedido_pagos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedido_pagos_inmutable();


/* ============================================================================
   3. LO RECIBIDO POR MÉTODO, PEDIDO POR PEDIDO

   Una fila por cada método con que se pagó: las partes si el pedido se
   dividió, y si no, el pedido entero con su método. Es lo que suma el
   cruce de caja.
   ============================================================================ */

CREATE OR REPLACE VIEW api.v_pagos_pedido AS
SELECT pp.pedido_id, mp.codigo AS metodo_pago, mp.nombre AS metodo_pago_nombre, mp.grupo_caja,
       pp.base, pp.recargo, pp.base + pp.recargo AS valor, TRUE AS dividido
  FROM core.pedido_pagos pp
  JOIN core.metodos_pago mp ON mp.id = pp.metodo_pago_id
UNION ALL
SELECT vp.pedido_id, vp.metodo_pago, vp.metodo_pago_nombre, vp.grupo_caja,
       vp.total - vp.recargo_pago, vp.recargo_pago, vp.total, FALSE
  FROM api.v_pedidos vp
 WHERE NOT EXISTS (SELECT 1 FROM core.pedido_pagos pp WHERE pp.pedido_id = vp.pedido_id);

GRANT SELECT ON api.v_pagos_pedido TO taseca_lectura;


/* ============================================================================
   4. COBRAR EN PARTES

   p_partes = [ {"metodo": "efectivo", "base": 20000},
                {"metodo": "nequi",    "base": 30000} ]

   `base` es el pedazo de la CUENTA (subtotal + domicilio) que se paga con
   ese método, sin recargo; las bases tienen que sumar la cuenta exacta. El
   recargo de cada método se calcula aquí, sobre su parte.
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_pago_dividido(
    p_pedido_id   BIGINT,
    p_partes      JSONB,
    p_usuario_id  INTEGER,
    p_nota        VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_empresa  INTEGER;
    v_unidad   INTEGER;
    v_estado   VARCHAR;
    v_pago     VARCHAR;
    v_codigo   VARCHAR;
    v_cuenta   NUMERIC;
    v_parte    JSONB;
    v_cod      TEXT;
    v_metodo   INTEGER;
    v_nombre   TEXT;
    v_base     NUMERIC;
    v_rec      NUMERIC;
    v_suma     NUMERIC := 0;
    v_recargo  NUMERIC := 0;
    v_texto    TEXT := '';
BEGIN
    SELECT p.empresa_id, p.unidad_id, e.codigo, ep.codigo, p.codigo
      INTO v_empresa, v_unidad, v_estado, v_pago, v_codigo
      FROM core.pedidos p
      JOIN core.estados_pedido e ON e.id = p.estado_pedido_id
      JOIN core.estados_pago ep  ON ep.id = p.estado_pago_id
     WHERE p.id = p_pedido_id
       FOR UPDATE OF p;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe.', p_pedido_id;
    END IF;

    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pagos', v_unidad);

    IF v_estado IN ('cancelado', 'anulado') THEN
        RAISE EXCEPTION 'La factura % está %: no hay pago que registrar.', v_codigo, v_estado;
    END IF;
    IF v_pago = 'confirmado' THEN
        RAISE EXCEPTION 'El pago de la factura % ya fue confirmado.', v_codigo;
    END IF;
    IF p_partes IS NULL OR jsonb_typeof(p_partes) <> 'array' OR jsonb_array_length(p_partes) < 2 THEN
        RAISE EXCEPTION 'Para dividir el pago hacen falta al menos dos métodos.';
    END IF;

    -- La cuenta, sin recargo: la misma base que usan crear_pedido y la 40
    SELECT COALESCE((SELECT SUM(i.precio_unitario * i.cantidad)
                       FROM core.pedido_items i WHERE i.pedido_id = p.id), 0)
           + p.costo_domicilio
      INTO v_cuenta
      FROM core.pedidos p
     WHERE p.id = p_pedido_id;

    FOR v_parte IN SELECT * FROM jsonb_array_elements(p_partes) LOOP
        v_cod := NULLIF(trim(v_parte ->> 'metodo'), '');
        IF v_cod IS NULL OR v_cod = 'mixto' THEN
            RAISE EXCEPTION 'Elige el método de cada parte del pago.';
        END IF;

        v_metodo := core.fn_id_catalogo('metodos_pago', v_cod);
        SELECT mp.nombre INTO v_nombre
          FROM core.empresa_metodos_pago emp
          JOIN core.metodos_pago mp ON mp.id = emp.metodo_pago_id
         WHERE emp.empresa_id = v_empresa AND emp.metodo_pago_id = v_metodo AND emp.activo;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El método de pago "%" no está disponible.', v_cod;
        END IF;

        BEGIN
            v_base := round((v_parte ->> 'base')::NUMERIC, 2);
        EXCEPTION WHEN invalid_text_representation THEN
            v_base := NULL;
        END;
        IF v_base IS NULL OR v_base <= 0 THEN
            RAISE EXCEPTION 'Escribe cuánto se paga con %: cada parte tiene que ser mayor que cero.', v_nombre;
        END IF;

        v_rec := core.fn_recargo_pago(v_empresa, v_metodo, v_base);

        BEGIN
            INSERT INTO core.pedido_pagos (pedido_id, metodo_pago_id, base, recargo, usuario_id)
            VALUES (p_pedido_id, v_metodo, v_base, v_rec, p_usuario_id);
        EXCEPTION WHEN unique_violation THEN
            RAISE EXCEPTION 'El método % está dos veces: junta esas partes en una sola.', v_nombre;
        END;

        v_suma    := v_suma + v_base;
        v_recargo := v_recargo + v_rec;
        v_texto   := v_texto || CASE WHEN v_texto = '' THEN '' ELSE ' + ' END
                     || v_nombre || ' ' || core.fn_pesos(v_base + v_rec)
                     || CASE WHEN v_rec > 0 THEN ' (recargo ' || core.fn_pesos(v_rec) || ')' ELSE '' END;
    END LOOP;

    IF v_suma <> v_cuenta THEN
        RAISE EXCEPTION 'Las partes suman % y la cuenta es %: tienen que dar lo mismo.',
              core.fn_pesos(v_suma), core.fn_pesos(v_cuenta);
    END IF;

    UPDATE core.pedidos
       SET estado_pago_id = core.fn_id_catalogo('estados_pago', 'confirmado'),
           metodo_pago_id = core.fn_id_catalogo('metodos_pago', 'mixto'),
           recargo_pago   = v_recargo
     WHERE id = p_pedido_id;

    UPDATE core.comprobantes_pago
       SET estado_pago_id = core.fn_id_catalogo('estados_pago', 'confirmado'),
           revisado_por_id = p_usuario_id, revisado_en = now()
     WHERE pedido_id = p_pedido_id AND revisado_en IS NULL;

    INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
    VALUES (p_pedido_id, left('Pago dividido: ' || v_texto, 300), p_usuario_id);

    IF NULLIF(trim(p_nota), '') IS NOT NULL THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        VALUES (p_pedido_id, 'Referencia del pago: ' || trim(p_nota), p_usuario_id);
    END IF;
END;
$$;

/* «$ 30.500»: pesos sin decimales, con punto de miles, para el historial. */
CREATE OR REPLACE FUNCTION core.fn_pesos(p_valor NUMERIC)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = core, public
AS $$
    SELECT '$' || replace(to_char(round(COALESCE(p_valor, 0)), 'FM999,999,999,990'), ',', '.');
$$;


/* ============================================================================
   5. LA VENTA DE MOSTRADOR TAMBIÉN SE PUEDE DIVIDIR

   Misma firma y mismo cuerpo que el de la 45. Un solo cambio, al final:
   si la venta de mostrador entra por rest.vender_con_pago_dividido (que
   enciende `taseca.pago_dividido`), aquí NO se cobra con un solo método;
   lo cobra después api.sp_pago_dividido, en la misma transacción.
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_crear_pedido(
    IN p_unidad_id integer, IN p_tipo character varying, IN p_metodo_pago character varying,
    IN p_items jsonb, IN p_usuario_id integer DEFAULT NULL, IN p_mesa character varying DEFAULT NULL,
    IN p_cliente_nombre character varying DEFAULT NULL, IN p_cliente_telefono character varying DEFAULT NULL,
    IN p_direccion character varying DEFAULT NULL, IN p_indicaciones character varying DEFAULT NULL,
    IN p_zona_id integer DEFAULT NULL, IN p_paga_con numeric DEFAULT NULL,
    IN p_clave character varying DEFAULT NULL,
    INOUT p_pedido_id bigint DEFAULT NULL, INOUT p_codigo character varying DEFAULT NULL)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'core', 'public'
AS $procedure$
DECLARE
    v_empresa   INTEGER := core.fn_empresa_de_unidad(p_unidad_id);
    v_metodo    INTEGER := core.fn_id_catalogo('metodos_pago', p_metodo_pago);
    v_tipo      INTEGER := core.fn_id_catalogo('tipos_pedido', p_tipo);
    v_cliente   BIGINT;
    v_mesa      INTEGER;
    v_linea     JSONB;
    v_item      BIGINT;
    v_menu      BIGINT;
    v_minimo    NUMERIC;
    v_falta     TEXT;
BEGIN
    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    END IF;

    /* ¿Este mismo envío ya entró? Entonces no es un pedido nuevo: es el
       mismo toque que llegó dos veces. Se devuelve el que ya existe. */
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

    IF p_tipo IN ('domicilio', 'recoger') THEN
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
        SELECT id, codigo INTO p_pedido_id, p_codigo
          FROM core.pedidos
         WHERE empresa_id = v_empresa AND clave_envio = p_clave;
        IF FOUND THEN
            RETURN;
        END IF;
        RAISE;
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

        /* A qué menú pertenece la línea: el armado lo trae en menu_dia_id; el
           plato del chef lo hereda de su plato. */
        v_menu := COALESCE((v_linea ->> 'menu_dia_id')::BIGINT,
                           (SELECT menu_dia_id FROM core.platos_dia WHERE id = (v_linea ->> 'plato_dia_id')::BIGINT));

        /* Elige acompañamientos si es armado (siempre) o si es un plato del
           chef cuyo menú los pide. */
        IF v_menu IS NOT NULL AND (
               (v_linea ? 'menu_dia_id')
            OR EXISTS (SELECT 1 FROM core.menus_dia md WHERE md.id = v_menu AND md.pide_acompanamientos)
           ) THEN
            INSERT INTO core.pedido_item_opciones (pedido_item_id, menu_opcion_id)
            SELECT v_item, x::BIGINT FROM jsonb_array_elements_text(COALESCE(v_linea -> 'opciones', '[]')) x;

            -- Toda categoría obligatoria con opciones activas debe tener al menos una elegida
            SELECT string_agg(c.nombre, ', ' ORDER BY c.orden) INTO v_falta
              FROM core.menu_categorias c
             WHERE c.menu_dia_id = v_menu
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

    /* ---- VENTA DIRECTA (mostrador): entrega si nada se prepara, y cobra. --- */
    IF p_tipo = 'mostrador' THEN
        IF NOT EXISTS (
            SELECT 1 FROM core.pedido_items i
              JOIN core.productos pr ON pr.id = i.producto_id
             WHERE i.pedido_id = p_pedido_id AND pr.requiere_preparacion
        ) AND NOT EXISTS (
            SELECT 1 FROM core.pedido_items i
             WHERE i.pedido_id = p_pedido_id
               AND (i.plato_dia_id IS NOT NULL OR i.menu_dia_id IS NOT NULL)
        ) THEN
            UPDATE core.pedidos
               SET estado_pedido_id = core.fn_id_catalogo('estados_pedido', 'entregado')
             WHERE id = p_pedido_id;
        END IF;

        -- (56) Con pago dividido lo cobra api.sp_pago_dividido, enseguida
        IF current_setting('taseca.pago_dividido', TRUE) IS DISTINCT FROM 'si' THEN
            CALL api.sp_actualizar_pago(p_pedido_id, 'confirmado', p_usuario_id, NULL, p_metodo_pago);
        END IF;
    END IF;
END;
$procedure$;


/* ============================================================================
   6. EL PEDIDO COMO LO VE EL PANEL: + sus partes
   (la misma fn_pedido_json de la 51, con una clave más al final)
   ============================================================================ */
CREATE OR REPLACE FUNCTION core.fn_pedido_json(p_pedido_id BIGINT)
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT to_jsonb(vp)
        || jsonb_build_object(
               'empresa_codigo', e.codigo,
               'mesa_id', p.mesa_id,
               'zona_id', p.zona_domicilio_id,
               'tomado_por_id', p.tomado_por_id,
               'items', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                               'pedido_item_id', i.pedido_item_id, 'origen', i.origen,
                               'producto_id', i.producto_id, 'plato_dia_id', i.plato_dia_id,
                               'menu_dia_id', i.menu_dia_id, 'nombre', i.nombre,
                               'precio_unitario', i.precio_unitario, 'cantidad', i.cantidad,
                               'notas', i.notas, 'detalle', i.detalle,
                               'opciones', COALESCE((SELECT jsonb_agg(x.menu_opcion_id ORDER BY x.menu_opcion_id)
                                                       FROM core.pedido_item_opciones x
                                                      WHERE x.pedido_item_id = i.pedido_item_id), '[]'))
                           ORDER BY i.pedido_item_id)
                      FROM api.v_pedido_items i WHERE i.pedido_id = vp.pedido_id), '[]'),
               'historial', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object('ts', h.creado_en, 'texto', h.descripcion) ORDER BY h.id)
                      FROM core.pedido_historial h WHERE h.pedido_id = vp.pedido_id), '[]'),
               'tiene_comprobante', EXISTS (SELECT 1 FROM core.comprobantes_pago c
                                             WHERE c.pedido_id = vp.pedido_id AND c.archivo_url IS NOT NULL),
               'referencia_pago', (SELECT c.referencia FROM core.comprobantes_pago c
                                    WHERE c.pedido_id = vp.pedido_id ORDER BY c.id DESC LIMIT 1),
               'anulacion', (SELECT jsonb_build_object('motivo', a.motivo, 'jornada_original', a.jornada_original,
                                                       'jornada_retorno', a.jornada_retorno,
                                                       'diferido', a.jornada_retorno <> a.jornada_original,
                                                       'creado_en', a.creado_en)
                               FROM core.anulaciones a WHERE a.pedido_id = vp.pedido_id),
               'domiciliario_id', p.domiciliario_id,
               'domiciliario', (SELECT u.nombre FROM core.usuarios u WHERE u.id = p.domiciliario_id),
               -- (56) Las partes, si el pago se dividió; si no, lista vacía
               'pagos', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object('metodo', mp.codigo, 'base', pp.base,
                                                        'recargo', pp.recargo, 'valor', pp.base + pp.recargo)
                                     ORDER BY pp.id)
                      FROM core.pedido_pagos pp
                      JOIN core.metodos_pago mp ON mp.id = pp.metodo_pago_id
                     WHERE pp.pedido_id = vp.pedido_id), '[]')
           )
      FROM api.v_pedidos vp
      JOIN core.pedidos p  ON p.id = vp.pedido_id
      JOIN core.empresas e ON e.id = vp.empresa_id
     WHERE vp.pedido_id = p_pedido_id;
$$;


/* ============================================================================
   7. API REST
   ============================================================================ */

-- Caja cobra en partes un pedido de «Por cobrar»
CREATE OR REPLACE FUNCTION rest.confirmar_pago_dividido(p_pedido_id BIGINT, p_partes JSONB, p_referencia TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    CALL api.sp_pago_dividido(p_pedido_id, p_partes, core.fn_exigir_sesion(), p_referencia);
    RETURN core.fn_pedido_de_sesion(p_pedido_id);
END;
$$;

/* Venta de mostrador cobrada en partes. Lo mismo que rest.crear_pedido
   con p_tipo = 'mostrador', pero el cobro lo hace sp_pago_dividido. Todo
   en una transacción: si las partes no cuadran, la venta no queda.

   Con `p_clave` repetida (el mismo toque que llegó dos veces) se devuelve
   la venta que ya existía, sin volver a cobrarla. */
CREATE OR REPLACE FUNCTION rest.vender_con_pago_dividido(
    p_unidad_id INTEGER, p_items JSONB, p_partes JSONB, p_clave TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario  INTEGER := core.fn_exigir_sesion();
    v_id       BIGINT;
    v_codigo   VARCHAR;
    v_primero  TEXT := NULLIF(trim(p_partes -> 0 ->> 'metodo'), '');
BEGIN
    IF p_partes IS NULL OR jsonb_typeof(p_partes) <> 'array' OR jsonb_array_length(p_partes) < 2 THEN
        RAISE EXCEPTION 'Para dividir el pago hacen falta al menos dos métodos.';
    END IF;
    IF v_primero IS NULL OR v_primero = 'mixto' THEN
        RAISE EXCEPTION 'Elige el método de cada parte del pago.';
    END IF;

    /* El pedido nace con el método de la primera parte (tiene que ser uno
       habilitado); sp_pago_dividido lo deja en «Pago dividido». */
    PERFORM set_config('taseca.pago_dividido', 'si', TRUE);
    CALL api.sp_crear_pedido(
        p_unidad_id => p_unidad_id, p_tipo => 'mostrador', p_metodo_pago => v_primero,
        p_items => p_items, p_usuario_id => v_usuario,
        p_clave => NULLIF(trim(p_clave), ''),
        p_pedido_id => v_id, p_codigo => v_codigo);
    PERFORM set_config('taseca.pago_dividido', '', TRUE);

    IF NOT EXISTS (SELECT 1 FROM core.pedidos p JOIN core.estados_pago ep ON ep.id = p.estado_pago_id
                    WHERE p.id = v_id AND ep.codigo = 'confirmado') THEN
        CALL api.sp_pago_dividido(v_id, p_partes, v_usuario, NULL);
    END IF;

    -- (52) Sede con comanda impresa: directo a preparación
    PERFORM core.fn_comanda_al_crear(v_id);

    RETURN core.fn_pedido_json(v_id);
END;
$$;


/* ============================================================================
   8. EL CRUCE DE CAJA SUMA CADA PARTE EN SU COLUMNA

   Misma función que en la 14. Cambian las dos consultas de pedidos: en vez
   de agrupar el pedido entero por su método, agrupan sus partes (una fila
   por cada método con que se pagó). `n` es el número de pagos de ese
   método (un pedido dividido cuenta en cada uno de los suyos).

   Las partes salen de core.fn_partes_pago, pedido por pedido, DESPUÉS de
   filtrar la jornada y la unidad. Unir con la vista api.v_pagos_pedido
   haría que PostgreSQL armara las partes de todos los pedidos de la base.
   ============================================================================ */

-- Las partes de UN pedido: las del pago dividido o el pedido entero
CREATE OR REPLACE FUNCTION core.fn_partes_pago(
    p_pedido_id BIGINT, p_metodo TEXT, p_grupo TEXT, p_total NUMERIC)
RETURNS TABLE (metodo_pago TEXT, grupo_caja TEXT, valor NUMERIC)
LANGUAGE sql
STABLE
SET search_path = core, public
AS $$
    SELECT mp.codigo::TEXT, mp.grupo_caja::TEXT, pp.base + pp.recargo
      FROM core.pedido_pagos pp
      JOIN core.metodos_pago mp ON mp.id = pp.metodo_pago_id
     WHERE pp.pedido_id = p_pedido_id
    UNION ALL
    SELECT p_metodo, p_grupo, p_total
     WHERE NOT EXISTS (SELECT 1 FROM core.pedido_pagos pp WHERE pp.pedido_id = p_pedido_id);
$$;
REVOKE ALL ON FUNCTION core.fn_partes_pago(BIGINT, TEXT, TEXT, NUMERIC) FROM PUBLIC;
CREATE OR REPLACE FUNCTION rest.informe_caja(p_fecha DATE, p_unidad_id INTEGER DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario  INTEGER := core.fn_exigir_sesion();
    v_empresa  INTEGER := core.fn_jwt_empresa();
    v_unidades INTEGER[];
    v_ventas   JSONB;
    v_anuladas JSONB;
    v_gastos   JSONB;
    v_base     JSONB;
    v_valor    NUMERIC;
BEGIN
    IF NOT (core.fn_tiene_permiso(v_usuario, 'informe') OR core.fn_tiene_permiso(v_usuario, 'base_caja')) THEN
        RAISE EXCEPTION 'Tu perfil no puede ver el cruce de caja.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_unidad_id IS NOT NULL THEN
        PERFORM core.fn_unidad_de_sesion(p_unidad_id);
        IF NOT core.fn_usuario_en_unidad(v_usuario, p_unidad_id) THEN
            RAISE EXCEPTION 'No trabajas en esa unidad.' USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;

    SELECT array_agg(u.id) INTO v_unidades
      FROM core.unidades u
     WHERE u.empresa_id = v_empresa
       AND (p_unidad_id IS NULL OR u.id = p_unidad_id)
       AND core.fn_usuario_en_unidad(v_usuario, u.id);

    -- Ventas efectivas por método: vendido, cobrado, pendiente y rechazado
    SELECT COALESCE(jsonb_object_agg(metodo_pago, jsonb_build_object(
               'grupo', grupo_caja, 'n', n, 'vendido', vendido, 'cobrado', cobrado,
               'pendiente', pendiente, 'nPendiente', n_pendiente, 'rechazado', rechazado)), '{}')
      INTO v_ventas
      FROM (SELECT pg.metodo_pago, pg.grupo_caja, count(*) AS n, SUM(pg.valor) AS vendido,
                   COALESCE(SUM(pg.valor) FILTER (WHERE vp.estado_pago = 'confirmado'), 0) AS cobrado,
                   COALESCE(SUM(pg.valor) FILTER (WHERE vp.estado_pago NOT IN ('confirmado', 'rechazado')), 0) AS pendiente,
                   count(*) FILTER (WHERE vp.estado_pago NOT IN ('confirmado', 'rechazado')) AS n_pendiente,
                   COALESCE(SUM(pg.valor) FILTER (WHERE vp.estado_pago = 'rechazado'), 0) AS rechazado
              FROM api.v_pedidos vp
              CROSS JOIN LATERAL core.fn_partes_pago(vp.pedido_id, vp.metodo_pago, vp.grupo_caja, vp.total) pg
             WHERE vp.unidad_id = ANY (v_unidades) AND vp.fecha_operativa = p_fecha AND vp.cuenta_como_venta
             GROUP BY pg.metodo_pago, pg.grupo_caja) x;

    SELECT COALESCE(jsonb_object_agg(metodo_pago, jsonb_build_object('grupo', grupo_caja, 'n', n, 'total', total)), '{}')
      INTO v_anuladas
      FROM (SELECT pg.metodo_pago, pg.grupo_caja, count(*) AS n, SUM(pg.valor) AS total
              FROM api.v_pedidos vp
              CROSS JOIN LATERAL core.fn_partes_pago(vp.pedido_id, vp.metodo_pago, vp.grupo_caja, vp.total) pg
             WHERE vp.unidad_id = ANY (v_unidades) AND vp.fecha_operativa = p_fecha AND vp.estado = 'anulado'
             GROUP BY pg.metodo_pago, pg.grupo_caja) x;

    SELECT COALESCE(jsonb_object_agg(metodo_pago, jsonb_build_object(
               'grupo', grupo_caja, 'n', n, 'total', total, 'pendientes', pendientes, 'montoPendiente', monto_pendiente)), '{}')
      INTO v_gastos
      FROM (SELECT metodo_pago, grupo_caja, count(*) AS n, SUM(monto) AS total,
                   count(*) FILTER (WHERE estado = 'registrado') AS pendientes,
                   COALESCE(SUM(monto) FILTER (WHERE estado = 'registrado'), 0) AS monto_pendiente
              FROM api.v_gastos
             WHERE unidad_id = ANY (v_unidades) AND fecha_operativa = p_fecha AND estado <> 'anulado'
             GROUP BY metodo_pago, grupo_caja) x;

    SELECT COALESCE(SUM(monto), 0) INTO v_valor
      FROM core.bases_caja WHERE unidad_id = ANY (v_unidades) AND fecha_operativa = p_fecha AND vigente;
    IF p_unidad_id IS NOT NULL THEN
        SELECT to_jsonb(b) INTO v_base FROM rest.bases_caja b
         WHERE b.unidad_id = p_unidad_id AND b.fecha_operativa = p_fecha AND b.vigente;
    END IF;

    RETURN jsonb_build_object(
        'jornada', p_fecha, 'unidad_id', p_unidad_id,
        'base', jsonb_build_object('valor', v_valor, 'registro', v_base),
        'ventas', v_ventas, 'anuladas', v_anuladas, 'gastos', v_gastos);
END;
$$;


/* ============================================================================
   9. EL CHEQUEO DE INTEGRIDAD (17) NO CONFUNDE «PAGO DIVIDIDO» CON UN ERROR

   api.fn_chequeo_integridad marca como ERROR todo pedido cuyo método no
   esté habilitado en su empresa, y «mixto» a propósito no lo está en
   ninguna. Se le enseña la excepción cambiando sólo esa consulta dentro
   de la función instalada: copiarla entera (cientos de líneas) para
   tocar una sería peor. Si el texto no aparece -porque alguien ya la
   cambió-, se avisa y no se toca nada.
   ============================================================================ */
DO $$
DECLARE
    v_def    TEXT := pg_get_functiondef('api.fn_chequeo_integridad()'::regprocedure);
    v_viejo  TEXT := 'AND emp.metodo_pago_id = p.metodo_pago_id)$q$';
    v_nuevo  TEXT := 'AND emp.metodo_pago_id = p.metodo_pago_id)'
                     || ' AND p.metodo_pago_id <> core.fn_id_catalogo(''metodos_pago'', ''mixto'')$q$';
BEGIN
    IF position('''mixto''' IN v_def) > 0 THEN
        RAISE NOTICE 'El chequeo de integridad ya conoce el pago dividido.';
    ELSIF position(v_viejo IN v_def) = 0 THEN
        RAISE NOTICE 'No encontré la consulta del método en api.fn_chequeo_integridad: no se tocó. Los pagos divididos saldrán ahí como «método no habilitado».';
    ELSE
        EXECUTE replace(v_def, v_viejo, v_nuevo);
    END IF;
END $$;


/* ============================================================================
   10. PERMISOS
   ============================================================================ */

REVOKE ALL ON PROCEDURE api.sp_pago_dividido(BIGINT, JSONB, INTEGER, VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_pago_dividido(BIGINT, JSONB, INTEGER, VARCHAR) TO taseca_app;

REVOKE ALL ON FUNCTION rest.confirmar_pago_dividido(BIGINT, JSONB, TEXT),
                       rest.vender_con_pago_dividido(INTEGER, JSONB, JSONB, TEXT)
       FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.confirmar_pago_dividido(BIGINT, JSONB, TEXT),
                          rest.vender_con_pago_dividido(INTEGER, JSONB, JSONB, TEXT)
      TO taseca_app;

NOTIFY pgrst, 'reload schema';
