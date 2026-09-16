/* ============================================================================
   TASECA · 03 · TRIGGERS
   ----------------------------------------------------------------------------
   Las reglas del negocio viven en la base, no sólo en la pantalla: aunque
   alguien escriba directo en la tabla, la regla se cumple.

     · actualizado_en automático
     · auditoría de las tablas sensibles
     · aislamiento multiempresa (nada se cruza entre empresas)
     · unidad inactiva = sin operación nueva; nunca sin unidades activas
     · pedidos: código, jornada, flujo de estados, historial, inmutabilidad
     · ítems: producto de la unidad, cupos, menú armado con su máximo
     · cierres revisados intocables; entradas que suman al stock
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. GENÉRICOS
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_actualizado_en()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.actualizado_en := now();
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN
        SELECT c.table_name
          FROM information_schema.columns c
          JOIN information_schema.tables tb
            ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
         WHERE c.table_schema = 'core'
           AND c.column_name = 'actualizado_en'
           AND tb.table_type = 'BASE TABLE'
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_actualizado_en BEFORE UPDATE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_actualizado_en()', t.table_name);
    END LOOP;
END;
$$;


/* Auditoría: guarda la fila antes y después. Del usuario nunca se guarda el
   hash del PIN. */
CREATE OR REPLACE FUNCTION core.tg_auditoria()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_antes   JSONB;
    v_despues JSONB;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_antes   := to_jsonb(OLD) - 'pin_hash'; END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN v_despues := to_jsonb(NEW) - 'pin_hash'; END IF;

    IF TG_OP = 'UPDATE' AND v_antes - 'actualizado_en' = v_despues - 'actualizado_en' THEN
        RETURN NEW; -- nada cambió de verdad
    END IF;

    INSERT INTO core.auditoria (tabla, registro_id, accion, datos_antes, datos_despues, usuario_id)
    VALUES (TG_TABLE_NAME,
            COALESCE((v_despues ->> 'id'), (v_antes ->> 'id'))::BIGINT,
            TG_OP, v_antes, v_despues, core.fn_usuario_actual());

    RETURN COALESCE(NEW, OLD);
END;
$$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['empresas', 'empresa_modulos', 'unidades', 'usuarios', 'productos',
                             'insumo_unidades', 'pedidos', 'anulaciones', 'gastos', 'bases_caja',
                             'cierres_inventario', 'entradas_inventario', 'rol_permisos']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_auditoria AFTER INSERT OR UPDATE OR DELETE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_auditoria()', t);
    END LOOP;
END;
$$;


