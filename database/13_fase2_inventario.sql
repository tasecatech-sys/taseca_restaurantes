/* ============================================================================
   TASECA · 13 · FASE 2 · BLOQUE 3: STOCK, ENTRADAS Y CIERRES DE INVENTARIO
   ----------------------------------------------------------------------------
   Ejecutar conectado a taseca_db, después de 01 … 12. Se puede volver a
   ejecutar: todo es idempotente.

   QUÉ AGREGA
     · Stock: crear y editar productos de inventario (código, categoría,
       área, unidad de conteo, mínimo, qué producto de la carta lo descuenta)
       y ajustar el stock actual a mano.
     · Entradas: se pueden ELIMINAR o CORREGIR mientras el cierre de esa
       jornada no esté revisado. No se borran: quedan ANULADAS con quién,
       cuándo y por qué, y dejan de contar. Corregir = anular + registrar la
       correcta, en una transacción.
     · Cierres: borrador, corrección (el conteo nuevo reemplaza al anterior),
       revisión y aplicar los saldos al stock.
     · rest.cruce_inventario: el cruce IN · EN · Z · SD de TODO el catálogo
       del área, calculado en la base.

   CORRIGE
     · Anular una factura cuya jornada YA tenía cierre cambiaba el cruce de ese
       día (la venta dejaba de contar) y además devolvía la mercancía como
       entrada del día siguiente. Ahora el día cerrado no cambia: esa venta
       sigue contando allí y la mercancía vuelve sólo por la entrada.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. ENTRADAS ANULABLES
   ============================================================================ */

ALTER TABLE core.entradas_inventario ADD COLUMN IF NOT EXISTS anulada_en       TIMESTAMPTZ;
ALTER TABLE core.entradas_inventario ADD COLUMN IF NOT EXISTS anulada_por_id   INTEGER REFERENCES core.usuarios (id) ON DELETE RESTRICT;
ALTER TABLE core.entradas_inventario ADD COLUMN IF NOT EXISTS motivo_anulacion VARCHAR(300);
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_entradas_anulacion') THEN
        ALTER TABLE core.entradas_inventario
            ADD CONSTRAINT ck_entradas_anulacion
            CHECK (anulada_en IS NULL OR length(trim(COALESCE(motivo_anulacion, ''))) >= 3);
    END IF;
END;
$$;
COMMENT ON COLUMN core.entradas_inventario.anulada_en IS 'Entrada eliminada o corregida: no se borra, deja de contar en stock y cruce.';

/* Una entrada sigue sin editarse. Lo único permitido es anularla UNA vez. */
CREATE OR REPLACE FUNCTION core.tg_entradas_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('taseca.borrado_pruebas', TRUE) = 'si' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    IF TG_OP = 'UPDATE'
       AND OLD.anulada_en IS NULL AND NEW.anulada_en IS NOT NULL
       AND (NEW.insumo_unidad_id, NEW.tipo_entrada_id, NEW.fecha_operativa, NEW.cantidad, NEW.pedido_id, NEW.usuario_id, NEW.creado_en)
           IS NOT DISTINCT FROM
           (OLD.insumo_unidad_id, OLD.tipo_entrada_id, OLD.fecha_operativa, OLD.cantidad, OLD.pedido_id, OLD.usuario_id, OLD.creado_en)
       AND NEW.observacion IS NOT DISTINCT FROM OLD.observacion THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Los registros de entradas_inventario no se modifican ni se borran: se anulan y se registra la correcta.';
END;
$$;

DROP TRIGGER IF EXISTS trg_entradas_inmutable ON core.entradas_inventario;
CREATE TRIGGER trg_entradas_inmutable
    BEFORE UPDATE OR DELETE ON core.entradas_inventario
    FOR EACH ROW EXECUTE FUNCTION core.tg_entradas_inmutable();

/* Al anular, lo que había sumado sale del stock (sin bajar de cero). */
CREATE OR REPLACE FUNCTION core.tg_entradas_anular_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.insumo_unidades
       SET stock_actual = GREATEST(stock_actual - OLD.cantidad, 0), actualizado_en = now()
     WHERE id = OLD.insumo_unidad_id;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_entradas_anular_stock ON core.entradas_inventario;
CREATE TRIGGER trg_entradas_anular_stock
    AFTER UPDATE OF anulada_en ON core.entradas_inventario
    FOR EACH ROW WHEN (OLD.anulada_en IS NULL AND NEW.anulada_en IS NOT NULL)
    EXECUTE FUNCTION core.tg_entradas_anular_stock();

-- Una entrada nueva también marca el stock como actualizado (refresco de la app)
CREATE OR REPLACE FUNCTION core.tg_entradas_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.insumo_unidades
       SET stock_actual = stock_actual + NEW.cantidad, actualizado_en = now()
     WHERE id = NEW.insumo_unidad_id;
    RETURN NEW;
END;
$$;

CREATE INDEX IF NOT EXISTS ix_entradas_vigentes ON core.entradas_inventario (insumo_unidad_id, fecha_operativa)
    WHERE anulada_en IS NULL;

-- La lista de entradas dice si están anuladas (columnas nuevas al final)
CREATE OR REPLACE VIEW api.v_entradas AS
SELECT en.id AS entrada_id, s.unidad_id, s.empresa_id, s.codigo, s.nombre AS insumo, s.area,
       te.codigo AS tipo, te.nombre AS tipo_nombre, te.automatico,
       en.fecha_operativa, en.cantidad, en.observacion,
       p.codigo AS factura, us.nombre AS registrada_por, en.creado_en,
       en.anulada_en, ua.nombre AS anulada_por, en.motivo_anulacion
  FROM core.entradas_inventario en
  JOIN api.v_stock s          ON s.insumo_unidad_id = en.insumo_unidad_id
  JOIN core.tipos_entrada te  ON te.id = en.tipo_entrada_id
  LEFT JOIN core.pedidos p    ON p.id = en.pedido_id
  LEFT JOIN core.usuarios us  ON us.id = en.usuario_id
  LEFT JOIN core.usuarios ua  ON ua.id = en.anulada_por_id;


