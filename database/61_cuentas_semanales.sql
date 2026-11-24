/* ============================================================================
   61 · CUENTAS SEMANALES (Nequi, Daviplata, Bre-B…)

   Lo que pidió el cliente (Gusti, 24/11): las cuentas digitales se
   desocupan un día a la semana, el que el negocio escoja. Ese día se
   anota con cuánto quedó cada cuenta (la base) y, al final de la semana,
   lo que dice la app tiene que coincidir con lo que dice el sistema.

   CÓMO FUNCIONA
     · core.empresas.dia_inicio_semana_cuentas: el día que arranca la
       semana (1 = lunes … 7 = domingo, como ISODOW). Lo escoge el negocio.
       Una semana va de ese día hasta el anterior de la semana siguiente,
       por fecha operativa (lo vendido de madrugada cuenta en el día de antes).
     · Una cuenta = un método de pago que no es efectivo (Nequi, Daviplata,
       Bre-B, datáfono…). Son de la EMPRESA: suman todas las sedes.
     · Debería haber = base + cobrado − gastos pagados desde la cuenta − retiros
         cobrado: las ventas confirmadas de la semana por ese método, con
                  sus recargos y las partes de un pago dividido (las mismas
                  que cuadran en el informe de caja).
         gastos:  los gastos no anulados pagados con ese método.
         retiros: la plata que se saca a mitad de semana (se anota aparte,
                  con motivo, y se puede anular con motivo).
     · Cerrar la semana: se escribe el saldo real de cada cuenta y queda una
       FOTO (base, cobrado, gastos, retiros, esperado, real). Una venta que
       se anule después no mueve una semana cerrada.

   Todo se lee y se escribe por funciones rest.* con permiso de informe o
   de base de caja; las tablas no tienen permisos directos.

   Idempotente.
   ============================================================================ */

SET search_path = core, public;

/* ------------------------------------------------------------- tablas */
ALTER TABLE core.empresas ADD COLUMN IF NOT EXISTS dia_inicio_semana_cuentas SMALLINT;
DO $$ BEGIN
    ALTER TABLE core.empresas ADD CONSTRAINT ck_empresas_dia_semana_cuentas
        CHECK (dia_inicio_semana_cuentas BETWEEN 1 AND 7);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON COLUMN core.empresas.dia_inicio_semana_cuentas IS
    'Día en que el negocio desocupa las cuentas digitales y arranca su semana (1 = lunes … 7 = domingo). NULL: no lo ha escogido.';

CREATE TABLE IF NOT EXISTS core.cuentas_semana (
    id              BIGSERIAL PRIMARY KEY,
    empresa_id      INTEGER NOT NULL REFERENCES core.empresas (id) ON DELETE CASCADE,
    metodo_pago_id  INTEGER NOT NULL REFERENCES core.metodos_pago (id),
    semana_inicio   DATE    NOT NULL,
    base            NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (base >= 0),
    base_por_id     INTEGER REFERENCES core.usuarios (id),
    base_en         TIMESTAMPTZ,
    base_motivo     VARCHAR(200),
    -- La foto del cierre
    cobrado         NUMERIC(12, 2),
    gastos          NUMERIC(12, 2),
    retiros         NUMERIC(12, 2),
    esperado        NUMERIC(12, 2),
    saldo_real      NUMERIC(12, 2) CHECK (saldo_real >= 0),
    cerrada_por_id  INTEGER REFERENCES core.usuarios (id),
    cerrada_en      TIMESTAMPTZ,
    observacion     VARCHAR(300),
    CONSTRAINT uq_cuentas_semana UNIQUE (empresa_id, metodo_pago_id, semana_inicio)
);
COMMENT ON TABLE core.cuentas_semana IS
    'Por cuenta digital y semana: la base con que arrancó y, al cerrar, la foto del cuadre. Ver la migración 61.';

CREATE TABLE IF NOT EXISTS core.cuentas_retiros (
    id                BIGSERIAL PRIMARY KEY,
    empresa_id        INTEGER NOT NULL REFERENCES core.empresas (id) ON DELETE CASCADE,
    metodo_pago_id    INTEGER NOT NULL REFERENCES core.metodos_pago (id),
    fecha_operativa   DATE    NOT NULL,
    monto             NUMERIC(12, 2) NOT NULL CHECK (monto > 0),
    motivo            VARCHAR(200) NOT NULL,
    usuario_id        INTEGER REFERENCES core.usuarios (id),
    creado_en         TIMESTAMPTZ NOT NULL DEFAULT now(),
    anulado_en        TIMESTAMPTZ,
    anulado_por_id    INTEGER REFERENCES core.usuarios (id),
    motivo_anulacion  VARCHAR(200)
);
COMMENT ON TABLE core.cuentas_retiros IS
    'Plata que se saca de una cuenta digital a mitad de semana. No se borra: se anula con motivo.';