/* ============================================================================
   2. AISLAMIENTO MULTIEMPRESA
   Las tablas de relación unen cosas que deben ser de la MISMA empresa: una
   categoría de NASCAR no puede asignarse a una unidad de otra empresa.
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_misma_empresa()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_a INTEGER;
    v_b INTEGER;
BEGIN
    CASE TG_TABLE_NAME
        WHEN 'categoria_unidades' THEN
            SELECT empresa_id INTO v_a FROM core.categorias WHERE id = NEW.categoria_id;
            v_b := core.fn_empresa_de_unidad(NEW.unidad_id);
        WHEN 'producto_unidades' THEN
            SELECT empresa_id INTO v_a FROM core.productos WHERE id = NEW.producto_id;
            v_b := core.fn_empresa_de_unidad(NEW.unidad_id);
        WHEN 'insumo_unidades' THEN
            SELECT empresa_id INTO v_a FROM core.insumos WHERE id = NEW.insumo_id;
            v_b := core.fn_empresa_de_unidad(NEW.unidad_id);
        WHEN 'usuario_unidades' THEN
            SELECT empresa_id INTO v_a FROM core.usuarios WHERE id = NEW.usuario_id;
            v_b := core.fn_empresa_de_unidad(NEW.unidad_id);
        WHEN 'productos' THEN
            v_a := NEW.empresa_id;
            SELECT empresa_id INTO v_b FROM core.categorias WHERE id = NEW.categoria_id;
        WHEN 'insumos' THEN
            v_a := NEW.empresa_id;
            SELECT empresa_id INTO v_b FROM core.categorias_insumo WHERE id = NEW.categoria_insumo_id;
        WHEN 'producto_insumos' THEN
            SELECT empresa_id INTO v_a FROM core.productos WHERE id = NEW.producto_id;
            SELECT empresa_id INTO v_b FROM core.insumos   WHERE id = NEW.insumo_id;
        WHEN 'gastos' THEN
            v_a := core.fn_empresa_de_unidad(NEW.unidad_id);
            SELECT empresa_id INTO v_b FROM core.categorias_gasto WHERE id = NEW.categoria_gasto_id;
        ELSE
            RAISE EXCEPTION 'tg_misma_empresa no está preparado para %', TG_TABLE_NAME;
    END CASE;

    IF v_a IS DISTINCT FROM v_b THEN
        RAISE EXCEPTION 'En % se intentó unir registros de empresas distintas (% y %).',
                        TG_TABLE_NAME, v_a, v_b
              USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['categoria_unidades', 'producto_unidades', 'insumo_unidades',
                             'usuario_unidades', 'productos', 'insumos', 'producto_insumos', 'gastos']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_misma_empresa BEFORE INSERT OR UPDATE ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_misma_empresa()', t);
    END LOOP;
END;
$$;


/* ============================================================================
   3. USUARIOS Y UNIDADES
   ============================================================================ */

/* Un usuario de plataforma no pertenece a ninguna empresa; uno de empresa
   siempre pertenece a una. */
CREATE OR REPLACE FUNCTION core.tg_usuarios_alcance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_alcance VARCHAR;
BEGIN
    SELECT alcance INTO v_alcance FROM core.roles WHERE id = NEW.rol_id;
    IF v_alcance = 'plataforma' AND NEW.empresa_id IS NOT NULL THEN
        RAISE EXCEPTION 'Un usuario de plataforma no pertenece a ninguna empresa.';
    ELSIF v_alcance = 'empresa' AND NEW.empresa_id IS NULL THEN
        RAISE EXCEPTION 'El usuario "%" necesita una empresa.', NEW.usuario;
    END IF;
    NEW.usuario := lower(trim(NEW.usuario));
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_usuarios_alcance
    BEFORE INSERT OR UPDATE OF rol_id, empresa_id, usuario ON core.usuarios
    FOR EACH ROW EXECUTE FUNCTION core.tg_usuarios_alcance();

/* Siempre debe quedar al menos una unidad activa en una empresa activa. */
CREATE OR REPLACE FUNCTION core.tg_unidades_minimo_activa()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.estado = 'activa' AND NEW.estado = 'inactiva'
       AND NOT EXISTS (SELECT 1 FROM core.unidades
                        WHERE empresa_id = NEW.empresa_id AND estado = 'activa' AND id <> NEW.id) THEN
        RAISE EXCEPTION 'Debe quedar al menos una unidad activa en la empresa.';
    END IF;
    IF NEW.empresa_id <> OLD.empresa_id THEN
        RAISE EXCEPTION 'Una unidad no puede cambiar de empresa.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_unidades_minimo_activa
    BEFORE UPDATE ON core.unidades
    FOR EACH ROW EXECUTE FUNCTION core.tg_unidades_minimo_activa();


/* ============================================================================
   4. PEDIDOS
   ============================================================================ */

/* Antes de crear: empresa de la unidad, código, jornada, estados iniciales y
   coherencia de mesa / zona según el tipo. */
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

    IF v_tipo = 'mesa' THEN
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

CREATE TRIGGER trg_pedidos_antes_insertar
    BEFORE INSERT ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_antes_insertar();


