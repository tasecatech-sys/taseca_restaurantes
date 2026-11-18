/* ============================================================================
   45 · EL MENÚ DEL CHEF PUEDE PEDIR ACOMPAÑAMIENTOS

   QUÉ ES
   ------
   En el «menú del chef» cada plato es completo y se agrega directo. Algunos
   restaurantes, sin embargo, incluyen con cada plato una sopa y una bebida
   que el CLIENTE elige. Eso ya existía solo para el «menú armado».

   Esta migración abre esa posibilidad al menú del chef, de forma OPCIONAL y
   por menú: un interruptor `pide_acompanamientos` en cada menú del día.
   Apagado por defecto → el menú del chef se comporta EXACTAMENTE como hoy, así
   que NASCAR y cualquier otro no cambian en nada.

   Reusa toda la maquinaria que ya existe para el armado: los grupos
   (menu_categorias) con sus opciones (menu_opciones), el guardado en
   pedido_item_opciones, la validación de obligatorias y el renglón del ticket.

   QUÉ SE HACE
   -----------
     1. `core.menus_dia.pide_acompanamientos BOOLEAN NOT NULL DEFAULT FALSE`.
     2. Las vistas `api.v_menu_dia` y `rest.menus_dia` publican el campo para
        que el panel y el portal sepan si hay que ofrecer la elección.
     3. `api.sp_crear_pedido`: la parte de opciones, hoy atada a las líneas con
        `menu_dia_id` (armado), se generaliza. Ahora una línea del chef
        (`plato_dia_id`) también guarda y valida sus opciones cuando su menú
        tiene `pide_acompanamientos`. El armado queda idéntico.

   NO se toca `sp_guardar_menu_dia`: su ON CONFLICT no pisa el flag, así que
   editar un menú lo conserva. El editor del panel (prender el flag y manejar
   los grupos) va en un paso aparte.

   Idempotente. Requiere: 00–17 y la 11 (rest.menus_dia).
   ============================================================================ */

/* ----------------------------------------------------------------------------
   1. EL INTERRUPTOR, POR MENÚ
   ---------------------------------------------------------------------------- */
ALTER TABLE core.menus_dia
    ADD COLUMN IF NOT EXISTS pide_acompanamientos BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN core.menus_dia.pide_acompanamientos IS
    'Menú del chef: si es TRUE, el cliente elige los acompañamientos (grupos menu_categorias). Ver database/45_chef_con_acompanamientos.sql.';