/* ============================================================================
   2. VENTAS QUE CUENTAN EN Z (una sola regla para vista y API)
   ----------------------------------------------------------------------------
   Cuenta la venta efectiva. Una factura ANULADA deja de contar… salvo para
   los insumos cuya mercancía volvió como entrada de retorno: eso significa
   que su jornada ya estaba cerrada, y ese cierre no se toca.
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.fn_z_insumo(p_insumo_unidad_id INTEGER, p_desde_excl DATE, p_hasta DATE)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(it.cantidad * pi.cantidad), 0)
      FROM core.insumo_unidades iu
      JOIN core.producto_insumos pi ON pi.insumo_id = iu.insumo_id
      JOIN core.pedido_items it     ON it.producto_id = pi.producto_id
      JOIN core.pedidos p           ON p.id = it.pedido_id AND p.unidad_id = iu.unidad_id
      JOIN core.estados_pedido ep   ON ep.id = p.estado_pedido_id
     WHERE iu.id = p_insumo_unidad_id
       AND p.fecha_operativa >  p_desde_excl
       AND p.fecha_operativa <= p_hasta
       AND (ep.cuenta_como_venta
            OR (ep.codigo = 'anulado'
                AND EXISTS (SELECT 1 FROM core.entradas_inventario e
                             WHERE e.pedido_id = p.id AND e.insumo_unidad_id = iu.id)));
$$;

CREATE OR REPLACE FUNCTION core.fn_en_insumo(p_insumo_unidad_id INTEGER, p_desde_excl DATE, p_hasta DATE)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(e.cantidad), 0)
      FROM core.entradas_inventario e
     WHERE e.insumo_unidad_id = p_insumo_unidad_id
       AND e.anulada_en IS NULL
       AND e.fecha_operativa >  p_desde_excl
       AND e.fecha_operativa <= p_hasta;
$$;

-- Mismas columnas que en 05: sin entradas anuladas y con la regla de Z de arriba
CREATE OR REPLACE VIEW api.v_cruce_inventario AS
WITH base AS (
    SELECT d.id AS cierre_detalle_id, c.id AS cierre_id, c.unidad_id, c.area_id, c.fecha_operativa,
           d.insumo_unidad_id, iu.insumo_id, d.saldo_fisico,
           ant.saldo_fisico    AS saldo_anterior,
           ant.fecha_operativa AS fecha_anterior
      FROM core.cierre_detalles d
      JOIN core.cierres_inventario c ON c.id = d.cierre_id
      JOIN core.insumo_unidades iu   ON iu.id = d.insumo_unidad_id
      LEFT JOIN LATERAL (
            SELECT d2.saldo_fisico, c2.fecha_operativa
              FROM core.cierre_detalles d2
              JOIN core.cierres_inventario c2 ON c2.id = d2.cierre_id
             WHERE d2.insumo_unidad_id = d.insumo_unidad_id
               AND c2.fecha_operativa < c.fecha_operativa
             ORDER BY c2.fecha_operativa DESC
             LIMIT 1
      ) ant ON TRUE
)
SELECT b.cierre_id, b.cierre_detalle_id, b.unidad_id, u.empresa_id, u.nombre AS unidad,
       a.codigo AS area, b.fecha_operativa, b.fecha_anterior,
       i.codigo, i.nombre AS insumo,
       COALESCE(b.saldo_anterior, 0) AS inicial,
       (b.saldo_anterior IS NULL)    AS sin_cierre_anterior,
       x.en                          AS entradas,
       x.z                           AS ventas,
       b.saldo_fisico                AS saldo_fisico,
       COALESCE(b.saldo_anterior, 0) + x.en - x.z                  AS saldo_esperado,
       COALESCE(b.saldo_anterior, 0) + x.en - x.z - b.saldo_fisico AS diferencia
  FROM base b
  JOIN core.unidades u         ON u.id = b.unidad_id
  JOIN core.areas_inventario a ON a.id = b.area_id
  JOIN core.insumos i          ON i.id = b.insumo_id
  /* La misma regla que core.fn_en_insumo y core.fn_z_insumo, escrita aquí
     porque una vista lee las tablas con los permisos de su dueño y una
     función con los de quien consulta (la app no lee core). */
  CROSS JOIN LATERAL (
        SELECT (SELECT COALESCE(SUM(e.cantidad), 0)
                  FROM core.entradas_inventario e
                 WHERE e.insumo_unidad_id = b.insumo_unidad_id
                   AND e.anulada_en IS NULL
                   AND e.fecha_operativa >  COALESCE(b.fecha_anterior, b.fecha_operativa - 1)
                   AND e.fecha_operativa <= b.fecha_operativa) AS en,
               (SELECT COALESCE(SUM(it.cantidad * pi.cantidad), 0)
                  FROM core.producto_insumos pi
                  JOIN core.pedido_items it   ON it.producto_id = pi.producto_id
                  JOIN core.pedidos p         ON p.id = it.pedido_id AND p.unidad_id = b.unidad_id
                  JOIN core.estados_pedido ep ON ep.id = p.estado_pedido_id
                 WHERE pi.insumo_id = b.insumo_id
                   AND p.fecha_operativa >  COALESCE(b.fecha_anterior, b.fecha_operativa - 1)
                   AND p.fecha_operativa <= b.fecha_operativa
                   AND (ep.cuenta_como_venta
                        OR (ep.codigo = 'anulado'
                            AND EXISTS (SELECT 1 FROM core.entradas_inventario e2
                                         WHERE e2.pedido_id = p.id AND e2.insumo_unidad_id = b.insumo_unidad_id)))) AS z
  ) x;

/* Borrar facturas de prueba: igual que en 04, pero sin descontar dos veces lo
   que devolvió una entrada que ya estaba anulada. */
CREATE OR REPLACE PROCEDURE api.sp_borrar_facturas_prueba(
    p_empresa_id    INTEGER,
    p_confirmacion  VARCHAR,
    p_usuario_id    INTEGER,
    INOUT p_borradas INTEGER DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'pedidos_anular');

    IF upper(trim(COALESCE(p_confirmacion, ''))) <> 'BORRAR' THEN
        RAISE EXCEPTION 'Escribe BORRAR para confirmar.';
    END IF;
    IF p_usuario_id IS NOT NULL
       AND p_empresa_id IS DISTINCT FROM (SELECT empresa_id FROM core.usuarios WHERE id = p_usuario_id)
       AND NOT core.fn_tiene_permiso(p_usuario_id, 'plataforma') THEN
        RAISE EXCEPTION 'No puedes borrar facturas de otra empresa.' USING ERRCODE = 'insufficient_privilege';
    END IF;

    PERFORM set_config('taseca.borrado_pruebas', 'si', TRUE);

    UPDATE core.insumo_unidades iu
       SET stock_actual = GREATEST(iu.stock_actual - e.total, 0)
      FROM (SELECT en.insumo_unidad_id, SUM(en.cantidad) AS total
              FROM core.entradas_inventario en
              JOIN core.pedidos p ON p.id = en.pedido_id
             WHERE p.empresa_id = p_empresa_id AND en.anulada_en IS NULL
             GROUP BY en.insumo_unidad_id) e
     WHERE iu.id = e.insumo_unidad_id;

    DELETE FROM core.entradas_inventario en USING core.pedidos p
     WHERE p.id = en.pedido_id AND p.empresa_id = p_empresa_id;
    DELETE FROM core.anulaciones a USING core.pedidos p
     WHERE p.id = a.pedido_id AND p.empresa_id = p_empresa_id;
    DELETE FROM core.pedidos WHERE empresa_id = p_empresa_id;
    GET DIAGNOSTICS p_borradas = ROW_COUNT;

    DELETE FROM core.clientes c
     WHERE c.empresa_id = p_empresa_id
       AND NOT EXISTS (SELECT 1 FROM core.pedidos p WHERE p.cliente_id = c.id);

    UPDATE core.consecutivos SET ultimo_numero = 0 WHERE empresa_id = p_empresa_id AND tipo = 'pedido';

    PERFORM set_config('taseca.borrado_pruebas', '', TRUE);
END;
$$;


/* ============================================================================
   3. STOCK (catálogo de inventario)
   ============================================================================ */