/* Historial al crear. */
CREATE OR REPLACE FUNCTION core.tg_pedidos_despues_insertar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO core.pedido_historial (pedido_id, estado_pedido_id, descripcion, usuario_id)
    VALUES (NEW.id, NEW.estado_pedido_id, 'Pedido recibido', core.fn_usuario_actual());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pedidos_despues_insertar
    AFTER INSERT ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_despues_insertar();


/* Antes de modificar:
     · los datos de identidad de la factura no cambian nunca
     · cancelado y anulado son finales: ya no se toca nada
     · el flujo sólo avanza (no se devuelve), «en camino» sólo en domicilio
     · entregado sólo admite pasar a anulado o cambiar el estado del pago
     · al entregar en efectivo, el pago queda confirmado */
CREATE OR REPLACE FUNCTION core.tg_pedidos_antes_actualizar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_ant   core.estados_pedido;
    v_nuevo core.estados_pedido;
    v_tipo  VARCHAR;
BEGIN
    IF NEW.empresa_id <> OLD.empresa_id OR NEW.unidad_id <> OLD.unidad_id
       OR NEW.codigo <> OLD.codigo OR NEW.fecha_operativa <> OLD.fecha_operativa
       OR NEW.tipo_pedido_id <> OLD.tipo_pedido_id OR NEW.creado_en <> OLD.creado_en THEN
        RAISE EXCEPTION 'La factura % no puede cambiar de empresa, unidad, código, tipo ni jornada.', OLD.codigo;
    END IF;

    SELECT * INTO v_ant   FROM core.estados_pedido WHERE id = OLD.estado_pedido_id;
    SELECT * INTO v_nuevo FROM core.estados_pedido WHERE id = NEW.estado_pedido_id;
    SELECT codigo INTO v_tipo FROM core.tipos_pedido WHERE id = NEW.tipo_pedido_id;

    IF v_ant.codigo IN ('cancelado', 'anulado') THEN
        RAISE EXCEPTION 'La factura % está % y ya no se puede modificar.', OLD.codigo, lower(v_ant.nombre);
    END IF;

    IF NEW.estado_pedido_id <> OLD.estado_pedido_id THEN
        IF v_nuevo.codigo = 'anulado' AND NOT EXISTS (SELECT 1 FROM core.anulaciones WHERE pedido_id = OLD.id) THEN
            RAISE EXCEPTION 'Una factura sólo se anula con api.sp_anular_pedido (motivo y retorno de inventario).';
        END IF;
        IF v_nuevo.solo_domicilio AND v_tipo <> 'domicilio' THEN
            RAISE EXCEPTION 'El estado "%" sólo aplica a domicilios.', v_nuevo.nombre;
        END IF;
        IF v_nuevo.orden < 90 AND v_nuevo.orden <= v_ant.orden THEN
            RAISE EXCEPTION 'El pedido % no puede volver de "%" a "%".', OLD.codigo, v_ant.nombre, v_nuevo.nombre;
        END IF;
        IF v_ant.codigo = 'entregado' AND v_nuevo.codigo <> 'anulado' THEN
            RAISE EXCEPTION 'Un pedido entregado sólo puede anularse.';
        END IF;
        IF v_nuevo.codigo = 'cancelado' AND (NEW.motivo_cancelacion IS NULL OR length(trim(NEW.motivo_cancelacion)) < 3) THEN
            RAISE EXCEPTION 'Para cancelar hay que escribir el motivo.';
        END IF;
        IF v_nuevo.codigo = 'entregado'
           AND (SELECT codigo FROM core.metodos_pago WHERE id = NEW.metodo_pago_id) = 'efectivo' THEN
            NEW.estado_pago_id := core.fn_id_catalogo('estados_pago', 'confirmado');
        END IF;
    ELSIF v_ant.codigo = 'entregado'
          AND (NEW.metodo_pago_id <> OLD.metodo_pago_id
               OR NEW.cliente_id IS DISTINCT FROM OLD.cliente_id
               OR NEW.direccion_entrega IS DISTINCT FROM OLD.direccion_entrega
               OR NEW.costo_domicilio <> OLD.costo_domicilio) THEN
        RAISE EXCEPTION 'La factura % ya fue entregada: sólo puede cambiar el estado del pago.', OLD.codigo;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pedidos_antes_actualizar
    BEFORE UPDATE ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_antes_actualizar();

