/* ============================================================================
   TASECA · 30 · EL RECARGO DE PAGAR CON CADA MÉTODO
   ----------------------------------------------------------------------------
   Lo que se le cobra al cliente POR PAGAR ASÍ: la comisión de la pasarela,
   el 4×1000, lo que el negocio decida. Configurable por método desde
   ⚙️ Configuración → 💳 Métodos de pago.

   DOS FORMAS, PORQUE LAS DOS EXISTEN EN LA CALLE

     'fijo'        tantos pesos, se cobre lo que se cobre
     'porcentaje'  tanto por ciento de lo que va a pasar por ese método

   La BASE del porcentaje es subtotal + domicilio. Cobrarlo sólo sobre la
   comida dejaría sin cubrir la comisión del domicilio, que también pasa por
   la misma pasarela.

   SE CALCULA EN LA BASE, NO EN EL NAVEGADOR

     El pedido llega del portal del cliente, y el portal no es de fiar: si
     el recargo viniera en la petición, cualquiera podría mandarlo en cero.
     Se calcula aquí con la configuración de la empresa, igual que ya se
     hace con el costo del domicilio (que sale de la zona, no de lo que
     diga el cliente).

   SE GUARDA, NO SE RECALCULA AL LEER

     `core.pedidos.recargo_pago` es una columna, no una cuenta de la vista.
     Si mañana el recargo de Nequi sube a $5.000, las facturas de ayer
     tienen que seguir diciendo los $1.500 que se cobraron de verdad. Una
     factura que cambia sola no es una factura.

   POR QUÉ NO SE TOCA api.sp_crear_pedido

     El recargo depende del subtotal, y el subtotal no existe hasta que se
     insertan los ítems, que es lo último que hace ese procedimiento. No
     puede ser un trigger BEFORE sobre core.pedidos.

     Y recrear el procedimiento entero para añadirle tres líneas al final
     obligaría a copiar su cuerpo aquí, con el riesgo de que las dos copias
     se separen. Así que se hace en rest.crear_pedido, que es el envoltorio
     por donde entran TODOS los pedidos y cabe en media pantalla.

   Nada de lo que ya existe cambia de valor: el recargo arranca en 0 para
   todos los métodos, y 0 es lo que se cobraba. Se puede ejecutar más de una
   vez.
   Requiere: 00 … 29 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. DÓNDE SE CONFIGURA Y DÓNDE SE GUARDA
   ============================================================================ */
