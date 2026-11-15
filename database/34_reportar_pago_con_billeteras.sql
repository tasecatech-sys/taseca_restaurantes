/* ============================================================================
   TASECA · 34 · REPORTAR EL PAGO TAMBIÉN DESDE NEQUI, DAVIPLATA Y BRE-B
   ----------------------------------------------------------------------------
   EL SÍNTOMA

     El cliente paga por Nequi, escribe la referencia, le da a confirmar y le
     sale:

       «No se encontró un pedido por transferencia reciente con ese número.»

     Con cualquier referencia. No era la referencia: era el método.

   LA CAUSA

     rest.reportar_pago busca el pedido así:

       AND m.codigo = 'transferencia'

     La migración 29 partió «transferencia» en Nequi, Daviplata y Bre-B, y
     dejó la genérica desactivada y renombrada «Otra transferencia». Desde
     entonces ningún pedido real tiene el código `transferencia`: tienen
     `nequi`, `daviplata` o `breb`. La 29 actualizó los datos, las vistas y
     la aplicación, pero se le pasó esta función.

     Resultado: desde la 29, NADIE puede reportar un pago.

   EL ARREGLO

     Buscar por GRUPO y no por código. `grupo_caja = 'transferencia'` es
     justo lo que agrupa a las cuatro, y es el mismo criterio que usan la
     caja y js/store.js (grupoDeMetodo). Si mañana se añade otra billetera,
     con ponerla en ese grupo ya entra: no hay que volver aquí.

   Se puede ejecutar más de una vez.
   Requiere: 00 … 33 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. LA FUNCIÓN

   Se reescribe entera porque es corta. Lo único que cambia es la línea del
   método, pero se deja el resto a la vista para que se lea de un golpe qué
   condiciones tiene que cumplir un pedido para poder reportar su pago.
   ============================================================================ */
CREATE OR REPLACE FUNCTION rest.reportar_pago(
    p_codigo     TEXT,
    p_referencia TEXT DEFAULT NULL,
    p_imagen     TEXT DEFAULT NULL,
    p_empresa    TEXT DEFAULT 'empresa_nascar'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'core', 'public'
AS $fn$
DECLARE
    v_id   BIGINT;
    v_comp BIGINT;
BEGIN
    SELECT p.id INTO v_id
      FROM core.pedidos p
      JOIN core.empresas e     ON e.id = p.empresa_id
      JOIN core.metodos_pago m ON m.id = p.metodo_pago_id
     WHERE e.codigo = p_empresa
       AND p.codigo = core.fn_normalizar_codigo_pedido(e.id, p_codigo)
       /* Por GRUPO, no por código: desde la migración 29 los pagos por
          transferencia llegan como nequi, daviplata o breb. */
       AND m.grupo_caja = 'transferencia'
       AND p.creado_en > now() - INTERVAL '24 hours';

    IF v_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró un pedido por transferencia reciente con ese número.';
    END IF;

    CALL api.sp_registrar_comprobante(p_pedido_id     => v_id,
                                      p_archivo_url   => p_imagen,
                                      p_referencia    => p_referencia,
                                      p_comprobante_id => v_comp);
    RETURN rest.seguimiento(p_codigo, p_empresa);
END;
$fn$;

COMMENT ON FUNCTION rest.reportar_pago(TEXT, TEXT, TEXT, TEXT) IS
    'El cliente reporta que ya transfirió. Vale para cualquier método del grupo transferencia: Nequi, Daviplata, Bre-B y la genérica.';


/* ============================================================================
   2. REVISIÓN

   No basta con que la función exista. Se comprueba que el criterio alcanza a
   las cuatro billeteras, que es lo que se rompió.
   ============================================================================ */
DO $blk$
DECLARE
    v_grupo   INTEGER;
    v_codigo  INTEGER;
    v_def     TEXT;
BEGIN
    SELECT count(*) INTO v_grupo  FROM core.metodos_pago WHERE grupo_caja = 'transferencia';
    SELECT count(*) INTO v_codigo FROM core.metodos_pago WHERE codigo     = 'transferencia';

    IF v_grupo < 4 THEN
        RAISE EXCEPTION 'Sólo % métodos en el grupo transferencia: falta la migración 29.', v_grupo;
    END IF;

    IF v_grupo = v_codigo THEN
        RAISE EXCEPTION 'El grupo y el código coinciden: este arreglo no serviría de nada.';
    END IF;

    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'rest' AND p.proname = 'reportar_pago';

    IF position('m.grupo_caja = ''transferencia''' IN v_def) = 0 THEN
        RAISE EXCEPTION 'rest.reportar_pago no quedó buscando por grupo.';
    END IF;
    IF position('m.codigo = ''transferencia''' IN v_def) > 0 THEN
        RAISE EXCEPTION 'rest.reportar_pago sigue buscando por código.';
    END IF;

    RAISE NOTICE 'OK · reportar_pago alcanza a los % métodos del grupo transferencia.', v_grupo;
END;
$blk$;