/* ----------------------------------------------------------------------------
   2. LAS VISTAS PUBLICAN EL CAMPO
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW api.v_menu_dia AS
SELECT m.id AS menu_dia_id, m.unidad_id, u.empresa_id, u.nombre AS unidad, m.fecha,
       t.codigo AS tipo, t.nombre AS tipo_nombre,
       m.nombre, m.descripcion, m.precio, m.disponible,
       COALESCE(m.titulo_publico, tx.titulo, 'Menú del día')                          AS titulo_publico,
       COALESCE(m.mensaje_publico, tx.mensaje, 'Consulta las opciones disponibles para hoy.') AS mensaje_publico,
       CASE WHEN m.titulo_publico IS NOT NULL THEN 'fecha'
            WHEN tx.titulo IS NOT NULL THEN 'unidad' ELSE 'defecto' END                AS origen_texto,
       CASE
           WHEN NOT m.disponible THEN FALSE
           WHEN t.codigo = 'armado' THEN m.precio IS NOT NULL AND EXISTS (
                SELECT 1 FROM core.menu_categorias c JOIN core.menu_opciones o ON o.menu_categoria_id = c.id
                 WHERE c.menu_dia_id = m.id AND c.activa AND o.activa)
           ELSE EXISTS (SELECT 1 FROM core.platos_dia pd WHERE pd.menu_dia_id = m.id AND pd.disponible)
       END AS publicado,
       m.creado_en, m.actualizado_en,
       m.pide_acompanamientos
  FROM core.menus_dia m
  JOIN core.unidades u   ON u.id = m.unidad_id
  JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
  LEFT JOIN core.textos_menu_unidad tx ON tx.unidad_id = m.unidad_id;

CREATE OR REPLACE VIEW rest.menus_dia AS
SELECT m.id AS menu_dia_id, u.empresa_id, m.unidad_id, m.fecha, t.codigo AS tipo,
       m.nombre, m.descripcion, m.precio, m.disponible,
       m.titulo_publico AS titulo_fecha, m.mensaje_publico AS mensaje_fecha,
       COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'categoria_id', c.id, 'nombre', c.nombre, 'icono', c.icono, 'orden', c.orden,
                          'obligatoria', c.obligatoria, 'max_seleccion', c.max_seleccion, 'activa', c.activa,
                          'opciones', COALESCE((SELECT jsonb_agg(jsonb_build_object('opcion_id', o.id, 'nombre', o.nombre,
                                                                                    'orden', o.orden, 'activa', o.activa)
                                                                 ORDER BY o.orden)
                                                  FROM core.menu_opciones o WHERE o.menu_categoria_id = c.id), '[]'))
                      ORDER BY c.orden)
                   FROM core.menu_categorias c WHERE c.menu_dia_id = m.id), '[]') AS categorias,
       COALESCE((SELECT jsonb_agg(jsonb_build_object(
                          'plato_dia_id', p.plato_dia_id, 'nombre', p.nombre, 'descripcion', p.descripcion,
                          'emoji', p.emoji, 'precio', p.precio, 'cupos', p.cupos, 'vendidos', p.vendidos,
                          'disponible', p.disponible, 'orden', p.orden,
                          'sopa', p.incluye_sopa, 'principio', p.incluye_principio,
                          'proteina', p.incluye_proteina, 'bebida', p.incluye_bebida)
                      ORDER BY p.orden)
                   FROM api.v_platos_dia p WHERE p.menu_dia_id = m.id), '[]') AS platos,
       m.pide_acompanamientos
  FROM core.menus_dia m
  JOIN core.unidades u   ON u.id = m.unidad_id
  JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
 WHERE m.fecha BETWEEN core.fn_fecha_operativa(u.empresa_id, now()) - 7
                   AND core.fn_fecha_operativa(u.empresa_id, now()) + 14;


/* ----------------------------------------------------------------------------
   3. EL PEDIDO GUARDA Y VALIDA OPCIONES TAMBIÉN EN EL CHEF

   Misma firma, mismo cuerpo que en producción, con un solo cambio: donde antes
   decía «si la línea trae menu_dia_id» (armado), ahora se calcula el menú de
   la línea -el de armado, o el del plato del chef- y se aplican las opciones
   cuando es armado O cuando el menú del chef pide acompañamientos.
   ---------------------------------------------------------------------------- */
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

        CALL api.sp_actualizar_pago(p_pedido_id, 'confirmado', p_usuario_id, NULL, p_metodo_pago);
    END IF;
END;
$procedure$;


/* ----------------------------------------------------------------------------
   3b. EL GUARDIÁN DE INTEGRIDAD DE OPCIONES TAMBIÉN ENTIENDE AL CHEF

   tg_item_opciones_antes valida que cada opción pertenezca al menú del ítem y
   que no se pase del máximo. Derivaba el menú SOLO de `menu_dia_id` (armado) y
   rechazaba lo demás con «Sólo un ítem de menú armado lleva opciones». Ahora el
   menú del ítem también se deriva del plato del chef (plato_dia → menu_dia).
   Lleva su search_path fijo (lo puso la 43; CREATE OR REPLACE lo borraría).
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.tg_item_opciones_antes()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = core, public
AS $$
DECLARE
    v_menu_item  BIGINT;
    v_menu_op    BIGINT;
    v_categoria  BIGINT;
    v_max        SMALLINT;
    v_nombre_cat VARCHAR;
    v_activa     BOOLEAN;
BEGIN
    /* El menú del ítem: el del armado (menu_dia_id) o el del plato del chef. */
    SELECT COALESCE(pi.menu_dia_id, pd.menu_dia_id)
      INTO v_menu_item
      FROM core.pedido_items pi
      LEFT JOIN core.platos_dia pd ON pd.id = pi.plato_dia_id
     WHERE pi.id = NEW.pedido_item_id;

    SELECT c.menu_dia_id, c.id, c.max_seleccion, c.nombre, (o.activa AND c.activa)
      INTO v_menu_op, v_categoria, v_max, v_nombre_cat, v_activa
      FROM core.menu_opciones o
      JOIN core.menu_categorias c ON c.id = o.menu_categoria_id
     WHERE o.id = NEW.menu_opcion_id;

    IF v_menu_item IS NULL THEN
        RAISE EXCEPTION 'Este ítem no admite opciones.';
    ELSIF v_menu_item <> v_menu_op THEN
        RAISE EXCEPTION 'La opción % no pertenece al menú del ítem.', NEW.menu_opcion_id;
    ELSIF NOT v_activa THEN
        RAISE EXCEPTION 'La opción elegida ya no está disponible.';
    END IF;

    IF (SELECT count(*)
          FROM core.pedido_item_opciones x
          JOIN core.menu_opciones o ON o.id = x.menu_opcion_id
         WHERE x.pedido_item_id = NEW.pedido_item_id
           AND o.menu_categoria_id = v_categoria
           AND x.id IS DISTINCT FROM NEW.id) >= v_max THEN
        RAISE EXCEPTION 'Puedes elegir máximo % opción(es) de %.', v_max, v_nombre_cat;
    END IF;

    RETURN NEW;