ALTER TABLE core.empresa_metodos_pago
    ADD COLUMN IF NOT EXISTS recargo      NUMERIC(12,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS recargo_tipo VARCHAR(12)   NOT NULL DEFAULT 'fijo';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_empresa_metodos_recargo') THEN
        ALTER TABLE core.empresa_metodos_pago
            ADD CONSTRAINT ck_empresa_metodos_recargo CHECK (recargo >= 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_empresa_metodos_recargo_tipo') THEN
        ALTER TABLE core.empresa_metodos_pago
            ADD CONSTRAINT ck_empresa_metodos_recargo_tipo
            CHECK (recargo_tipo IN ('fijo', 'porcentaje'));
    END IF;
END;
$$;

COMMENT ON COLUMN core.empresa_metodos_pago.recargo IS
    'Lo que se le cobra al cliente por pagar con este método. 0 = no se cobra nada.';
COMMENT ON COLUMN core.empresa_metodos_pago.recargo_tipo IS
    'fijo = pesos · porcentaje = % de (subtotal + domicilio).';

ALTER TABLE core.pedidos
    ADD COLUMN IF NOT EXISTS recargo_pago NUMERIC(12,2) NOT NULL DEFAULT 0;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_pedidos_recargo_pago') THEN
        ALTER TABLE core.pedidos
            ADD CONSTRAINT ck_pedidos_recargo_pago CHECK (recargo_pago >= 0);
    END IF;
END;
$$;

COMMENT ON COLUMN core.pedidos.recargo_pago IS
    'Recargo del método de pago, congelado al crear el pedido. No se recalcula.';


/* ============================================================================
   2. LA REGLA, EN UN SOLO SITIO

   Para que la base y js/store.js (recargoDeMetodo) digan el mismo número.
   Se redondea al peso: no hay moneda de a céntimo y un total con decimales
   no se puede cobrar en caja.
   ============================================================================ */
CREATE OR REPLACE FUNCTION core.fn_recargo_pago(p_empresa_id INTEGER, p_metodo_pago_id INTEGER, p_base NUMERIC)
RETURNS NUMERIC
LANGUAGE sql STABLE
SET search_path = core, public
AS $$
    SELECT COALESCE(
        GREATEST(round(
            CASE WHEN emp.recargo_tipo = 'porcentaje'
                 THEN COALESCE(p_base, 0) * emp.recargo / 100
                 ELSE emp.recargo
            END
        ), 0), 0)
      FROM core.empresa_metodos_pago emp
     WHERE emp.empresa_id     = p_empresa_id
       AND emp.metodo_pago_id = p_metodo_pago_id
       AND emp.recargo > 0;
$$;

COMMENT ON FUNCTION core.fn_recargo_pago(INTEGER, INTEGER, NUMERIC) IS
    'Cuánto recarga un método de pago sobre una base. Espejo de recargoDeMetodo() en js/store.js.';


/* ============================================================================
   3. EL TOTAL LO INCLUYE

   Mismo texto que 05_vistas.sql salvo las tres líneas del recargo. Si esa
   vista cambia, hay que volver a traer el cambio aquí.
   ============================================================================ */
CREATE OR REPLACE VIEW api.v_pedidos AS
SELECT p.id AS pedido_id, p.empresa_id, p.unidad_id, u.nombre AS unidad, p.codigo,
       tp.codigo AS tipo, tp.nombre AS tipo_nombre,
       ep.codigo AS estado, ep.nombre AS estado_nombre, ep.orden AS estado_orden, ep.es_final,
       ep.cuenta_como_venta,
       pg.codigo AS estado_pago, pg.nombre AS estado_pago_nombre,
       mp.codigo AS metodo_pago, mp.nombre AS metodo_pago_nombre, mp.grupo_caja,
       me.numero AS mesa,
       cl.nombre AS cliente, cl.telefono AS cliente_telefono,
       p.direccion_entrega, p.indicaciones, z.nombre AS zona,
       COALESCE(it.subtotal, 0)                                      AS subtotal,
       p.costo_domicilio,
       COALESCE(it.subtotal, 0) + p.costo_domicilio + p.recargo_pago AS total,
       COALESCE(it.unidades, 0)                                        AS productos,
       p.paga_con,
       /* El cambio se calcula contra lo que de verdad hay que pagar: con el
          recargo fuera, caja devolvería de más. */
       CASE WHEN p.paga_con IS NOT NULL
            THEN p.paga_con - (COALESCE(it.subtotal, 0) + p.costo_domicilio + p.recargo_pago)
       END AS cambio,
       p.fecha_operativa, p.motivo_cancelacion,
       us.nombre AS tomado_por,
       p.creado_en, p.actualizado_en,
       /* AL FINAL a la fuerza: CREATE OR REPLACE VIEW no deja meter una
          columna en medio ni renombrar las que hay. Su sitio natural
          sería al lado de costo_domicilio, pero no se puede. */
       p.recargo_pago
  FROM core.pedidos p
  JOIN core.unidades u        ON u.id = p.unidad_id
  JOIN core.tipos_pedido tp   ON tp.id = p.tipo_pedido_id
  JOIN core.estados_pedido ep ON ep.id = p.estado_pedido_id
  JOIN core.estados_pago pg   ON pg.id = p.estado_pago_id
  JOIN core.metodos_pago mp   ON mp.id = p.metodo_pago_id
  LEFT JOIN core.mesas me           ON me.id = p.mesa_id
  LEFT JOIN core.clientes cl        ON cl.id = p.cliente_id
  LEFT JOIN core.zonas_domicilio z  ON z.id = p.zona_domicilio_id
  LEFT JOIN core.usuarios us        ON us.id = p.tomado_por_id
  LEFT JOIN LATERAL (
        SELECT SUM(i.precio_unitario * i.cantidad) AS subtotal, SUM(i.cantidad) AS unidades
          FROM core.pedido_items i WHERE i.pedido_id = p.id
  ) it ON TRUE;


/* ============================================================================
   4. EL PANEL VE LA CONFIGURACIÓN

   OJO: NO es el texto de 15_fase2_configuracion_plataforma.sql. Esa vista
   creció después —migraciones posteriores le añadieron n_unidades,
   n_usuarios y patron, y le cambiaron el orden— y CREATE OR REPLACE VIEW
   no deja quitar columnas ni reordenarlas. Esto es la vista TAL COMO ESTÁ
   instalada, cambiando sólo los dos campos nuevos de `metodos_pago`.

   Si vuelve a crecer, hay que traer otra vez su definición real:
     SELECT pg_get_viewdef('api.v_empresa_ficha'::regclass, true);
   ============================================================================ */
CREATE OR REPLACE VIEW api.v_empresa_ficha AS
SELECT e.id AS empresa_id,
       e.codigo,
       e.nombre_comercial,
       e.razon_social,
       e.nit,
       e.eslogan,
       e.descripcion,
       e.estado,
       e.hora_corte_operativa,
       e.telefono,
       e.whatsapp,
       e.email,
       e.direccion,
       e.horario_general,
       e.instagram_url,
       e.facebook_url,
       e.tiempo_mesa,
       e.tiempo_domicilio,
       e.color_primario,
       e.color_secundario,
       e.color_acento,
       e.color_fondo,
       e.tipografia,
       e.logo_texto,
       e.logo_acento,
       e.iniciales,
       e.lema,
       e.plantilla,
       e.creado_en,
       core.fn_fecha_operativa(e.id, now()) AS jornada_actual,
       (SELECT i.actualizado_en FROM core.empresa_imagenes i WHERE i.empresa_id = e.id) AS imagenes_version,
       (SELECT jsonb_object_agg(m.modulo, m.activo) FROM api.v_empresa_modulos m WHERE m.empresa_id = e.id) AS modulos,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('codigo', mp.codigo, 'nombre', mp.nombre, 'grupo', mp.grupo_caja,
                                                     'descripcion', emp.descripcion, 'activo', emp.activo,
                                                     'recargo', emp.recargo, 'recargo_tipo', emp.recargo_tipo)
                                  ORDER BY emp.orden, mp.id)
                   FROM core.empresa_metodos_pago emp
                   JOIN core.metodos_pago mp ON mp.id = emp.metodo_pago_id
                  WHERE emp.empresa_id = e.id), '[]'::jsonb) AS metodos_pago,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('entidad', c.entidad, 'numero', c.numero, 'titular', c.titular)
                                  ORDER BY c.id)
                   FROM core.cuentas_recaudo c
                  WHERE c.empresa_id = e.id AND c.activa), '[]'::jsonb) AS cuentas,
       (SELECT count(*) FROM core.unidades u  WHERE u.empresa_id  = e.id) AS n_unidades,
       (SELECT count(*) FROM core.usuarios us WHERE us.empresa_id = e.id) AS n_usuarios,
       e.patron
  FROM core.empresas e;


