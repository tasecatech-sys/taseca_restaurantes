/* ============================================================================
   GUSTI BROASTER · Coca-Cola 1.5 L · PASO 2: CORRECCIÓN
   ----------------------------------------------------------------------------
   Un cierre REVISADO está protegido por la base (triggers
   trg_cierre_detalles_antes y trg_cierres_antes_actualizar): ni la app ni un
   UPDATE normal lo pueden tocar. Esta corrección los apaga SOLO dentro de
   esta ejecución y los vuelve a encender al final.

   Qué hace, todo o nada (si algo falla, no queda ningún cambio):
     1. Cambia lo CONTADO en ese cierre por el número correcto (56).
     2. Deja constancia en la observación del cierre: qué había y qué quedó.
     3. Anula (no borra) la(s) entrada(s) que se hicieron para "corregir".
        Al anularla, la base le resta su cantidad al stock del editor.
     4. Deja el stock del editor = lo contado + las entradas posteriores al
        cierre, igual que si se hubiera pulsado «Llevar saldos al stock».
        Si ya hay un conteo MÁS RECIENTE de ese producto, este paso no se
        hace: manda el conteo más reciente.

   El cierre sigue revisado. Ventas, pedidos y demás productos no se tocan.

   ANTES: ejecuta el PASO 1 y llena los cuatro datos marcados con  ◀◀◀
   DESPUÉS: ejecuta la verificación del final.
   ============================================================================ */

DO $$
DECLARE
    -- ◀◀◀ DATOS A LLENAR (del PASO 1) ----------------------------------------
    v_cierre_id         BIGINT   := 10;                -- cierre del 21/11/2026 · Sede principal (contado 13)
    v_insumo_unidad_id  INTEGER  := 91;                -- COCACOLA15 · GUSTI BROASTER · Sede principal
    v_saldo_correcto    NUMERIC  := 56;                -- lo que realmente había
    v_entradas          BIGINT[] := ARRAY[56]::BIGINT[]; -- ajuste de 43 hecho para "cuadrar" (23:25 del 21/11)
    v_motivo            TEXT     := 'Corrección de soporte: se intentó compensar con entrada un conteo mal digitado';
    -- ------------------------------------------------------------------------

    v_fecha       DATE;
    v_unidad      INTEGER;
    v_estado      TEXT;
    v_producto    TEXT;
    v_antes       NUMERIC;
    v_n           INTEGER;
    v_posteriores NUMERIC;
    v_stock_antes NUMERIC;