/* Las facturas no se borran (salvo la limpieza de pruebas, que usa su
   procedimiento y lo declara en la sesión). */
CREATE OR REPLACE FUNCTION core.tg_pedidos_no_borrar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('taseca.borrado_pruebas', TRUE) = 'si' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'Las facturas no se borran: se cancelan o se anulan (factura %).', OLD.codigo;
END;
$$;

CREATE TRIGGER trg_pedidos_no_borrar
    BEFORE DELETE ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_no_borrar();

/* Historial en cada cambio de estado o de pago. */
CREATE OR REPLACE FUNCTION core.tg_pedidos_historial()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.estado_pedido_id <> OLD.estado_pedido_id THEN
        INSERT INTO core.pedido_historial (pedido_id, estado_pedido_id, descripcion, usuario_id)
        SELECT NEW.id, NEW.estado_pedido_id,
               'Estado: ' || e.nombre ||
               CASE WHEN e.codigo = 'cancelado' THEN ' · ' || NEW.motivo_cancelacion ELSE '' END,
               core.fn_usuario_actual()
          FROM core.estados_pedido e WHERE e.id = NEW.estado_pedido_id;
    END IF;
    IF NEW.estado_pago_id <> OLD.estado_pago_id THEN
        INSERT INTO core.pedido_historial (pedido_id, descripcion, usuario_id)
        SELECT NEW.id, 'Pago: ' || p.nombre, core.fn_usuario_actual()
          FROM core.estados_pago p WHERE p.id = NEW.estado_pago_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pedidos_historial
    AFTER UPDATE ON core.pedidos
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedidos_historial();


/* ============================================================================
   5. ÍTEMS DEL PEDIDO
   ============================================================================ */

/* Al agregar un ítem:
     · el pedido sigue siendo editable (estado nuevo)
     · producto de carta: de la unidad, activo y no agotado
     · plato del chef: del menú de la unidad, disponible y con cupo
     · menú armado: de la unidad, armado, disponible y con precio
   Nombre y precio se toman de la fuente si no vienen: es la foto de la
   factura. */
CREATE OR REPLACE FUNCTION core.tg_pedido_items_antes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_pedido  core.pedidos;
    v_estado  VARCHAR;
    v_nombre  VARCHAR;
    v_precio  NUMERIC;
    v_ok      BOOLEAN;
    v_cupos   INTEGER;
    v_otros   INTEGER := 0;