/* ============================================================================
   4b. GUARDAR LA CONFIGURACIÓN

   Mismo procedimiento que 15_fase2_configuracion_plataforma.sql con los dos
   campos nuevos. Si no llegan —una página vieja en caché— se deja lo que ya
   había en vez de ponerlo en cero: un recargo configurado no se borra por
   guardar otra cosa desde otra pestaña.
   ============================================================================ */
CREATE OR REPLACE PROCEDURE api.sp_guardar_metodos_pago(p_empresa_id INTEGER, p_usuario_id INTEGER, p_metodos JSONB)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, public
AS $$
DECLARE
    v JSONB;
    v_orden SMALLINT := 0;
BEGIN
    PERFORM core.fn_preparar_operacion(p_usuario_id, 'config_pagos');
    PERFORM core.fn_exigir_empresa_propia(p_usuario_id, p_empresa_id);

    FOR v IN SELECT * FROM jsonb_array_elements(COALESCE(p_metodos, '[]')) LOOP
        v_orden := v_orden + 1;
        IF NOT EXISTS (SELECT 1 FROM core.metodos_pago WHERE codigo = v ->> 'codigo') THEN
            RAISE EXCEPTION 'El método de pago "%" no existe.', v ->> 'codigo';
        END IF;
        INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo, descripcion, orden,
                                               recargo, recargo_tipo)
        VALUES (p_empresa_id, core.fn_id_catalogo('metodos_pago', v ->> 'codigo'),
                COALESCE((v ->> 'activo')::BOOLEAN, TRUE), core.fn_texto(v ->> 'descripcion', 250), v_orden,
                GREATEST(COALESCE((v ->> 'recargo')::NUMERIC, 0), 0),
                CASE WHEN v ->> 'recargo_tipo' = 'porcentaje' THEN 'porcentaje' ELSE 'fijo' END)
        ON CONFLICT (empresa_id, metodo_pago_id) DO UPDATE
           SET activo = EXCLUDED.activo,
               descripcion = COALESCE(EXCLUDED.descripcion, core.empresa_metodos_pago.descripcion),
               recargo = CASE WHEN v ? 'recargo' THEN EXCLUDED.recargo
                              ELSE core.empresa_metodos_pago.recargo END,
               recargo_tipo = CASE WHEN v ? 'recargo_tipo' THEN EXCLUDED.recargo_tipo
                                   ELSE core.empresa_metodos_pago.recargo_tipo END;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago WHERE empresa_id = p_empresa_id AND activo) THEN
        RAISE EXCEPTION 'Tiene que quedar al menos un método de pago activo.';
    END IF;