BEGIN
    -- ---- Validaciones: si algo no cuadra, no se toca nada -------------------
    SELECT c.fecha_operativa, c.unidad_id, ec.codigo
      INTO v_fecha, v_unidad, v_estado
      FROM core.cierres_inventario c
      JOIN core.estados_cierre ec ON ec.id = c.estado_cierre_id
     WHERE c.id = v_cierre_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el cierre %. Revisa v_cierre_id.', v_cierre_id;
    END IF;

    SELECT i.nombre, iu.stock_actual INTO v_producto, v_stock_antes
      FROM core.insumo_unidades iu JOIN core.insumos i ON i.id = iu.insumo_id
     WHERE iu.id = v_insumo_unidad_id AND iu.unidad_id = v_unidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El insumo_unidad % no es de la sede del cierre %.', v_insumo_unidad_id, v_cierre_id;
    END IF;

    SELECT saldo_fisico INTO v_antes
      FROM core.cierre_detalles
     WHERE cierre_id = v_cierre_id AND insumo_unidad_id = v_insumo_unidad_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION '% no aparece contado en el cierre %.', v_producto, v_cierre_id;
    END IF;

    IF v_saldo_correcto IS NULL OR v_saldo_correcto < 0 THEN
        RAISE EXCEPTION 'El saldo correcto no puede ser negativo.';
    END IF;

    IF cardinality(v_entradas) > 0 THEN
        SELECT count(*) INTO v_n
          FROM core.entradas_inventario
         WHERE id = ANY (v_entradas)
           AND insumo_unidad_id = v_insumo_unidad_id
           AND anulada_en IS NULL;
        IF v_n <> cardinality(v_entradas) THEN
            RAISE EXCEPTION 'Alguna entrada de % no es de este producto o ya estaba anulada.', v_entradas;
        END IF;
    END IF;

    -- ---- 1. Lo contado ------------------------------------------------------
    ALTER TABLE core.cierre_detalles DISABLE TRIGGER trg_cierre_detalles_antes;
    UPDATE core.cierre_detalles
       SET saldo_fisico = v_saldo_correcto
     WHERE cierre_id = v_cierre_id AND insumo_unidad_id = v_insumo_unidad_id;
    ALTER TABLE core.cierre_detalles ENABLE TRIGGER trg_cierre_detalles_antes;

    -- ---- 2. Constancia en el cierre -----------------------------------------
    ALTER TABLE core.cierres_inventario DISABLE TRIGGER trg_cierres_antes_actualizar;
    UPDATE core.cierres_inventario
       SET observacion = left(concat_ws(' · ', NULLIF(trim(observacion), ''),
                              format('[Soporte %s] %s: contado %s → %s',
                                     to_char(now() AT TIME ZONE 'America/Bogota', 'DD/MM/YYYY'),
                                     v_producto, v_antes, v_saldo_correcto)), 400),
           actualizado_en = now()
     WHERE id = v_cierre_id;
    ALTER TABLE core.cierres_inventario ENABLE TRIGGER trg_cierres_antes_actualizar;

    -- ---- 3. Anular la(s) entrada(s) de "corrección" -------------------------
    --      La base permite anular (nunca borrar); su trigger resta del stock.
    IF cardinality(v_entradas) > 0 THEN
        UPDATE core.entradas_inventario
           SET anulada_en = now(), motivo_anulacion = left(v_motivo, 300)
         WHERE id = ANY (v_entradas);
    END IF;

    -- ---- 4. Stock del editor ------------------------------------------------
    IF EXISTS (SELECT 1 FROM core.cierre_detalles d
                 JOIN core.cierres_inventario c ON c.id = d.cierre_id
                WHERE d.insumo_unidad_id = v_insumo_unidad_id AND c.fecha_operativa > v_fecha) THEN
        RAISE NOTICE 'Hay un conteo más reciente de %: el stock del editor no se toca.', v_producto;
    ELSE
        SELECT COALESCE(sum(cantidad), 0) INTO v_posteriores
          FROM core.entradas_inventario
         WHERE insumo_unidad_id = v_insumo_unidad_id
           AND anulada_en IS NULL
           AND fecha_operativa > v_fecha;

        UPDATE core.insumo_unidades
           SET stock_actual = v_saldo_correcto + v_posteriores, actualizado_en = now()
         WHERE id = v_insumo_unidad_id;
    END IF;

    RAISE NOTICE 'Listo · % · cierre % del %: contado % → % · entradas anuladas: % · stock del editor antes: %',
        v_producto, v_cierre_id, v_fecha, v_antes, v_saldo_correcto, v_entradas, v_stock_antes;
END;
$$;


/* ---- Verificación (después de ejecutar lo de arriba) -----------------------
   Cambia el 0 por el mismo v_cierre_id. Debe decir saldo_contado = 56 y el
   estado seguir en «revisado». */
SELECT c.id AS cierre_id, c.fecha_operativa, ec.codigo AS estado, i.nombre AS producto,
       d.saldo_fisico AS saldo_contado, iu.stock_actual AS stock_del_editor, c.observacion
  FROM core.cierre_detalles d
  JOIN core.cierres_inventario c ON c.id = d.cierre_id
  JOIN core.estados_cierre ec    ON ec.id = c.estado_cierre_id
  JOIN core.insumo_unidades iu   ON iu.id = d.insumo_unidad_id
  JOIN core.insumos i            ON i.id = iu.insumo_id
 WHERE c.id = 10
   AND i.nombre ILIKE '%coca%';

-- Y que los dos triggers de protección quedaron encendidos (tgenabled = 'O'):
SELECT tgname, tgenabled FROM pg_trigger
 WHERE tgname IN ('trg_cierre_detalles_antes', 'trg_cierres_antes_actualizar');
