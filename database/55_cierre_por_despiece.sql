/* ============================================================================
   55 · CIERRE CONTANDO POR DESPIECE (pollos enteros + presas sueltas)

   Lo que pidió el cliente: al hacer el inventario, contar los pollos ENTEROS
   (sin despresar) y aparte las presas SUELTAS, y que el sistema arme el
   saldo de cada presa sin duplicar nada.

   EL SALDO SIGUE SIENDO POR PRESA
     cierre_detalles.saldo_fisico de «Pechuga» = sueltas + enteros × 2. El
     panel hace esa suma; el «Pollo entero» no es un insumo con stock, así
     que el cruce (lo vendido contra lo contado) no cambia en nada.

   EL DESGLOSE QUEDA GUARDADO (core.cierres_inventario.conteo_despieces)
     Una foto de lo que se contó entero:
       [{ despiece_id, nombre, cantidad, componentes: [{codigo, cantidad}] }]
     Es una foto y no un enlace: si mañana cambia la receta del despiece, el
     cierre de hoy sigue diciendo lo que se contó hoy. Sirve para mostrar
     «10 pollos enteros + 3 pechugas sueltas» y para corregir el cierre sin
     sumar dos veces.

   La base comprueba que cuadre: cada presa del desglose tiene que tener
   un saldo de al menos (enteros × cantidad), si no, el desglose no cabe.

   Idempotente. Requiere: 13 (cierres) y 50 (despieces).
   ============================================================================ */

SET search_path = core, public;

ALTER TABLE core.cierres_inventario ADD COLUMN IF NOT EXISTS conteo_despieces JSONB NOT NULL DEFAULT '[]'::JSONB;
COMMENT ON COLUMN core.cierres_inventario.conteo_despieces IS
    'Lo que se contó entero (pollos sin despresar), como foto. Ya está sumado en el saldo de cada presa.';

/* rest.despieces: también la ve quien sólo REGISTRA el cierre (la mesera con
   «cierres_registrar»), que es quien cuenta los pollos enteros. Es la de la
   50 con ese permiso más. */
CREATE OR REPLACE VIEW rest.despieces AS
WITH sesion AS MATERIALIZED (
    SELECT core.fn_jwt_usuario() AS usuario_id, core.fn_jwt_empresa() AS empresa_id
)
SELECT d.id AS despiece_id, d.empresa_id, d.nombre, d.activo, d.actualizado_en,
       COALESCE((SELECT jsonb_agg(jsonb_build_object('insumo_id', i.id, 'codigo', i.codigo, 'nombre', i.nombre,
                                                     'area', a.codigo, 'cantidad', dc.cantidad)
                                  ORDER BY i.nombre)
                   FROM core.despiece_componentes dc
                   JOIN core.insumos i ON i.id = dc.insumo_id
                   JOIN core.areas_inventario a ON a.id = i.area_id
                  WHERE dc.despiece_id = d.id), '[]'::JSONB) AS componentes
  FROM core.despieces d
  JOIN sesion s ON s.empresa_id = d.empresa_id
 WHERE EXISTS (SELECT 1 FROM unnest(ARRAY['stock', 'entradas', 'cierres', 'cierres_registrar']) p(p)
                WHERE api.fn_tiene_permiso(s.usuario_id, p.p::VARCHAR));