END;
$$;


/* ----------------------------------------------------------------------------
   3c. LA INTEGRIDAD MULTIEMPRESA TAMBIÉN ENTIENDE AL CHEF

   tg_relaciones_empresa valida, entre muchas cosas, que una opción pertenezca
   al menú del ítem. Derivaba el menú del ítem solo de `menu_dia_id`; ahora
   también del plato del chef. Es la MISMA función de la 22, con esa única rama
   generalizada; conserva su search_path (lo fijó la 43).
   ---------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION core.tg_relaciones_empresa()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'core', 'public'
AS $function$
DECLARE
    v_empresa INTEGER;   -- empresa a la que pertenece la fila
    v_unidad  INTEGER;   -- unidad a la que pertenece la fila
    v_otra    INTEGER;
BEGIN
    CASE TG_TABLE_NAME

    WHEN 'pedidos' THEN
        IF NEW.empresa_id <> core.fn_empresa_de_unidad(NEW.unidad_id) THEN
            RAISE EXCEPTION 'La factura % sería de una empresa distinta a la de su unidad.', NEW.codigo
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.mesa_id IS NOT NULL
           AND (SELECT unidad_id FROM core.mesas WHERE id = NEW.mesa_id) <> NEW.unidad_id THEN
            RAISE EXCEPTION 'Esa mesa es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.zona_domicilio_id IS NOT NULL
           AND (SELECT unidad_id FROM core.zonas_domicilio WHERE id = NEW.zona_domicilio_id) <> NEW.unidad_id THEN
            RAISE EXCEPTION 'Esa zona de domicilio es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.cliente_id IS NOT NULL
           AND (SELECT empresa_id FROM core.clientes WHERE id = NEW.cliente_id) <> NEW.empresa_id THEN
            RAISE EXCEPTION 'Ese cliente es de otra empresa.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.tomado_por_id;
        IF v_otra IS NOT NULL AND v_otra <> NEW.empresa_id THEN
            RAISE EXCEPTION 'Ese usuario no es de la empresa de la factura.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'pedido_items' THEN
        SELECT p.empresa_id, p.unidad_id INTO v_empresa, v_unidad
          FROM core.pedidos p WHERE p.id = NEW.pedido_id;
        IF NEW.producto_id IS NOT NULL
           AND (SELECT empresa_id FROM core.productos WHERE id = NEW.producto_id) <> v_empresa THEN
            RAISE EXCEPTION 'Ese producto es de otra empresa.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.plato_dia_id IS NOT NULL
           AND (SELECT md.unidad_id FROM core.platos_dia pd JOIN core.menus_dia md ON md.id = pd.menu_dia_id
                 WHERE pd.id = NEW.plato_dia_id) <> v_unidad THEN
            RAISE EXCEPTION 'Ese plato del día es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        IF NEW.menu_dia_id IS NOT NULL
           AND (SELECT unidad_id FROM core.menus_dia WHERE id = NEW.menu_dia_id) <> v_unidad THEN
            RAISE EXCEPTION 'Ese menú es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'pedido_item_opciones' THEN
        /* El menú del ítem: armado (menu_dia_id) o plato del chef (plato_dia). */
        SELECT COALESCE(i.menu_dia_id, pd.menu_dia_id) INTO v_otra
          FROM core.pedido_items i
          LEFT JOIN core.platos_dia pd ON pd.id = i.plato_dia_id
         WHERE i.id = NEW.pedido_item_id;
        IF (SELECT mc.menu_dia_id FROM core.menu_opciones mo
              JOIN core.menu_categorias mc ON mc.id = mo.menu_categoria_id
             WHERE mo.id = NEW.menu_opcion_id) IS DISTINCT FROM v_otra THEN
            RAISE EXCEPTION 'Esa opción no es del menú de ese ítem.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'entradas_inventario' THEN
        SELECT iu.unidad_id INTO v_unidad FROM core.insumo_unidades iu WHERE iu.id = NEW.insumo_unidad_id;
        IF NEW.pedido_id IS NOT NULL
           AND (SELECT unidad_id FROM core.pedidos WHERE id = NEW.pedido_id) <> v_unidad THEN
            RAISE EXCEPTION 'Esa factura es de otra unidad.' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.usuario_id;
        IF v_otra IS NOT NULL AND v_otra <> core.fn_empresa_de_unidad(v_unidad) THEN
            RAISE EXCEPTION 'Ese usuario no es de la empresa de la unidad.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'cierre_detalles' THEN
        SELECT ci.unidad_id INTO v_unidad FROM core.cierres_inventario ci WHERE ci.id = NEW.cierre_id;
        IF (SELECT unidad_id FROM core.insumo_unidades WHERE id = NEW.insumo_unidad_id) <> v_unidad THEN
            RAISE EXCEPTION 'Ese producto no es de la unidad del cierre.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'bases_caja' THEN
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.usuario_id;
        IF v_otra IS NOT NULL AND v_otra <> core.fn_empresa_de_unidad(NEW.unidad_id) THEN
            RAISE EXCEPTION 'Ese usuario no es de la empresa de la unidad.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'cierres_inventario' THEN
        v_empresa := core.fn_empresa_de_unidad(NEW.unidad_id);
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.registrado_por_id;
        IF v_otra IS NOT NULL AND v_otra <> v_empresa THEN
            RAISE EXCEPTION 'Quien registra el cierre no es de la empresa de la unidad.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.revisado_por_id;
        IF v_otra IS NOT NULL AND v_otra <> v_empresa THEN
            RAISE EXCEPTION 'Quien revisa el cierre no es de la empresa de la unidad.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'menus_dia' THEN
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.creado_por_id;
        IF v_otra IS NOT NULL AND v_otra <> core.fn_empresa_de_unidad(NEW.unidad_id) THEN
            RAISE EXCEPTION 'Quien crea el menú no es de la empresa de la unidad.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'pedido_historial' THEN
        SELECT empresa_id INTO v_empresa FROM core.pedidos WHERE id = NEW.pedido_id;
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.usuario_id;
        IF v_otra IS NOT NULL AND v_otra <> v_empresa THEN
            RAISE EXCEPTION 'Ese movimiento lo firma un usuario de otra empresa.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'comprobantes_pago' THEN
        SELECT empresa_id INTO v_empresa FROM core.pedidos WHERE id = NEW.pedido_id;
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.revisado_por_id;
        IF v_otra IS NOT NULL AND v_otra <> v_empresa THEN
            RAISE EXCEPTION 'Ese comprobante lo revisa un usuario de otra empresa.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    WHEN 'anulaciones' THEN
        SELECT empresa_id INTO v_empresa FROM core.pedidos WHERE id = NEW.pedido_id;
        SELECT empresa_id INTO v_otra FROM core.usuarios WHERE id = NEW.usuario_id;
        IF v_otra IS NOT NULL AND v_otra <> v_empresa THEN
            RAISE EXCEPTION 'Esa anulación la firma un usuario de otra empresa.'
                  USING ERRCODE = 'integrity_constraint_violation';
        END IF;

    ELSE
        RAISE EXCEPTION 'tg_relaciones_empresa no está preparado para %', TG_TABLE_NAME;
    END CASE;

    RETURN NEW;
END;
$function$;


/* ----------------------------------------------------------------------------
   4. REVISIÓN (texto y estructura; el comportamiento se prueba aparte)
   ---------------------------------------------------------------------------- */
DO $$
DECLARE v_def TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='core' AND table_name='menus_dia' AND column_name='pide_acompanamientos') THEN
        RAISE EXCEPTION 'No se añadió core.menus_dia.pide_acompanamientos.';
    END IF;
    IF (SELECT pg_get_viewdef('rest.menus_dia'::regclass, true)) NOT LIKE '%pide_acompanamientos%' THEN
        RAISE EXCEPTION 'rest.menus_dia no publica el campo.';
    END IF;
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='api' AND p.proname='sp_crear_pedido';
    IF v_def NOT LIKE '%pide_acompanamientos%' THEN
        RAISE EXCEPTION 'sp_crear_pedido no quedó generalizado.';
    END IF;
    RAISE NOTICE 'OK · el menú del chef puede pedir acompañamientos (apagado por defecto).';
END $$;

NOTIFY pgrst, 'reload schema';