BEGIN
    SELECT * INTO v_pedido FROM core.pedidos WHERE id = COALESCE(NEW.pedido_id, OLD.pedido_id);
    SELECT codigo INTO v_estado FROM core.estados_pedido WHERE id = v_pedido.estado_pedido_id;

    IF v_estado <> 'nuevo' AND current_setting('taseca.borrado_pruebas', TRUE) IS DISTINCT FROM 'si' THEN
        RAISE EXCEPTION 'La factura % ya está en "%": sus productos no se pueden cambiar.', v_pedido.codigo, v_estado;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    IF NEW.producto_id IS NOT NULL THEN
        SELECT p.nombre, p.precio, (p.activo AND c.activa AND NOT pu.agotado)
          INTO v_nombre, v_precio, v_ok
          FROM core.productos p
          JOIN core.categorias c         ON c.id = p.categoria_id
          JOIN core.producto_unidades pu ON pu.producto_id = p.id AND pu.unidad_id = v_pedido.unidad_id
         WHERE p.id = NEW.producto_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El producto % no se vende en la unidad del pedido.', NEW.producto_id;
        ELSIF NOT v_ok THEN
            RAISE EXCEPTION '"%" no está disponible en este momento.', v_nombre;
        END IF;

    ELSIF NEW.plato_dia_id IS NOT NULL THEN
        SELECT pd.nombre, pd.precio, (pd.disponible AND m.disponible), pd.cupos
          INTO v_nombre, v_precio, v_ok, v_cupos
          FROM core.platos_dia pd
          JOIN core.menus_dia m ON m.id = pd.menu_dia_id
          JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
         WHERE pd.id = NEW.plato_dia_id
           AND m.unidad_id = v_pedido.unidad_id
           AND t.codigo = 'chef';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El plato del día % no es del menú del chef de esta unidad.', NEW.plato_dia_id;
        ELSIF NOT v_ok THEN
            RAISE EXCEPTION '"%" ya no está disponible.', v_nombre;
        END IF;
        IF v_cupos IS NOT NULL THEN
            IF TG_OP = 'UPDATE' AND OLD.plato_dia_id = NEW.plato_dia_id THEN
                v_otros := OLD.cantidad;
            END IF;
            IF core.fn_vendidos_plato(NEW.plato_dia_id) - v_otros + NEW.cantidad > v_cupos THEN
                RAISE EXCEPTION 'No quedan cupos suficientes de "%".', v_nombre;
            END IF;
        END IF;

    ELSE
        SELECT COALESCE(m.nombre, 'Menú del día'), m.precio, m.disponible
          INTO v_nombre, v_precio, v_ok
          FROM core.menus_dia m
          JOIN core.tipos_menu t ON t.id = m.tipo_menu_id
         WHERE m.id = NEW.menu_dia_id
           AND m.unidad_id = v_pedido.unidad_id
           AND t.codigo = 'armado';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El menú % no es un menú armado de esta unidad.', NEW.menu_dia_id;
        ELSIF NOT v_ok OR v_precio IS NULL THEN
            RAISE EXCEPTION 'El menú armado no está disponible o no tiene precio.';
        END IF;
    END IF;

    NEW.nombre          := COALESCE(NEW.nombre, v_nombre);
    NEW.precio_unitario := COALESCE(NEW.precio_unitario, v_precio);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pedido_items_antes
    BEFORE INSERT OR UPDATE OR DELETE ON core.pedido_items
    FOR EACH ROW EXECUTE FUNCTION core.tg_pedido_items_antes();


/* Opciones del menú armado: la opción es del menú del ítem y la categoría no
   supera su máximo (Principio = 2). */
CREATE OR REPLACE FUNCTION core.tg_item_opciones_antes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_menu_item  BIGINT;
    v_menu_op    BIGINT;
    v_categoria  BIGINT;
    v_max        SMALLINT;
    v_nombre_cat VARCHAR;
    v_activa     BOOLEAN;
BEGIN
    SELECT menu_dia_id INTO v_menu_item FROM core.pedido_items WHERE id = NEW.pedido_item_id;

    SELECT c.menu_dia_id, c.id, c.max_seleccion, c.nombre, (o.activa AND c.activa)
      INTO v_menu_op, v_categoria, v_max, v_nombre_cat, v_activa
      FROM core.menu_opciones o
      JOIN core.menu_categorias c ON c.id = o.menu_categoria_id
     WHERE o.id = NEW.menu_opcion_id;

    IF v_menu_item IS NULL THEN
        RAISE EXCEPTION 'Sólo un ítem de menú armado lleva opciones.';
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

CREATE TRIGGER trg_item_opciones_antes
    BEFORE INSERT OR UPDATE ON core.pedido_item_opciones
    FOR EACH ROW EXECUTE FUNCTION core.tg_item_opciones_antes();

/* Una opción ya vendida no cambia de nombre: la factura de ese día debe
   seguir diciendo lo que el cliente pidió. */