END;
$$;


/* ============================================================================
   5. AL CREAR EL PEDIDO

   Después del CALL, que es cuando ya existen los ítems y hay subtotal.

   HAY DOS VERSIONES de rest.crear_pedido y se parchean LAS DOS: la de 11
   parámetros y la de 12 con `p_clave`, que añadió
   23_pedidos_sin_duplicados.sql. La aplicación manda p_clave, así que usa
   la de 12 — parchear sólo la de 11 deja el recargo en una función que
   nadie llama, y eso no se nota hasta que alguien pregunta por qué los
   totales no traen el recargo.
   ============================================================================ */
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
    p_paga_con          NUMERIC DEFAULT NULL
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
        p_paga_con => p_paga_con, p_pedido_id => v_id, p_codigo => v_codigo);

    /* El recargo del método, congelado. Va aquí y no dentro del
       procedimiento porque necesita el subtotal, que no existe hasta que
       ese procedimiento termina de insertar los ítems. */
    UPDATE core.pedidos p
       SET recargo_pago = core.fn_recargo_pago(
               p.empresa_id, p.metodo_pago_id,
               COALESCE((SELECT SUM(i.precio_unitario * i.cantidad)
                           FROM core.pedido_items i WHERE i.pedido_id = p.id), 0)
               + p.costo_domicilio)
     WHERE p.id = v_id;

    RETURN core.fn_pedido_json(v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION rest.crear_pedido(INTEGER, TEXT, TEXT, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC)
      TO taseca_anon, taseca_app;


/* La versión de 12 parámetros, que es la que llama la aplicación. */
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

    /* Con `clave` repetida sp_crear_pedido devuelve el pedido que YA
       existía en vez de crear otro; el recargo que saldría es el mismo, y
       el IS DISTINCT FROM evita reescribirlo. Reintentar no mueve una
       factura. */
    UPDATE core.pedidos p
       SET recargo_pago = core.fn_recargo_pago(
               p.empresa_id, p.metodo_pago_id,
               COALESCE((SELECT SUM(i.precio_unitario * i.cantidad)
                           FROM core.pedido_items i WHERE i.pedido_id = p.id), 0)
               + p.costo_domicilio)
     WHERE p.id = v_id
       AND p.recargo_pago IS DISTINCT FROM core.fn_recargo_pago(
               p.empresa_id, p.metodo_pago_id,
               COALESCE((SELECT SUM(i.precio_unitario * i.cantidad)
                           FROM core.pedido_items i WHERE i.pedido_id = p.id), 0)
               + p.costo_domicilio);

    RETURN core.fn_pedido_json(v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION rest.crear_pedido(INTEGER, TEXT, TEXT, JSONB, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC, TEXT)
      TO taseca_anon, taseca_app;


/* ============================================================================
   6. COMPROBACIÓN
   ============================================================================ */
DO $$
DECLARE
    v_fijo NUMERIC;
    v_pct  NUMERIC;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'core' AND table_name = 'pedidos'
                      AND column_name = 'recargo_pago') THEN
        RAISE EXCEPTION 'Falta core.pedidos.recargo_pago: revisa el paso 1.';
    END IF;

    /* La regla, con números a mano: 3% de 20.000 son 600, y un fijo es un
       fijo pase lo que pase con la base. */
    SELECT round(20000 * 3 / 100.0), 1500 INTO v_pct, v_fijo;
    IF v_pct <> 600 THEN
        RAISE EXCEPTION 'El porcentaje no cuadra: 3%% de 20000 dio %.', v_pct;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_recargo_pago'
                     AND pronamespace = 'core'::regnamespace) THEN
        RAISE EXCEPTION 'Falta core.fn_recargo_pago: revisa el paso 2.';
    END IF;

    IF pg_get_viewdef('api.v_pedidos'::regclass) NOT LIKE '%recargo_pago%' THEN
        RAISE EXCEPTION 'api.v_pedidos no incluye el recargo en el total.';
    END IF;

    /* Las DOS versiones de rest.crear_pedido, o el recargo se queda en la
       que no se usa. */
    IF (SELECT count(*) FROM pg_proc p
         WHERE p.proname = 'crear_pedido' AND p.pronamespace = 'rest'::regnamespace
           AND pg_get_functiondef(p.oid) LIKE '%fn_recargo_pago%') <> 2 THEN
        RAISE EXCEPTION 'Alguna versión de rest.crear_pedido se quedó sin calcular el recargo.';
    END IF;

    RAISE NOTICE '✔ El recargo por método queda configurable, y en 0 para todos.';
    RAISE NOTICE '  Se pone en Configuración → Métodos de pago, por método.';
END;
$$;
