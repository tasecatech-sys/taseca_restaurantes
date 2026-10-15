/* ============================================================================
   TASECA · 22 · LA RED DE SEGURIDAD, COMPLETA
   ----------------------------------------------------------------------------
   El script 17 dejó dos cosas: un CHEQUEO que encuentra relaciones cruzadas
   (api.fn_chequeo_integridad) y unos TRIGGERS que impiden que vuelvan a
   aparecer. Pero los triggers no llegaron a todas las tablas que el chequeo
   vigila. Auditando el camino completo de un pedido salieron cinco sitios
   donde una fila cruzada se DETECTABA después, pero nadie la BLOQUEABA:

     · core.cierres_inventario   firmado o revisado por alguien de otra empresa
     · core.menus_dia            creado por alguien de otra empresa
     · core.pedido_historial     movimiento escrito por alguien de otra empresa
     · core.comprobantes_pago    comprobante revisado por alguien de otra empresa
     · core.anulaciones          anulación firmada por alguien de otra empresa

   Por la aplicación no podía pasar —los procedimientos sólo pasan el usuario
   de la sesión, y ése ya pasó por fn_preparar_operacion—, pero la regla tiene
   que valer venga el dato de donde venga, igual que en pedidos, ítems,
   entradas, conteos y bases de caja. Esto lo iguala.

   Los usuarios de PLATAFORMA (empresa NULL) siguen exentos: el SuperAdmin
   opera dentro de una empresa sin pertenecer a ninguna. Es la misma excepción
   que ya hacían los demás triggers.

   No cambia datos y se puede ejecutar más de una vez.
   Requiere: 00 … 17 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. EL TRIGGER, CON LAS CINCO TABLAS QUE FALTABAN
   ============================================================================ */

CREATE OR REPLACE FUNCTION core.tg_relaciones_empresa()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
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
        SELECT i.menu_dia_id INTO v_otra FROM core.pedido_items i WHERE i.id = NEW.pedido_item_id;
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

    /* ---- Lo que añade este script 22 ---------------------------------- */

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
$$;


/* ============================================================================
   2. LOS TRIGGERS QUE FALTABAN

   `anulaciones` ya tiene trg_anulaciones_inmutable (BEFORE UPDATE OR DELETE):
   aquí sólo hace falta vigilar el INSERT. En las demás, insertar y actualizar.
   ============================================================================ */

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['cierres_inventario', 'menus_dia', 'pedido_historial', 'comprobantes_pago'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_relaciones ON core.%I', t, t);
        EXECUTE format('CREATE TRIGGER trg_%s_relaciones BEFORE INSERT OR UPDATE ON core.%I
                        FOR EACH ROW EXECUTE FUNCTION core.tg_relaciones_empresa()', t, t);
    END LOOP;

    DROP TRIGGER IF EXISTS trg_anulaciones_relaciones ON core.anulaciones;
    CREATE TRIGGER trg_anulaciones_relaciones BEFORE INSERT ON core.anulaciones
        FOR EACH ROW EXECUTE FUNCTION core.tg_relaciones_empresa();
END;
$$;


/* ============================================================================
   3. REVISIÓN

   Qué tablas del camino de un pedido tienen ya la red puesta.
   ============================================================================ */

DO $$
DECLARE
    v_faltan TEXT;
BEGIN
    SELECT string_agg(x.tabla, ', ' ORDER BY x.tabla) INTO v_faltan
      FROM unnest(ARRAY['pedidos', 'pedido_items', 'pedido_item_opciones', 'pedido_historial',
                        'comprobantes_pago', 'anulaciones', 'entradas_inventario',
                        'cierres_inventario', 'cierre_detalles', 'bases_caja', 'menus_dia']) AS x(tabla)
     WHERE NOT EXISTS (
            SELECT 1 FROM pg_trigger t
              JOIN pg_class c ON c.oid = t.tgrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
              JOIN pg_proc p ON p.oid = t.tgfoid
             WHERE n.nspname = 'core' AND c.relname = x.tabla
               AND p.proname = 'tg_relaciones_empresa' AND NOT t.tgisinternal);

    RAISE NOTICE '--------------------------------------------------';
    IF v_faltan IS NULL THEN
        RAISE NOTICE 'Las 11 tablas del camino de un pedido tienen la red puesta.';
    ELSE
        RAISE EXCEPTION 'Siguen sin red: %', v_faltan;
    END IF;
    RAISE NOTICE '--------------------------------------------------';
END;
$$;