/* La unidad de conteo se escribe a mano en la pantalla ("botella",
   "Porción"…): se busca por código o nombre y, si no existe, se crea. */
CREATE OR REPLACE FUNCTION core.fn_unidad_medida(p_texto TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_txt TEXT := lower(regexp_replace(trim(COALESCE(p_texto, '')), '\s+', ' ', 'g'));
    v_id  INTEGER;
BEGIN
    IF v_txt = '' THEN
        v_txt := 'unidad';
    END IF;
    IF length(v_txt) > 20 THEN
        RAISE EXCEPTION 'La unidad de conteo "%" es demasiado larga (máximo 20 letras).', v_txt;
    END IF;
    SELECT id INTO v_id FROM core.unidades_medida WHERE lower(codigo) = v_txt OR lower(nombre) = v_txt LIMIT 1;
    IF v_id IS NULL THEN
        INSERT INTO core.unidades_medida (codigo, nombre)
        VALUES (v_txt, upper(left(v_txt, 1)) || substr(v_txt, 2))
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;

/* Categoría de inventario por nombre; si no existe en la empresa, se crea. */
CREATE OR REPLACE FUNCTION core.fn_categoria_insumo(p_empresa_id INTEGER, p_nombre TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_nombre TEXT := COALESCE(NULLIF(regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g'), ''), 'General');
    v_id     INTEGER;
BEGIN
    SELECT id INTO v_id FROM core.categorias_insumo WHERE empresa_id = p_empresa_id AND lower(nombre) = lower(v_nombre);
    IF v_id IS NULL THEN
        INSERT INTO core.categorias_insumo (empresa_id, nombre) VALUES (p_empresa_id, left(v_nombre, 80))
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_cantidad_entera(p_valor NUMERIC, p_que TEXT, p_permitir_cero BOOLEAN)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p_valor IS NULL OR p_valor <> trunc(p_valor) OR p_valor < 0 OR (p_valor = 0 AND NOT p_permitir_cero) THEN
        RAISE EXCEPTION '% debe ser un número entero %.', p_que,
              CASE WHEN p_permitir_cero THEN 'mayor o igual a cero' ELSE 'mayor que cero' END;
    END IF;
    RETURN p_valor;
END;
$$;

/* Crea o edita un producto de inventario.
   p_stock_actual / p_stock_minimo NULL = no cambiar.
   p_productos NULL = no cambiar qué producto de la carta lo descuenta. */
CREATE OR REPLACE PROCEDURE api.sp_guardar_insumo(
    p_empresa_id     INTEGER,
    p_codigo         VARCHAR,
    p_nombre         VARCHAR,
    p_categoria      VARCHAR,
    p_area           VARCHAR,
    p_unidad_medida  VARCHAR,
    p_unidades       INTEGER[],
    p_usuario_id     INTEGER,
    p_activo         BOOLEAN   DEFAULT TRUE,
    p_stock_actual   NUMERIC   DEFAULT NULL,
    p_stock_minimo   NUMERIC   DEFAULT NULL,
    p_productos      INTEGER[] DEFAULT NULL,
    INOUT p_insumo_id INTEGER  DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_codigo VARCHAR := upper(regexp_replace(trim(COALESCE(p_codigo, '')), '\s+', '', 'g'));
    v_nombre VARCHAR := regexp_replace(trim(COALESCE(p_nombre, '')), '\s+', ' ', 'g');
    v_area   INTEGER := (SELECT id FROM core.areas_inventario WHERE codigo = p_area);
    v_p      INTEGER;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'stock');
    PERFORM core.fn_exigir_unidades(p_usuario_id, p_empresa_id, p_unidades);

    IF v_codigo = '' OR length(v_codigo) > 20 THEN
        RAISE EXCEPTION 'El producto necesita un código de hasta 20 caracteres.';
    END IF;
    IF length(v_nombre) < 2 THEN
        RAISE EXCEPTION 'El producto necesita un nombre.';
    END IF;
    IF v_area IS NULL THEN
        RAISE EXCEPTION 'Elige el área del producto (comidas o bar).';
    END IF;
    IF EXISTS (SELECT 1 FROM core.insumos WHERE empresa_id = p_empresa_id AND codigo = v_codigo
                                            AND id IS DISTINCT FROM p_insumo_id) THEN
        RAISE EXCEPTION 'Ya existe otro producto con el código % (puede ser de otra unidad de la empresa).', v_codigo;
    END IF;
    IF p_stock_actual IS NOT NULL THEN
        PERFORM core.fn_cantidad_entera(p_stock_actual, 'El stock actual', TRUE);
    END IF;
    IF p_stock_minimo IS NOT NULL THEN
        PERFORM core.fn_cantidad_entera(p_stock_minimo, 'El stock mínimo', TRUE);
    END IF;

    IF p_insumo_id IS NULL THEN
        INSERT INTO core.insumos (empresa_id, categoria_insumo_id, area_id, unidad_medida_id, codigo, nombre, activo)
        VALUES (p_empresa_id, core.fn_categoria_insumo(p_empresa_id, p_categoria), v_area,
                core.fn_unidad_medida(p_unidad_medida), v_codigo, v_nombre, COALESCE(p_activo, TRUE))
        RETURNING id INTO p_insumo_id;
    ELSE
        -- Cambiar de área rompería los cierres ya contados de este producto
        IF EXISTS (SELECT 1 FROM core.insumos i WHERE i.id = p_insumo_id AND i.area_id <> v_area)
           AND EXISTS (SELECT 1 FROM core.cierre_detalles d JOIN core.insumo_unidades iu ON iu.id = d.insumo_unidad_id
                        WHERE iu.insumo_id = p_insumo_id) THEN
            RAISE EXCEPTION 'El producto ya aparece en cierres de su área: no puede cambiar de área. Crea uno nuevo.';
        END IF;
        UPDATE core.insumos
           SET codigo = v_codigo, nombre = v_nombre, area_id = v_area,
               categoria_insumo_id = core.fn_categoria_insumo(p_empresa_id, p_categoria),
               unidad_medida_id = core.fn_unidad_medida(p_unidad_medida),
               activo = COALESCE(p_activo, activo)
         WHERE id = p_insumo_id AND empresa_id = p_empresa_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ese producto de inventario ya no existe. Recarga la página.';
        END IF;
    END IF;

    -- Unidades: se agregan; las que ya tenían movimientos no se quitan desde aquí
    INSERT INTO core.insumo_unidades (insumo_id, unidad_id)
    SELECT p_insumo_id, x FROM unnest(p_unidades) x
    ON CONFLICT (insumo_id, unidad_id) DO NOTHING;

    UPDATE core.insumo_unidades
       SET stock_actual = COALESCE(p_stock_actual, stock_actual),
           stock_minimo = COALESCE(p_stock_minimo, stock_minimo),
           actualizado_en = now()
     WHERE insumo_id = p_insumo_id AND unidad_id = ANY (p_unidades)
       AND (p_stock_actual IS NOT NULL OR p_stock_minimo IS NOT NULL);

    IF p_productos IS NOT NULL THEN
        FOREACH v_p IN ARRAY p_productos LOOP
            IF NOT EXISTS (SELECT 1 FROM core.productos WHERE id = v_p AND empresa_id = p_empresa_id) THEN
                RAISE EXCEPTION 'El producto de la carta % no es de esta empresa.', v_p USING ERRCODE = 'insufficient_privilege';
            END IF;
        END LOOP;
        DELETE FROM core.producto_insumos WHERE insumo_id = p_insumo_id AND producto_id <> ALL (p_productos);
        INSERT INTO core.producto_insumos (producto_id, insumo_id)
        SELECT x, p_insumo_id FROM unnest(p_productos) x
        ON CONFLICT (producto_id, insumo_id) DO NOTHING;
    END IF;

    UPDATE core.insumos SET actualizado_en = now() WHERE id = p_insumo_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api.sp_ajustar_stock_actual(p_unidad_id INTEGER, p_insumo_id INTEGER, p_cantidad NUMERIC, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'stock', p_unidad_id);
    PERFORM core.fn_cantidad_entera(p_cantidad, 'El stock', TRUE);
    UPDATE core.insumo_unidades SET stock_actual = p_cantidad, actualizado_en = now()
     WHERE unidad_id = p_unidad_id AND insumo_id = p_insumo_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese producto no está en esta unidad.';
    END IF;
END;
$$;


/* ============================================================================
   4. ENTRADAS
   ============================================================================ */

CREATE OR REPLACE PROCEDURE api.sp_anular_entrada(p_entrada_id BIGINT, p_motivo VARCHAR, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v RECORD;
BEGIN
    SELECT e.id, e.anulada_en, e.fecha_operativa, iu.unidad_id, i.area_id, a.nombre AS area, te.automatico
      INTO v
      FROM core.entradas_inventario e
      JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
      JOIN core.insumos i          ON i.id = iu.insumo_id
      JOIN core.areas_inventario a ON a.id = i.area_id
      JOIN core.tipos_entrada te   ON te.id = e.tipo_entrada_id
     WHERE e.id = p_entrada_id
       FOR UPDATE OF e;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró la entrada.';
    END IF;

    PERFORM core.fn_preparar_operacion(p_usuario_id, 'entradas', v.unidad_id);

    IF v.anulada_en IS NOT NULL THEN
        RAISE EXCEPTION 'Esa entrada ya estaba eliminada.';
    END IF;
    IF v.automatico THEN
        RAISE EXCEPTION 'Los retornos por anulación de factura los genera el sistema: no se eliminan a mano.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.cierres_inventario c JOIN core.estados_cierre ec ON ec.id = c.estado_cierre_id
                WHERE c.unidad_id = v.unidad_id AND c.area_id = v.area_id
                  AND c.fecha_operativa = v.fecha_operativa AND ec.codigo = 'revisado') THEN
        RAISE EXCEPTION 'El cierre de % del % ya fue revisado: sus entradas quedaron congeladas.',
              lower(v.area), to_char(v.fecha_operativa, 'DD/MM/YYYY');
    END IF;
    IF length(trim(COALESCE(p_motivo, ''))) < 3 THEN
        RAISE EXCEPTION 'Escribe por qué se elimina la entrada.';
    END IF;

    UPDATE core.entradas_inventario
       SET anulada_en = now(), anulada_por_id = p_usuario_id, motivo_anulacion = left(trim(p_motivo), 300)
     WHERE id = p_entrada_id;
END;
$$;


/* ============================================================================
   5. CIERRES
   ============================================================================ */

/* Se reemplaza la versión de 04:
     · estado 'borrador' o 'completado' (un completado no vuelve a borrador)
     · p_nuevo = TRUE: si ya hay cierre para esa unidad, área y fecha, avisa
       (YA_EXISTE) en vez de mezclarlo
     · al corregir, el conteo nuevo REEMPLAZA al anterior: lo que no se contó
       esta vez sale del cierre
     · saldos enteros ≥ 0 y nunca una jornada futura
   p_detalle: [{"insumo_id": 7, "saldo": 24}] o [{"codigo": "BAR-01", "saldo": 24}] */
DROP PROCEDURE IF EXISTS api.sp_registrar_cierre(INTEGER, VARCHAR, JSONB, INTEGER, DATE, VARCHAR, BIGINT);

CREATE OR REPLACE PROCEDURE api.sp_registrar_cierre(
    p_unidad_id    INTEGER,
    p_area         VARCHAR,
    p_detalle      JSONB,
    p_usuario_id   INTEGER,
    p_fecha        DATE    DEFAULT NULL,
    p_observacion  VARCHAR DEFAULT NULL,
    p_estado       VARCHAR DEFAULT 'completado',
    p_nuevo        BOOLEAN DEFAULT FALSE,
    INOUT p_cierre_id BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_empresa  INTEGER := core.fn_empresa_de_unidad(p_unidad_id);
    v_area     INTEGER := (SELECT id FROM core.areas_inventario WHERE codigo = p_area);
    v_hoy      DATE;
    v_fecha    DATE;
    v_estado   VARCHAR := COALESCE(NULLIF(p_estado, ''), 'completado');
    v_actual   VARCHAR;
    v_linea    JSONB;
    v_iu       INTEGER;
    v_contados INTEGER[] := '{}';
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'cierres_registrar', p_unidad_id);

    IF v_empresa IS NULL THEN
        RAISE EXCEPTION 'La unidad % no existe.', p_unidad_id;
    END IF;
    IF v_area IS NULL THEN
        RAISE EXCEPTION 'El cierre necesita un área válida (comidas o bar).';
    END IF;
    IF v_estado NOT IN ('borrador', 'completado') THEN
        RAISE EXCEPTION 'Un cierre se guarda como borrador o completado; la revisión es aparte.';
    END IF;
    IF p_detalle IS NULL OR jsonb_typeof(p_detalle) <> 'array' OR jsonb_array_length(p_detalle) = 0 THEN
        RAISE EXCEPTION 'El cierre no tiene productos contados.';
    END IF;

    v_hoy   := core.fn_fecha_operativa(v_empresa, now());
    v_fecha := COALESCE(p_fecha, v_hoy);
    IF v_fecha > v_hoy THEN
        RAISE EXCEPTION 'No se puede cerrar una jornada que todavía no llega (%).', to_char(v_fecha, 'DD/MM/YYYY');
    END IF;

    SELECT c.id, ec.codigo INTO p_cierre_id, v_actual
      FROM core.cierres_inventario c JOIN core.estados_cierre ec ON ec.id = c.estado_cierre_id
     WHERE c.unidad_id = p_unidad_id AND c.area_id = v_area AND c.fecha_operativa = v_fecha
       FOR UPDATE OF c;

    IF p_cierre_id IS NOT NULL AND p_nuevo THEN
        RAISE EXCEPTION 'YA_EXISTE: ya hay un cierre de % para esa unidad y fecha. Vuelve atrás para corregirlo.', p_area;
    END IF;
    IF v_actual = 'revisado' THEN
        RAISE EXCEPTION 'El cierre de % del % ya fue revisado: no se puede corregir.', p_area, to_char(v_fecha, 'DD/MM/YYYY');
    END IF;
    IF v_actual = 'completado' THEN
        v_estado := 'completado'; -- lo completado no vuelve a borrador
    END IF;

    IF p_cierre_id IS NULL THEN
        INSERT INTO core.cierres_inventario (unidad_id, area_id, estado_cierre_id, fecha_operativa, observacion, registrado_por_id)
        VALUES (p_unidad_id, v_area, core.fn_id_catalogo('estados_cierre', v_estado), v_fecha,
                NULLIF(trim(p_observacion), ''), p_usuario_id)
        RETURNING id INTO p_cierre_id;
    ELSE
        UPDATE core.cierres_inventario
           SET estado_cierre_id = core.fn_id_catalogo('estados_cierre', v_estado),
               observacion = COALESCE(NULLIF(trim(p_observacion), ''), observacion),
               registrado_por_id = p_usuario_id, actualizado_en = now()
         WHERE id = p_cierre_id;
    END IF;

    FOR v_linea IN SELECT * FROM jsonb_array_elements(p_detalle) LOOP
        SELECT iu.id INTO v_iu
          FROM core.insumo_unidades iu JOIN core.insumos i ON i.id = iu.insumo_id
         WHERE iu.unidad_id = p_unidad_id AND i.area_id = v_area
           AND (i.id = NULLIF(v_linea ->> 'insumo_id', '')::INTEGER
                OR (v_linea ? 'codigo' AND i.codigo = upper(trim(v_linea ->> 'codigo'))));
        IF v_iu IS NULL THEN
            RAISE EXCEPTION 'El producto % no es de esta unidad ni de esta área.', COALESCE(v_linea ->> 'codigo', v_linea ->> 'insumo_id');
        END IF;
        PERFORM core.fn_cantidad_entera(NULLIF(v_linea ->> 'saldo', '')::NUMERIC,
                                        'El saldo de ' || COALESCE(v_linea ->> 'codigo', v_linea ->> 'insumo_id'), TRUE);

        INSERT INTO core.cierre_detalles (cierre_id, insumo_unidad_id, saldo_fisico)
        VALUES (p_cierre_id, v_iu, (v_linea ->> 'saldo')::NUMERIC)
        ON CONFLICT (cierre_id, insumo_unidad_id) DO UPDATE SET saldo_fisico = EXCLUDED.saldo_fisico;
        v_contados := v_contados || v_iu;
    END LOOP;

    -- El conteo nuevo reemplaza al anterior
    DELETE FROM core.cierre_detalles WHERE cierre_id = p_cierre_id AND insumo_unidad_id <> ALL (v_contados);
END;
$$;

/* Igual que en 04, pero exige que el cierre esté completado (no un borrador). */
CREATE OR REPLACE PROCEDURE api.sp_revisar_cierre(p_cierre_id BIGINT, p_usuario_id INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_estado VARCHAR;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'cierres_revisar',
            (SELECT unidad_id FROM core.cierres_inventario WHERE id = p_cierre_id));
    SELECT ec.codigo INTO v_estado
      FROM core.cierres_inventario c JOIN core.estados_cierre ec ON ec.id = c.estado_cierre_id
     WHERE c.id = p_cierre_id;
    IF v_estado IS NULL OR v_estado = 'revisado' THEN
        RAISE EXCEPTION 'El cierre % no existe o ya estaba revisado.', p_cierre_id;
    END IF;
    IF v_estado = 'borrador' THEN
        RAISE EXCEPTION 'Ese cierre es un borrador: primero hay que completarlo.';
    END IF;
    UPDATE core.cierres_inventario
       SET estado_cierre_id = core.fn_id_catalogo('estados_cierre', 'revisado'),
           revisado_por_id = p_usuario_id, revisado_en = now(), actualizado_en = now()
     WHERE id = p_cierre_id;
END;
$$;

/* Igual que en 04; se puede aplicar más de una vez (antes fallaba en un
   cierre revisado que ya estaba aplicado). */
CREATE OR REPLACE PROCEDURE api.sp_aplicar_cierre_a_stock(p_cierre_id BIGINT, p_usuario_id INTEGER, INOUT p_aplicados INTEGER DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'stock',
            (SELECT unidad_id FROM core.cierres_inventario WHERE id = p_cierre_id));
    IF NOT EXISTS (SELECT 1 FROM core.cierres_inventario WHERE id = p_cierre_id) THEN
        RAISE EXCEPTION 'No se encontró el cierre.';
    END IF;

    UPDATE core.insumo_unidades iu
       SET stock_actual = d.saldo_fisico, actualizado_en = now()
      FROM core.cierre_detalles d
     WHERE d.cierre_id = p_cierre_id AND d.insumo_unidad_id = iu.id;
    GET DIAGNOSTICS p_aplicados = ROW_COUNT;

    UPDATE core.cierres_inventario SET aplicado_a_stock = TRUE, actualizado_en = now()
     WHERE id = p_cierre_id AND NOT aplicado_a_stock;
END;
$$;


/* ============================================================================
   6. API REST · LECTURA
   Todo filtrado por la empresa del token, las unidades del usuario y sus
   permisos. Cierres y entradas: los últimos 62 días.
   ============================================================================ */

CREATE OR REPLACE VIEW rest.stock AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT i.id AS insumo_id, i.empresa_id, i.codigo, i.nombre, ci.nombre AS categoria, a.codigo AS area,
       um.codigo AS unidad_medida, i.activo,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('unidad_id', iu.unidad_id, 'stock_actual', iu.stock_actual,
                                                     'stock_minimo', iu.stock_minimo) ORDER BY iu.unidad_id)
                   FROM core.insumo_unidades iu WHERE iu.insumo_id = i.id), '[]') AS unidades,
       COALESCE((SELECT jsonb_agg(pi.producto_id ORDER BY pi.producto_id)
                   FROM core.producto_insumos pi WHERE pi.insumo_id = i.id), '[]') AS productos,
       GREATEST(i.actualizado_en, (SELECT max(iu.actualizado_en) FROM core.insumo_unidades iu WHERE iu.insumo_id = i.id)) AS actualizado_en
  FROM core.insumos i
  JOIN sesion s                  ON s.empresa_id = i.empresa_id
  JOIN core.categorias_insumo ci ON ci.id = i.categoria_insumo_id
  JOIN core.areas_inventario a   ON a.id = i.area_id
  JOIN core.unidades_medida um   ON um.id = i.unidad_medida_id
 WHERE EXISTS (SELECT 1 FROM unnest(ARRAY['stock', 'entradas', 'cierres', 'cierres_registrar']) p
                WHERE api.fn_tiene_permiso(s.usuario_id, p))
   AND EXISTS (SELECT 1 FROM core.insumo_unidades iu
                WHERE iu.insumo_id = i.id AND core.fn_usuario_en_unidad(s.usuario_id, iu.unidad_id));

CREATE OR REPLACE VIEW rest.cierres AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT c.id AS cierre_id, u.empresa_id, c.unidad_id, a.codigo AS area, c.fecha_operativa, ec.codigo AS estado,
       c.observacion, c.aplicado_a_stock, c.registrado_por_id, ur.nombre AS registrado_por,
       uv.nombre AS revisado_por, c.revisado_en, c.creado_en, c.actualizado_en,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', i.codigo, 'nombre', i.nombre, 'saldo', d.saldo_fisico)
                                  ORDER BY i.codigo)
                   FROM core.cierre_detalles d
                   JOIN core.insumo_unidades iu ON iu.id = d.insumo_unidad_id
                   JOIN core.insumos i          ON i.id = iu.insumo_id
                  WHERE d.cierre_id = c.id), '[]') AS productos
  FROM core.cierres_inventario c
  JOIN core.unidades u         ON u.id = c.unidad_id
  JOIN sesion s                ON s.empresa_id = u.empresa_id
  JOIN core.areas_inventario a ON a.id = c.area_id
  JOIN core.estados_cierre ec  ON ec.id = c.estado_cierre_id
  LEFT JOIN core.usuarios ur   ON ur.id = c.registrado_por_id
  LEFT JOIN core.usuarios uv   ON uv.id = c.revisado_por_id
 WHERE c.fecha_operativa >= core.fn_fecha_operativa(u.empresa_id, now()) - 62
   AND core.fn_usuario_en_unidad(s.usuario_id, c.unidad_id)
   AND EXISTS (SELECT 1 FROM unnest(ARRAY['stock', 'cierres', 'cierres_registrar']) p
                WHERE api.fn_tiene_permiso(s.usuario_id, p));