CREATE INDEX IF NOT EXISTS ix_cuentas_retiros_semana ON core.cuentas_retiros (empresa_id, metodo_pago_id, fecha_operativa);

ALTER TABLE core.cuentas_semana  ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.cuentas_retiros ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON core.cuentas_semana, core.cuentas_retiros FROM PUBLIC;

/* ------------------------------------------------------- las cuentas */
/* El día en que arranca la semana que contiene p_fecha. NULL si el
   negocio no ha escogido el día. */
CREATE OR REPLACE FUNCTION core.fn_semana_cuentas(p_empresa INTEGER, p_fecha DATE)
RETURNS DATE
LANGUAGE sql
STABLE
SET search_path TO 'core', 'public'
AS $$
    SELECT p_fecha - ((EXTRACT(ISODOW FROM p_fecha)::INTEGER - e.dia_inicio_semana_cuentas + 7) % 7)
      FROM core.empresas e
     WHERE e.id = p_empresa AND e.dia_inicio_semana_cuentas IS NOT NULL;
$$;

/* Quién puede: el que ve la caja (informe) o registra su base. */
CREATE OR REPLACE FUNCTION core.fn_exigir_cuentas(p_usuario INTEGER)
RETURNS VOID
LANGUAGE plpgsql
STABLE
SET search_path TO 'core', 'public'
AS $$
BEGIN
    IF NOT (core.fn_tiene_permiso(p_usuario, 'informe') OR core.fn_tiene_permiso(p_usuario, 'base_caja')) THEN
        RAISE EXCEPTION 'Tu perfil no puede ver ni registrar las cuentas.' USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$;

/* Lo que se movió en una cuenta entre dos fechas operativas. */
CREATE OR REPLACE FUNCTION core.fn_movimiento_cuenta(p_empresa INTEGER, p_metodo INTEGER, p_desde DATE, p_hasta DATE,
                                                     OUT cobrado NUMERIC, OUT gastos NUMERIC, OUT retiros NUMERIC)
LANGUAGE sql
STABLE
SET search_path TO 'core', 'public'
AS $$
    SELECT
        COALESCE((SELECT SUM(pg.valor)
                    FROM api.v_pedidos vp
                    CROSS JOIN LATERAL core.fn_partes_pago(vp.pedido_id, vp.metodo_pago, vp.grupo_caja, vp.total) pg
                   WHERE vp.empresa_id = p_empresa
                     AND vp.fecha_operativa BETWEEN p_desde AND p_hasta
                     AND vp.cuenta_como_venta AND vp.estado_pago = 'confirmado'
                     AND pg.metodo_pago = (SELECT codigo FROM core.metodos_pago WHERE id = p_metodo)), 0),
        COALESCE((SELECT SUM(g.monto)
                    FROM core.gastos g
                    JOIN core.unidades u       ON u.id = g.unidad_id
                    JOIN core.estados_gasto eg ON eg.id = g.estado_gasto_id
                   WHERE u.empresa_id = p_empresa AND g.metodo_pago_id = p_metodo
                     AND g.fecha_operativa BETWEEN p_desde AND p_hasta
                     AND eg.codigo <> 'anulado'), 0),
        COALESCE((SELECT SUM(r.monto)
                    FROM core.cuentas_retiros r
                   WHERE r.empresa_id = p_empresa AND r.metodo_pago_id = p_metodo
                     AND r.fecha_operativa BETWEEN p_desde AND p_hasta
                     AND r.anulado_en IS NULL), 0);
$$;

/* Las cuentas de la empresa: los métodos activos que no son efectivo
   (ni «mixto», que no es una cuenta), y los que ya tienen algo esa semana. */