/* rest.cierres: + el desglose (al final). */
CREATE OR REPLACE VIEW rest.cierres AS
 WITH sesion AS MATERIALIZED (
         SELECT core.fn_jwt_usuario() AS usuario_id,
            core.fn_jwt_empresa() AS empresa_id
        )
 SELECT c.id AS cierre_id,
    u.empresa_id,
    c.unidad_id,
    a.codigo AS area,
    c.fecha_operativa,
    ec.codigo AS estado,
    c.observacion,
    c.aplicado_a_stock,
    c.registrado_por_id,
    ur.nombre AS registrado_por,
    uv.nombre AS revisado_por,
    c.revisado_en,
    c.creado_en,
    c.actualizado_en,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('codigo', i.codigo, 'nombre', i.nombre, 'saldo', d.saldo_fisico) ORDER BY i.codigo) AS jsonb_agg
           FROM core.cierre_detalles d
             JOIN core.insumo_unidades iu ON iu.id = d.insumo_unidad_id
             JOIN core.insumos i ON i.id = iu.insumo_id
          WHERE d.cierre_id = c.id), '[]'::jsonb) AS productos,
    c.conteo_despieces
   FROM core.cierres_inventario c
     JOIN core.unidades u ON u.id = c.unidad_id
     JOIN sesion s ON s.empresa_id = u.empresa_id
     JOIN core.areas_inventario a ON a.id = c.area_id
     JOIN core.estados_cierre ec ON ec.id = c.estado_cierre_id
     LEFT JOIN core.usuarios ur ON ur.id = c.registrado_por_id
     LEFT JOIN core.usuarios uv ON uv.id = c.revisado_por_id
  WHERE c.fecha_operativa >= (core.fn_fecha_operativa(u.empresa_id, now()) - 62) AND core.fn_usuario_en_unidad(s.usuario_id, c.unidad_id) AND (EXISTS ( SELECT 1
           FROM unnest(ARRAY['stock'::text, 'cierres'::text, 'cierres_registrar'::text]) p(p)
          WHERE api.fn_tiene_permiso(s.usuario_id, p.p::character varying)));

/* rest.registrar_cierre: la misma de producción, y si llega `despieces`
   (el panel nuevo siempre lo manda, aunque sea vacío) se guarda la foto.
   Un panel viejo no lo manda y el desglose anterior se queda como estaba. */
CREATE OR REPLACE FUNCTION rest.registrar_cierre(p_cierre jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'core', 'public'
AS $function$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_unidad  INTEGER := NULLIF(p_cierre ->> 'unidad_id', '')::INTEGER;
    v_id      BIGINT;
    v_foto    JSONB;
    d         JSONB;
    c         JSONB;
    v_n       NUMERIC;
    v_saldo   NUMERIC;
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

    /* (55) El desglose por despiece: sólo los que tienen cantidad > 0, y
       cada presa tiene que caber en su saldo. */
    IF p_cierre ? 'despieces' THEN
        v_foto := '[]'::JSONB;
        FOR d IN SELECT * FROM jsonb_array_elements(COALESCE(p_cierre -> 'despieces', '[]'::JSONB)) LOOP
            v_n := NULLIF(d ->> 'cantidad', '')::NUMERIC;
            CONTINUE WHEN v_n IS NULL OR v_n <= 0;
            PERFORM core.fn_cantidad_entera(v_n, 'La cantidad de enteros', FALSE);
            FOR c IN SELECT * FROM jsonb_array_elements(COALESCE(d -> 'componentes', '[]'::JSONB)) LOOP
                SELECT de.saldo_fisico INTO v_saldo
                  FROM core.cierre_detalles de
                  JOIN core.insumo_unidades iu ON iu.id = de.insumo_unidad_id
                  JOIN core.insumos i ON i.id = iu.insumo_id
                 WHERE de.cierre_id = v_id AND i.codigo = upper(trim(c ->> 'codigo'));
                IF COALESCE(v_saldo, 0) < v_n * COALESCE(NULLIF(c ->> 'cantidad', '')::NUMERIC, 0) THEN
                    RAISE EXCEPTION 'El conteo de «%» no cuadra: % enteros necesitan al menos % de %, y el saldo es %.',
                        d ->> 'nombre', v_n, v_n * (c ->> 'cantidad')::NUMERIC, c ->> 'codigo', COALESCE(v_saldo, 0);
                END IF;
            END LOOP;
            v_foto := v_foto || jsonb_build_array(jsonb_build_object(
                'despiece_id', d -> 'despiece_id', 'nombre', d ->> 'nombre', 'cantidad', v_n,
                'componentes', COALESCE(d -> 'componentes', '[]'::JSONB)));
        END LOOP;
        UPDATE core.cierres_inventario SET conteo_despieces = v_foto WHERE id = v_id;
    END IF;

    RETURN core.fn_cierre_json(v_id);
END;
$function$;