CREATE OR REPLACE VIEW rest.entradas AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT e.id AS entrada_id, i.empresa_id, iu.unidad_id, i.codigo, i.nombre, a.codigo AS area,
       e.cantidad, te.codigo AS tipo, e.observacion, e.fecha_operativa, e.usuario_id,
       us.nombre AS registrada_por, e.creado_en, p.codigo AS factura
  FROM core.entradas_inventario e
  JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
  JOIN core.insumos i          ON i.id = iu.insumo_id
  JOIN sesion s                ON s.empresa_id = i.empresa_id
  JOIN core.areas_inventario a ON a.id = i.area_id
  JOIN core.tipos_entrada te   ON te.id = e.tipo_entrada_id
  LEFT JOIN core.usuarios us   ON us.id = e.usuario_id
  LEFT JOIN core.pedidos p     ON p.id = e.pedido_id
 WHERE e.anulada_en IS NULL
   AND e.fecha_operativa >= core.fn_fecha_operativa(i.empresa_id, now()) - 62
   AND core.fn_usuario_en_unidad(s.usuario_id, iu.unidad_id)
   AND EXISTS (SELECT 1 FROM unnest(ARRAY['stock', 'entradas', 'cierres']) p2
                WHERE api.fn_tiene_permiso(s.usuario_id, p2));