CREATE OR REPLACE FUNCTION core.tg_menu_opciones_vendidas()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.nombre <> OLD.nombre
       AND EXISTS (SELECT 1 FROM core.pedido_item_opciones WHERE menu_opcion_id = OLD.id) THEN
        RAISE EXCEPTION '"%" ya se vendió: no se puede renombrar. Desactívala y crea otra.', OLD.nombre;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_menu_opciones_vendidas
    BEFORE UPDATE OF nombre ON core.menu_opciones
    FOR EACH ROW EXECUTE FUNCTION core.tg_menu_opciones_vendidas();


/* ============================================================================
   6. OPERACIÓN DE LA UNIDAD (menú, caja, gastos, inventario)
   ============================================================================ */

/* Registros nuevos sólo en unidades activas, y con su jornada si no viene. */
CREATE OR REPLACE FUNCTION core.tg_operacion_unidad_activa()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_unidad INTEGER;
BEGIN
    IF TG_TABLE_NAME = 'entradas_inventario' THEN
        SELECT unidad_id INTO v_unidad FROM core.insumo_unidades WHERE id = NEW.insumo_unidad_id;
    ELSE
        v_unidad := NEW.unidad_id;
    END IF;

    PERFORM core.fn_exigir_unidad_operativa(v_unidad);

    IF TG_TABLE_NAME IN ('bases_caja', 'gastos', 'cierres_inventario', 'entradas_inventario') THEN
        NEW.fecha_operativa := COALESCE(NEW.fecha_operativa,
                                        core.fn_fecha_operativa(core.fn_empresa_de_unidad(v_unidad), now()));
    END IF;
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['menus_dia', 'bases_caja', 'gastos', 'cierres_inventario', 'entradas_inventario']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%1$s_unidad_activa BEFORE INSERT ON core.%1$I
                 FOR EACH ROW EXECUTE FUNCTION core.tg_operacion_unidad_activa()', t);
    END LOOP;
END;
$$;

/* La entrada suma al stock de la unidad. */
CREATE OR REPLACE FUNCTION core.tg_entradas_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.insumo_unidades
       SET stock_actual = stock_actual + NEW.cantidad
     WHERE id = NEW.insumo_unidad_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_entradas_stock
    AFTER INSERT ON core.entradas_inventario
    FOR EACH ROW EXECUTE FUNCTION core.tg_entradas_stock();

/* Las entradas son movimientos: no se editan ni se borran. Si una estuvo
   mal, se registra un ajuste. */
CREATE OR REPLACE FUNCTION core.tg_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF current_setting('taseca.borrado_pruebas', TRUE) = 'si' THEN
        RETURN COALESCE(OLD, NEW);
    END IF;
    RAISE EXCEPTION 'Los registros de % no se modifican ni se borran: registra un ajuste.', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER trg_entradas_inmutable
    BEFORE UPDATE OR DELETE ON core.entradas_inventario
    FOR EACH ROW EXECUTE FUNCTION core.tg_inmutable();

CREATE TRIGGER trg_anulaciones_inmutable
    BEFORE UPDATE OR DELETE ON core.anulaciones
    FOR EACH ROW EXECUTE FUNCTION core.tg_inmutable();

/* La base de caja no se edita: se corrige con una nueva. Sólo se permite
   marcarla como no vigente. */
CREATE OR REPLACE FUNCTION core.tg_bases_caja_antes_actualizar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.monto <> OLD.monto OR NEW.unidad_id <> OLD.unidad_id OR NEW.fecha_operativa <> OLD.fecha_operativa THEN
        RAISE EXCEPTION 'La base de caja no se edita: registra una corrección.';
    END IF;
    IF OLD.vigente = FALSE AND NEW.vigente = TRUE THEN
        RAISE EXCEPTION 'Una base reemplazada no vuelve a quedar vigente.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_bases_caja_antes_actualizar
    BEFORE UPDATE ON core.bases_caja
    FOR EACH ROW EXECUTE FUNCTION core.tg_bases_caja_antes_actualizar();