CREATE OR REPLACE FUNCTION core.fn_cuentas_de(p_empresa INTEGER, p_semana DATE)
RETURNS TABLE (metodo_pago_id INTEGER, codigo TEXT, nombre TEXT)
LANGUAGE sql
STABLE
SET search_path TO 'core', 'public'
AS $$
    SELECT mp.id, mp.codigo::TEXT, mp.nombre::TEXT
      FROM core.metodos_pago mp
     WHERE mp.grupo_caja <> 'efectivo' AND mp.codigo <> 'mixto'
       AND (EXISTS (SELECT 1 FROM core.empresa_metodos_pago emp
                     WHERE emp.empresa_id = p_empresa AND emp.metodo_pago_id = mp.id AND emp.activo)
            OR EXISTS (SELECT 1 FROM core.cuentas_semana cs
                        WHERE cs.empresa_id = p_empresa AND cs.metodo_pago_id = mp.id AND cs.semana_inicio = p_semana))
     ORDER BY mp.id;
$$;

/* ------------------------------------------------------------ leer */
CREATE OR REPLACE FUNCTION rest.cuentas_semana(p_semana DATE DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'core', 'public'
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
    v_dia     SMALLINT;
    v_hoy     DATE;
    v_ini     DATE;
    v_fin     DATE;
    v_cuentas JSONB;
    v_semanas JSONB;
BEGIN
    PERFORM core.fn_exigir_cuentas(v_usuario);
    SELECT dia_inicio_semana_cuentas INTO v_dia FROM core.empresas WHERE id = v_empresa;
    v_hoy := core.fn_fecha_operativa(v_empresa, now());
    IF v_dia IS NULL THEN
        RETURN jsonb_build_object('configurado', FALSE, 'hoy', v_hoy);
    END IF;

    v_ini := core.fn_semana_cuentas(v_empresa, COALESCE(p_semana, v_hoy));
    v_fin := v_ini + 6;

    SELECT COALESCE(jsonb_agg(x ORDER BY (x ->> 'metodo_pago_id')::INTEGER), '[]') INTO v_cuentas
      FROM (
        SELECT jsonb_build_object(
                   'metodo_pago_id', c.metodo_pago_id, 'metodo', c.codigo, 'nombre', c.nombre,
                   'base', COALESCE(cs.base, 0),
                   'base_registrada', cs.base_por_id IS NOT NULL,
                   'base_por', (SELECT nombre FROM core.usuarios WHERE id = cs.base_por_id),
                   'base_en', cs.base_en, 'base_motivo', cs.base_motivo,
                   'cobrado',  CASE WHEN cs.cerrada_en IS NOT NULL THEN cs.cobrado ELSE m.cobrado END,
                   'gastos',   CASE WHEN cs.cerrada_en IS NOT NULL THEN cs.gastos  ELSE m.gastos  END,
                   'retiros',  CASE WHEN cs.cerrada_en IS NOT NULL THEN cs.retiros ELSE m.retiros END,
                   'esperado', CASE WHEN cs.cerrada_en IS NOT NULL THEN cs.esperado
                                    ELSE COALESCE(cs.base, 0) + m.cobrado - m.gastos - m.retiros END,
                   'saldo_real', cs.saldo_real,
                   'diferencia', CASE WHEN cs.cerrada_en IS NOT NULL THEN cs.saldo_real - cs.esperado END,
                   'cerrada', cs.cerrada_en IS NOT NULL,
                   'retiros_lista', COALESCE((
                        SELECT jsonb_agg(jsonb_build_object(
                                   'id', r.id, 'fecha', r.fecha_operativa, 'monto', r.monto, 'motivo', r.motivo,
                                   'por', (SELECT nombre FROM core.usuarios WHERE id = r.usuario_id),
                                   'anulado', r.anulado_en IS NOT NULL, 'motivo_anulacion', r.motivo_anulacion)
                                ORDER BY r.fecha_operativa, r.id)
                          FROM core.cuentas_retiros r
                         WHERE r.empresa_id = v_empresa AND r.metodo_pago_id = c.metodo_pago_id
                           AND r.fecha_operativa BETWEEN v_ini AND v_fin), '[]')) AS x
          FROM core.fn_cuentas_de(v_empresa, v_ini) c
          LEFT JOIN core.cuentas_semana cs
                 ON cs.empresa_id = v_empresa AND cs.metodo_pago_id = c.metodo_pago_id AND cs.semana_inicio = v_ini
          CROSS JOIN LATERAL core.fn_movimiento_cuenta(v_empresa, c.metodo_pago_id, v_ini, v_fin) m
      ) t;

    -- Las semanas anteriores con algo registrado (para el historial)
    SELECT COALESCE(jsonb_agg(s ORDER BY s ->> 'semana_inicio' DESC), '[]') INTO v_semanas
      FROM (
        SELECT jsonb_build_object(
                   'semana_inicio', cs.semana_inicio, 'semana_fin', cs.semana_inicio + 6,
                   'cerrada', bool_and(cs.cerrada_en IS NOT NULL),
                   'diferencia', SUM(cs.saldo_real - cs.esperado) FILTER (WHERE cs.cerrada_en IS NOT NULL)) AS s
          FROM core.cuentas_semana cs
         WHERE cs.empresa_id = v_empresa AND cs.semana_inicio <> v_ini
         GROUP BY cs.semana_inicio
         ORDER BY cs.semana_inicio DESC
         LIMIT 12
      ) h;

    RETURN jsonb_build_object(
        'configurado', TRUE, 'dia', v_dia, 'hoy', v_hoy,
        'semana_inicio', v_ini, 'semana_fin', v_fin,
        'es_actual', v_ini = core.fn_semana_cuentas(v_empresa, v_hoy),
        'cerrada', EXISTS (SELECT 1 FROM core.cuentas_semana WHERE empresa_id = v_empresa AND semana_inicio = v_ini AND cerrada_en IS NOT NULL),
        'cuentas', v_cuentas, 'semanas', v_semanas);
END;
$$;

/* ------------------------------------------------------- escribir */
/* Escoger (o cambiar) el día en que arranca la semana. */
CREATE OR REPLACE FUNCTION rest.configurar_semana_cuentas(p_dia INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'core', 'public'
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
BEGIN
    PERFORM core.fn_preparar_operacion(v_usuario, 'informe');
    IF p_dia IS NULL OR p_dia NOT BETWEEN 1 AND 7 THEN
        RAISE EXCEPTION 'Escoge el día de la semana (de lunes a domingo).';
    END IF;
    UPDATE core.empresas SET dia_inicio_semana_cuentas = p_dia WHERE id = v_empresa;
    RETURN jsonb_build_object('dia', p_dia);
END;
$$;

/* La base de la semana de una cuenta. Corregirla pide el motivo. */
CREATE OR REPLACE FUNCTION rest.registrar_base_cuenta(p_base JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'core', 'public'
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
    v_metodo  INTEGER := (SELECT id FROM core.metodos_pago WHERE codigo = p_base ->> 'metodo');
    v_monto   NUMERIC := NULLIF(p_base ->> 'monto', '')::NUMERIC;
    v_motivo  TEXT    := NULLIF(trim(COALESCE(p_base ->> 'motivo', '')), '');
    v_ini     DATE;
    v_fila    core.cuentas_semana;
BEGIN
    PERFORM core.fn_exigir_cuentas(v_usuario);
    PERFORM core.fn_fijar_usuario(v_usuario);
    v_ini := core.fn_semana_cuentas(v_empresa, COALESCE(NULLIF(p_base ->> 'semana', '')::DATE,
                                                         core.fn_fecha_operativa(v_empresa, now())));
    IF v_ini IS NULL THEN
        RAISE EXCEPTION 'Primero escoge el día en que empieza la semana de las cuentas.';
    END IF;
    IF v_metodo IS NULL OR NOT EXISTS (SELECT 1 FROM core.fn_cuentas_de(v_empresa, v_ini) c WHERE c.metodo_pago_id = v_metodo) THEN
        RAISE EXCEPTION 'Esa cuenta no está activa en este negocio.';
    END IF;
    IF v_monto IS NULL OR v_monto < 0 THEN
        RAISE EXCEPTION 'La base es un valor de 0 en adelante.';
    END IF;

    SELECT * INTO v_fila FROM core.cuentas_semana
     WHERE empresa_id = v_empresa AND metodo_pago_id = v_metodo AND semana_inicio = v_ini FOR UPDATE;
    IF v_fila.cerrada_en IS NOT NULL THEN
        RAISE EXCEPTION 'Esa semana ya está cerrada: su base no se cambia.';
    END IF;
    IF v_fila.base_por_id IS NOT NULL AND v_fila.base IS DISTINCT FROM v_monto
       AND length(COALESCE(v_motivo, '')) < 3 THEN
        RAISE EXCEPTION 'La base ya estaba registrada: escribe el motivo de la corrección.';
    END IF;

    INSERT INTO core.cuentas_semana (empresa_id, metodo_pago_id, semana_inicio, base, base_por_id, base_en, base_motivo)
    VALUES (v_empresa, v_metodo, v_ini, v_monto, v_usuario, now(), v_motivo)
    ON CONFLICT (empresa_id, metodo_pago_id, semana_inicio) DO UPDATE
       SET base = EXCLUDED.base, base_por_id = EXCLUDED.base_por_id, base_en = EXCLUDED.base_en,
           base_motivo = CASE WHEN core.cuentas_semana.base_por_id IS NULL THEN EXCLUDED.base_motivo
                              ELSE COALESCE(EXCLUDED.base_motivo, core.cuentas_semana.base_motivo) END;

    RETURN jsonb_build_object('semana_inicio', v_ini, 'metodo', p_base ->> 'metodo', 'base', v_monto);
END;
$$;

/* Un retiro a mitad de semana. */
CREATE OR REPLACE FUNCTION rest.registrar_retiro_cuenta(p_retiro JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'core', 'public'
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
    v_metodo  INTEGER := (SELECT id FROM core.metodos_pago WHERE codigo = p_retiro ->> 'metodo');
    v_monto   NUMERIC := NULLIF(p_retiro ->> 'monto', '')::NUMERIC;
    v_motivo  TEXT    := trim(COALESCE(p_retiro ->> 'motivo', ''));
    v_hoy     DATE    := core.fn_fecha_operativa(v_empresa, now());
    v_fecha   DATE    := COALESCE(NULLIF(p_retiro ->> 'fecha', '')::DATE, v_hoy);
    v_ini     DATE;
    v_id      BIGINT;
BEGIN
    PERFORM core.fn_exigir_cuentas(v_usuario);
    PERFORM core.fn_fijar_usuario(v_usuario);
    v_ini := core.fn_semana_cuentas(v_empresa, v_fecha);
    IF v_ini IS NULL THEN
        RAISE EXCEPTION 'Primero escoge el día en que empieza la semana de las cuentas.';
    END IF;
    IF v_fecha > v_hoy THEN
        RAISE EXCEPTION 'Un retiro no puede tener fecha futura.';
    END IF;
    IF v_metodo IS NULL OR NOT EXISTS (SELECT 1 FROM core.fn_cuentas_de(v_empresa, v_ini) c WHERE c.metodo_pago_id = v_metodo) THEN
        RAISE EXCEPTION 'Esa cuenta no está activa en este negocio.';
    END IF;
    IF v_monto IS NULL OR v_monto <= 0 THEN
        RAISE EXCEPTION 'El retiro tiene que ser mayor que 0.';
    END IF;
    IF length(v_motivo) < 3 THEN
        RAISE EXCEPTION 'Escribe para qué fue el retiro.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.cuentas_semana WHERE empresa_id = v_empresa AND semana_inicio = v_ini AND cerrada_en IS NOT NULL) THEN
        RAISE EXCEPTION 'La semana de esa fecha ya está cerrada.';
    END IF;

    INSERT INTO core.cuentas_retiros (empresa_id, metodo_pago_id, fecha_operativa, monto, motivo, usuario_id)
    VALUES (v_empresa, v_metodo, v_fecha, v_monto, left(v_motivo, 200), v_usuario)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('id', v_id);
END;
$$;

CREATE OR REPLACE FUNCTION rest.anular_retiro_cuenta(p_id BIGINT, p_motivo TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'core', 'public'
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
    v_r       core.cuentas_retiros;
BEGIN
    PERFORM core.fn_exigir_cuentas(v_usuario);
    PERFORM core.fn_fijar_usuario(v_usuario);
    SELECT * INTO v_r FROM core.cuentas_retiros WHERE id = p_id AND empresa_id = v_empresa FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ese retiro no existe.';
    ELSIF v_r.anulado_en IS NOT NULL THEN
        RAISE EXCEPTION 'Ese retiro ya está anulado.';
    ELSIF length(trim(COALESCE(p_motivo, ''))) < 3 THEN
        RAISE EXCEPTION 'Escribe el motivo de la anulación.';
    ELSIF EXISTS (SELECT 1 FROM core.cuentas_semana
                   WHERE empresa_id = v_empresa AND cerrada_en IS NOT NULL
                     AND semana_inicio = core.fn_semana_cuentas(v_empresa, v_r.fecha_operativa)) THEN
        RAISE EXCEPTION 'La semana de ese retiro ya está cerrada.';
    END IF;
    UPDATE core.cuentas_retiros
       SET anulado_en = now(), anulado_por_id = v_usuario, motivo_anulacion = left(trim(p_motivo), 200)
     WHERE id = p_id;
    RETURN jsonb_build_object('id', p_id, 'anulado', TRUE);
END;
$$;

/* Cerrar la semana: el saldo real de cada cuenta, y la foto del cuadre. */
CREATE OR REPLACE FUNCTION rest.cerrar_semana_cuentas(p_cierre JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'core', 'public'
AS $$
DECLARE
    v_usuario INTEGER := core.fn_exigir_sesion();
    v_empresa INTEGER := core.fn_jwt_empresa();
    v_hoy     DATE    := core.fn_fecha_operativa(v_empresa, now());
    v_ini     DATE;
    v_obs     TEXT    := NULLIF(trim(COALESCE(p_cierre ->> 'observacion', '')), '');
    c         RECORD;
    v_saldo   NUMERIC;
    m         RECORD;
    v_n       INTEGER := 0;
BEGIN
    PERFORM core.fn_exigir_cuentas(v_usuario);
    PERFORM core.fn_fijar_usuario(v_usuario);
    v_ini := core.fn_semana_cuentas(v_empresa, COALESCE(NULLIF(p_cierre ->> 'semana', '')::DATE, v_hoy));
    IF v_ini IS NULL THEN
        RAISE EXCEPTION 'Primero escoge el día en que empieza la semana de las cuentas.';
    END IF;
    IF v_ini > v_hoy THEN
        RAISE EXCEPTION 'Esa semana todavía no empieza.';
    END IF;
    IF EXISTS (SELECT 1 FROM core.cuentas_semana WHERE empresa_id = v_empresa AND semana_inicio = v_ini AND cerrada_en IS NOT NULL) THEN
        RAISE EXCEPTION 'Esa semana ya está cerrada.';
    END IF;

    FOR c IN SELECT * FROM core.fn_cuentas_de(v_empresa, v_ini) LOOP
        SELECT NULLIF(x ->> 'saldo_real', '')::NUMERIC INTO v_saldo
          FROM jsonb_array_elements(COALESCE(p_cierre -> 'saldos', '[]')) x
         WHERE x ->> 'metodo' = c.codigo;
        IF v_saldo IS NULL OR v_saldo < 0 THEN
            RAISE EXCEPTION 'Falta el saldo real de %: escribe lo que dice la cuenta (0 si está vacía).', c.nombre;
        END IF;
        SELECT * INTO m FROM core.fn_movimiento_cuenta(v_empresa, c.metodo_pago_id, v_ini, v_ini + 6);

        INSERT INTO core.cuentas_semana (empresa_id, metodo_pago_id, semana_inicio)
        VALUES (v_empresa, c.metodo_pago_id, v_ini)
        ON CONFLICT (empresa_id, metodo_pago_id, semana_inicio) DO NOTHING;

        UPDATE core.cuentas_semana
           SET cobrado = m.cobrado, gastos = m.gastos, retiros = m.retiros,
               esperado = base + m.cobrado - m.gastos - m.retiros,
               saldo_real = v_saldo, cerrada_por_id = v_usuario, cerrada_en = now(), observacion = v_obs
         WHERE empresa_id = v_empresa AND metodo_pago_id = c.metodo_pago_id AND semana_inicio = v_ini;
        v_n := v_n + 1;
    END LOOP;

    RETURN jsonb_build_object('semana_inicio', v_ini, 'cuentas', v_n);
END;
$$;

REVOKE ALL ON FUNCTION rest.cuentas_semana(DATE), rest.configurar_semana_cuentas(INTEGER),
                       rest.registrar_base_cuenta(JSONB), rest.registrar_retiro_cuenta(JSONB),
                       rest.anular_retiro_cuenta(BIGINT, TEXT), rest.cerrar_semana_cuentas(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rest.cuentas_semana(DATE), rest.configurar_semana_cuentas(INTEGER),
                          rest.registrar_base_cuenta(JSONB), rest.registrar_retiro_cuenta(JSONB),
                          rest.anular_retiro_cuenta(BIGINT, TEXT), rest.cerrar_semana_cuentas(JSONB) TO taseca_app;