/* Una sola fila con la última modificación del inventario de la empresa.
   La aplicación la consulta (unos bytes) y sólo recarga si cambió. */
CREATE OR REPLACE VIEW rest.inventario_marca AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_empresa() AS empresa_id
)
SELECT s.empresa_id,
       GREATEST(
           (SELECT max(i.actualizado_en) FROM core.insumos i WHERE i.empresa_id = s.empresa_id),
           (SELECT max(iu.actualizado_en) FROM core.insumo_unidades iu JOIN core.unidades u ON u.id = iu.unidad_id
             WHERE u.empresa_id = s.empresa_id),
           (SELECT max(c.actualizado_en) FROM core.cierres_inventario c JOIN core.unidades u ON u.id = c.unidad_id
             WHERE u.empresa_id = s.empresa_id),
           (SELECT max(GREATEST(e.creado_en, COALESCE(e.anulada_en, e.creado_en)))
              FROM core.entradas_inventario e JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
              JOIN core.unidades u ON u.id = iu.unidad_id
             WHERE u.empresa_id = s.empresa_id)
       ) AS marca
  FROM sesion s
 WHERE s.empresa_id IS NOT NULL;


/* ============================================================================
   7. API REST · FUNCIONES
   ============================================================================ */

/* El cierre como lo usa la aplicación. */
CREATE OR REPLACE FUNCTION core.fn_cierre_json(p_cierre_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
    SELECT to_jsonb(c) FROM rest.cierres c WHERE c.cierre_id = p_cierre_id;
$$;

/* POST /rpc/guardar_insumo { "p_insumo": { insumo_id|null, codigo, nombre, categoria,
   area, unidad, activo, stock_actual?, stock_minimo?, unidades: [..], productos?: [..] } } */
CREATE OR REPLACE FUNCTION rest.guardar_insumo(p_insumo JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
    v_id      INTEGER := NULLIF(p_insumo ->> 'insumo_id', '')::INTEGER;
    v_unidades  INTEGER[];
    v_productos INTEGER[];
BEGIN
    v_unidades := ARRAY(SELECT x::INTEGER FROM jsonb_array_elements_text(COALESCE(p_insumo -> 'unidades', '[]')) x);
    IF jsonb_typeof(p_insumo -> 'productos') = 'array' THEN
        v_productos := ARRAY(SELECT x::INTEGER FROM jsonb_array_elements_text(p_insumo -> 'productos') x);
    END IF;

    CALL api.sp_guardar_insumo(
        p_empresa_id    => v_empresa,
        p_codigo        => p_insumo ->> 'codigo',
        p_nombre        => p_insumo ->> 'nombre',
        p_categoria     => p_insumo ->> 'categoria',
        p_area          => p_insumo ->> 'area',
        p_unidad_medida => p_insumo ->> 'unidad',
        p_unidades      => v_unidades,
        p_usuario_id    => v_usuario,
        p_activo        => COALESCE((p_insumo ->> 'activo')::BOOLEAN, TRUE),
        p_stock_actual  => NULLIF(p_insumo ->> 'stock_actual', '')::NUMERIC,
        p_stock_minimo  => NULLIF(p_insumo ->> 'stock_minimo', '')::NUMERIC,
        p_productos     => v_productos,
        p_insumo_id     => v_id);
    RETURN jsonb_build_object('insumo_id', v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.ajustar_stock(p_unidad_id INTEGER, p_codigo TEXT, p_cantidad NUMERIC)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_insumo  INTEGER := (SELECT id FROM core.insumos WHERE empresa_id = core.fn_jwt_empresa() AND codigo = upper(trim(p_codigo)));
BEGIN
    IF v_insumo IS NULL THEN
        RAISE EXCEPTION 'El producto % no existe en el inventario.', p_codigo;
    END IF;
    CALL api.sp_ajustar_stock_actual(p_unidad_id, v_insumo, p_cantidad, v_usuario);
    RETURN jsonb_build_object('codigo', upper(trim(p_codigo)), 'stock_actual', p_cantidad);
END;
$$;

/* POST /rpc/registrar_entrada { "p_entrada": { unidad_id, codigo, tipo, cantidad, observacion, fecha } } */
CREATE OR REPLACE FUNCTION rest.registrar_entrada(p_entrada JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
    v_unidad  INTEGER := NULLIF(p_entrada ->> 'unidad_id', '')::INTEGER;
    v_insumo  INTEGER;
    v_fecha   DATE    := NULLIF(p_entrada ->> 'fecha', '')::DATE;
    v_id      BIGINT;
BEGIN
    SELECT id INTO v_insumo FROM core.insumos WHERE empresa_id = v_empresa AND codigo = upper(trim(p_entrada ->> 'codigo'));
    IF v_insumo IS NULL THEN
        RAISE EXCEPTION 'El producto no existe en el catálogo de inventario.';
    END IF;
    IF v_fecha IS NULL THEN
        RAISE EXCEPTION 'La entrada necesita una fecha válida.';
    END IF;
    IF v_fecha > core.fn_fecha_operativa(v_empresa, now()) THEN
        RAISE EXCEPTION 'La entrada no puede ser de una jornada futura.';
    END IF;
    PERFORM core.fn_cantidad_entera(NULLIF(p_entrada ->> 'cantidad', '')::NUMERIC, 'La cantidad', FALSE);

    CALL api.sp_registrar_entrada(
        p_unidad_id   => v_unidad,
        p_insumo_id   => v_insumo,
        p_tipo        => COALESCE(NULLIF(p_entrada ->> 'tipo', ''), 'compra'),
        p_cantidad    => (p_entrada ->> 'cantidad')::NUMERIC,
        p_usuario_id  => v_usuario,
        p_observacion => p_entrada ->> 'observacion',
        p_fecha       => v_fecha,
        p_entrada_id  => v_id);

    RETURN (SELECT to_jsonb(e) FROM rest.entradas e WHERE e.entrada_id = v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.anular_entrada(p_entrada_id BIGINT, p_motivo TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.entradas_inventario e
                     JOIN core.insumo_unidades iu ON iu.id = e.insumo_unidad_id
                     JOIN core.insumos i ON i.id = iu.insumo_id
                    WHERE e.id = p_entrada_id AND i.empresa_id = core.fn_jwt_empresa()) THEN
        RAISE EXCEPTION 'No se encontró la entrada.';
    END IF;
    CALL api.sp_anular_entrada(p_entrada_id, COALESCE(NULLIF(trim(p_motivo), ''), 'Eliminada desde el panel'), v_usuario);
    RETURN jsonb_build_object('entrada_id', p_entrada_id, 'anulada', TRUE);
END;
$$;

/* Corregir = anular la entrada y registrar la correcta, todo o nada.
   p_datos: los campos que cambian (unidad_id, codigo, tipo, cantidad, observacion, fecha). */
CREATE OR REPLACE FUNCTION rest.corregir_entrada(p_entrada_id BIGINT, p_datos JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_actual JSONB;
BEGIN
    SELECT to_jsonb(e) INTO v_actual FROM rest.entradas e WHERE e.entrada_id = p_entrada_id;
    IF v_actual IS NULL THEN
        RAISE EXCEPTION 'No se encontró la entrada (o ya no se puede corregir).';
    END IF;

    PERFORM rest.anular_entrada(p_entrada_id, 'Corregida desde el panel');
    RETURN rest.registrar_entrada(
        jsonb_build_object('unidad_id', v_actual -> 'unidad_id', 'codigo', v_actual -> 'codigo',
                           'tipo', v_actual -> 'tipo', 'cantidad', v_actual -> 'cantidad',
                           'observacion', v_actual -> 'observacion', 'fecha', v_actual -> 'fecha_operativa')
        || jsonb_strip_nulls(COALESCE(p_datos, '{}')));
END;
$$;

/* POST /rpc/registrar_cierre { "p_cierre": { unidad_id, area, fecha, estado, observacion,
   productos: [{ codigo, saldo }], nuevo } } */
CREATE OR REPLACE FUNCTION rest.registrar_cierre(p_cierre JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_unidad  INTEGER := NULLIF(p_cierre ->> 'unidad_id', '')::INTEGER;
    v_id      BIGINT;
BEGIN
    IF core.fn_empresa_de_unidad(v_unidad) IS DISTINCT FROM core.fn_jwt_empresa() THEN
        RAISE EXCEPTION 'La unidad % no es de esta empresa.', v_unidad USING ERRCODE = 'insufficient_privilege';
    END IF;
    CALL api.sp_registrar_cierre(
        p_unidad_id   => v_unidad,
        p_area        => p_cierre ->> 'area',
        p_detalle     => p_cierre -> 'productos',
        p_usuario_id  => v_usuario,
        p_fecha       => NULLIF(p_cierre ->> 'fecha', '')::DATE,
        p_observacion => p_cierre ->> 'observacion',
        p_estado      => p_cierre ->> 'estado',
        p_nuevo       => COALESCE((p_cierre ->> 'nuevo')::BOOLEAN, FALSE),
        p_cierre_id   => v_id);
    RETURN core.fn_cierre_json(v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.revisar_cierre(p_cierre_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.cierres_inventario c JOIN core.unidades u ON u.id = c.unidad_id
                    WHERE c.id = p_cierre_id AND u.empresa_id = core.fn_jwt_empresa()) THEN
        RAISE EXCEPTION 'No se encontró el cierre.';
    END IF;
    CALL api.sp_revisar_cierre(p_cierre_id, core.fn_exigir_sesion());
    RETURN core.fn_cierre_json(p_cierre_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.aplicar_cierre_a_stock(p_cierre_id BIGINT)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_n INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.cierres_inventario c JOIN core.unidades u ON u.id = c.unidad_id
                    WHERE c.id = p_cierre_id AND u.empresa_id = core.fn_jwt_empresa()) THEN
        RAISE EXCEPTION 'No se encontró el cierre.';
    END IF;
    CALL api.sp_aplicar_cierre_a_stock(p_cierre_id, core.fn_exigir_sesion(), v_n);
    RETURN v_n;
END;
$$;

/* EL CRUCE de una unidad, jornada y área, para TODO el catálogo del área
   (lo contado y lo que falta por contar):

     IN  saldo del último cierre anterior en que se contó el producto; si
         nunca se contó, el stock registrado antes de esa jornada ('stock')
     EN  entradas vigentes desde ese cierre hasta esta jornada
     Z   ventas en el mismo tramo (ver core.fn_z_insumo)
     SD  lo contado en el cierre de esta jornada (null = sin registrar) */
CREATE OR REPLACE FUNCTION rest.cruce_inventario(p_unidad_id INTEGER, p_fecha DATE, p_area TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_area    INTEGER := (SELECT id FROM core.areas_inventario WHERE codigo = p_area);
    v_cierre  BIGINT;
    v_filas   JSONB;
    v_ant     JSONB;
BEGIN
    IF core.fn_empresa_de_unidad(p_unidad_id) IS DISTINCT FROM core.fn_jwt_empresa()
       OR NOT core.fn_usuario_en_unidad(v_usuario, p_unidad_id) THEN
        RAISE EXCEPTION 'No trabajas en esa unidad.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT (core.fn_tiene_permiso(v_usuario, 'cierres') OR core.fn_tiene_permiso(v_usuario, 'stock')) THEN
        RAISE EXCEPTION 'Tu perfil no puede ver el cruce de inventario.' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF v_area IS NULL OR p_fecha IS NULL THEN
        RAISE EXCEPTION 'Elige la fecha y el área del cruce.';
    END IF;

    SELECT id INTO v_cierre FROM core.cierres_inventario
     WHERE unidad_id = p_unidad_id AND area_id = v_area AND fecha_operativa = p_fecha;

    SELECT jsonb_build_object('cierre_id', c.id, 'fecha', c.fecha_operativa) INTO v_ant
      FROM core.cierres_inventario c
     WHERE c.unidad_id = p_unidad_id AND c.area_id = v_area AND c.fecha_operativa < p_fecha
     ORDER BY c.fecha_operativa DESC LIMIT 1;

    WITH items AS (
        SELECT iu.id AS iu_id, i.codigo, i.nombre, ci.nombre AS categoria, um.codigo AS unidad, iu.stock_actual,
               (SELECT d.saldo_fisico FROM core.cierre_detalles d WHERE d.cierre_id = v_cierre AND d.insumo_unidad_id = iu.id) AS sd,
               EXISTS (SELECT 1 FROM core.cierre_detalles d WHERE d.cierre_id = v_cierre AND d.insumo_unidad_id = iu.id) AS registrado,
               ant.saldo_fisico AS saldo_ant, ant.fecha_operativa AS fecha_ant
          FROM core.insumo_unidades iu
          JOIN core.insumos i            ON i.id = iu.insumo_id
          JOIN core.categorias_insumo ci ON ci.id = i.categoria_insumo_id
          JOIN core.unidades_medida um   ON um.id = i.unidad_medida_id
          LEFT JOIN LATERAL (
                SELECT d2.saldo_fisico, c2.fecha_operativa
                  FROM core.cierre_detalles d2
                  JOIN core.cierres_inventario c2 ON c2.id = d2.cierre_id
                 WHERE d2.insumo_unidad_id = iu.id AND c2.fecha_operativa < p_fecha
                 ORDER BY c2.fecha_operativa DESC LIMIT 1
          ) ant ON TRUE
         WHERE iu.unidad_id = p_unidad_id AND i.area_id = v_area
           AND (i.activo OR EXISTS (SELECT 1 FROM core.cierre_detalles d WHERE d.cierre_id = v_cierre AND d.insumo_unidad_id = iu.id))
    ),
    calc AS (
        SELECT it.*,
               core.fn_en_insumo(it.iu_id, COALESCE(it.fecha_ant, p_fecha - 1), p_fecha) AS en,
               core.fn_z_insumo(it.iu_id, COALESCE(it.fecha_ant, p_fecha - 1), p_fecha)  AS z,
               -- Sin conteo previo: el stock registrado, menos lo que entró desde esa jornada
               GREATEST(it.stock_actual - core.fn_en_insumo(it.iu_id, p_fecha - 1, 'infinity'::DATE), 0) AS stock_base
          FROM items it
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'codigo', codigo, 'nombre', nombre, 'categoria', categoria, 'unidad', unidad,
               'IN', CASE WHEN fecha_ant IS NOT NULL THEN saldo_ant ELSE stock_base END,
               'origenIN', CASE WHEN fecha_ant IS NOT NULL THEN 'cierre' WHEN stock_base > 0 THEN 'stock' ELSE 'sin-dato' END,
               'fuenteIN', fecha_ant,
               'EN', en, 'Z', z,
               'SD', CASE WHEN registrado THEN sd END,
               'registrado', registrado)
           ORDER BY codigo), '[]')
      INTO v_filas
      FROM calc;

    RETURN jsonb_build_object('unidad_id', p_unidad_id, 'fecha', p_fecha, 'area', p_area,
                              'cierre', CASE WHEN v_cierre IS NOT NULL THEN core.fn_cierre_json(v_cierre) END,
                              'cierre_anterior', v_ant, 'filas', v_filas);
END;
$$;


/* ============================================================================
   8. PERMISOS
   ============================================================================ */

REVOKE ALL ON FUNCTION core.fn_unidad_medida(TEXT), core.fn_categoria_insumo(INTEGER, TEXT),
                       core.fn_cantidad_entera(NUMERIC, TEXT, BOOLEAN), core.fn_cierre_json(BIGINT),
                       core.fn_z_insumo(INTEGER, DATE, DATE), core.fn_en_insumo(INTEGER, DATE, DATE)
       FROM PUBLIC;
REVOKE ALL ON FUNCTION core.fn_z_insumo(INTEGER, DATE, DATE), core.fn_en_insumo(INTEGER, DATE, DATE)
       FROM taseca_app, taseca_lectura;

REVOKE ALL ON PROCEDURE api.sp_guardar_insumo(INTEGER, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER[], INTEGER,
                                              BOOLEAN, NUMERIC, NUMERIC, INTEGER[], INTEGER),
                        api.sp_ajustar_stock_actual(INTEGER, INTEGER, NUMERIC, INTEGER),
                        api.sp_anular_entrada(BIGINT, VARCHAR, INTEGER),
                        api.sp_registrar_cierre(INTEGER, VARCHAR, JSONB, INTEGER, DATE, VARCHAR, VARCHAR, BOOLEAN, BIGINT),
                        api.sp_revisar_cierre(BIGINT, INTEGER),
                        api.sp_aplicar_cierre_a_stock(BIGINT, INTEGER, INTEGER),
                        api.sp_borrar_facturas_prueba(INTEGER, VARCHAR, INTEGER, INTEGER)
       FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE api.sp_guardar_insumo(INTEGER, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER[], INTEGER,
                                                 BOOLEAN, NUMERIC, NUMERIC, INTEGER[], INTEGER),
                           api.sp_ajustar_stock_actual(INTEGER, INTEGER, NUMERIC, INTEGER),
                           api.sp_anular_entrada(BIGINT, VARCHAR, INTEGER),
                           api.sp_registrar_cierre(INTEGER, VARCHAR, JSONB, INTEGER, DATE, VARCHAR, VARCHAR, BOOLEAN, BIGINT),
                           api.sp_revisar_cierre(BIGINT, INTEGER),
                           api.sp_aplicar_cierre_a_stock(BIGINT, INTEGER, INTEGER),
                           api.sp_borrar_facturas_prueba(INTEGER, VARCHAR, INTEGER, INTEGER)
      TO taseca_app;
GRANT SELECT ON api.v_entradas, api.v_cruce_inventario TO taseca_app, taseca_lectura;

GRANT SELECT ON rest.stock, rest.cierres, rest.entradas, rest.inventario_marca TO taseca_app;

REVOKE ALL ON FUNCTION rest.guardar_insumo(JSONB), rest.ajustar_stock(INTEGER, TEXT, NUMERIC),
                       rest.registrar_entrada(JSONB), rest.anular_entrada(BIGINT, TEXT), rest.corregir_entrada(BIGINT, JSONB),
                       rest.registrar_cierre(JSONB), rest.revisar_cierre(BIGINT), rest.aplicar_cierre_a_stock(BIGINT),
                       rest.cruce_inventario(INTEGER, DATE, TEXT)
       FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.guardar_insumo(JSONB), rest.ajustar_stock(INTEGER, TEXT, NUMERIC),
                          rest.registrar_entrada(JSONB), rest.anular_entrada(BIGINT, TEXT), rest.corregir_entrada(BIGINT, JSONB),
                          rest.registrar_cierre(JSONB), rest.revisar_cierre(BIGINT), rest.aplicar_cierre_a_stock(BIGINT),
                          rest.cruce_inventario(INTEGER, DATE, TEXT)
      TO taseca_app;

NOTIFY pgrst, 'reload schema';