/* Un gasto anulado ya no cambia. */
CREATE OR REPLACE FUNCTION core.tg_gastos_antes_actualizar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT codigo FROM core.estados_gasto WHERE id = OLD.estado_gasto_id) = 'anulado' THEN
        RAISE EXCEPTION 'El gasto % está anulado y no se puede modificar.', OLD.id;
    END IF;
    IF (SELECT codigo FROM core.estados_gasto WHERE id = NEW.estado_gasto_id) = 'anulado'
       AND (NEW.motivo_anulacion IS NULL OR length(trim(NEW.motivo_anulacion)) < 3) THEN
        RAISE EXCEPTION 'Para anular un gasto hay que escribir el motivo.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_gastos_antes_actualizar
    BEFORE UPDATE ON core.gastos
    FOR EACH ROW EXECUTE FUNCTION core.tg_gastos_antes_actualizar();


/* ============================================================================
   7. CIERRES DE INVENTARIO
   ============================================================================ */

/* Un cierre revisado ya no lo toca nadie (salvo marcarlo como aplicado al
   stock). */
CREATE OR REPLACE FUNCTION core.tg_cierres_antes_actualizar()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF (SELECT codigo FROM core.estados_cierre WHERE id = OLD.estado_cierre_id) = 'revisado' THEN
            RAISE EXCEPTION 'El cierre % está revisado: no se puede borrar.', OLD.id;
        END IF;
        RETURN OLD;
    END IF;

    IF (SELECT codigo FROM core.estados_cierre WHERE id = OLD.estado_cierre_id) = 'revisado'
       AND (NEW.estado_cierre_id <> OLD.estado_cierre_id
            OR NEW.observacion IS DISTINCT FROM OLD.observacion
            OR NEW.fecha_operativa <> OLD.fecha_operativa
            OR NEW.aplicado_a_stock = OLD.aplicado_a_stock) THEN
        RAISE EXCEPTION 'El cierre % está revisado y ya no se puede modificar.', OLD.id;
    END IF;
    IF NEW.unidad_id <> OLD.unidad_id OR NEW.area_id <> OLD.area_id THEN
        RAISE EXCEPTION 'Un cierre no cambia de unidad ni de área.';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cierres_antes_actualizar
    BEFORE UPDATE OR DELETE ON core.cierres_inventario
    FOR EACH ROW EXECUTE FUNCTION core.tg_cierres_antes_actualizar();

/* Detalle: el insumo es de la unidad y del área del cierre, y el cierre no
   está revisado. */
CREATE OR REPLACE FUNCTION core.tg_cierre_detalles_antes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cierre  core.cierres_inventario;
    v_estado  VARCHAR;
BEGIN
    SELECT * INTO v_cierre FROM core.cierres_inventario WHERE id = COALESCE(NEW.cierre_id, OLD.cierre_id);
    SELECT codigo INTO v_estado FROM core.estados_cierre WHERE id = v_cierre.estado_cierre_id;

    IF v_estado = 'revisado' THEN
        RAISE EXCEPTION 'El cierre % está revisado: su conteo no se puede cambiar.', v_cierre.id;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM core.insumo_unidades iu
          JOIN core.insumos i ON i.id = iu.insumo_id
         WHERE iu.id = NEW.insumo_unidad_id
           AND iu.unidad_id = v_cierre.unidad_id
           AND i.area_id = v_cierre.area_id
    ) THEN
        RAISE EXCEPTION 'El insumo % no es de la unidad ni del área de este cierre.', NEW.insumo_unidad_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cierre_detalles_antes
    BEFORE INSERT OR UPDATE OR DELETE ON core.cierre_detalles
    FOR EACH ROW EXECUTE FUNCTION core.tg_cierre_detalles_antes();
