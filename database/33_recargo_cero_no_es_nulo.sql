/* ============================================================================
   TASECA · 33 · UN RECARGO DE CERO NO ES UN RECARGO NULO
   ----------------------------------------------------------------------------
   URGENTE. Arregla que NO SE PUEDAN CREAR PEDIDOS.

   EL SÍNTOMA

     Al confirmar un pedido:
       null value in column "recargo_pago" of relation "pedidos"
       violates not-null constraint

     Pasaba con cualquier método de pago SIN recargo configurado —o sea, con
     casi todos—. Con un método que sí tenía recargo, el pedido entraba bien.

   LA CAUSA

     core.fn_recargo_pago, de la migración 30, estaba escrita así:

       SELECT COALESCE(GREATEST(round(...), 0), 0)
         FROM core.empresa_metodos_pago emp
        WHERE emp.empresa_id = …  AND emp.metodo_pago_id = …
          AND emp.recargo > 0;          <-- aquí está el problema

     El COALESCE envuelve el VALOR, no la CONSULTA. Protege de que el valor
     calculado salga nulo, pero no de que la consulta no devuelva NINGUNA
     fila — y es justo lo que pasa, porque `emp.recargo > 0` descarta a todo
     método cuyo recargo sea 0. Una función SQL cuya consulta no devuelve
     filas devuelve NULL.

     Después, rest.crear_pedido hace:
       UPDATE core.pedidos SET recargo_pago = core.fn_recargo_pago(…)
     y `recargo_pago` es NOT NULL. De ahí el error.

   EL ARREGLO

     Mover el COALESCE afuera, envolviendo la consulta entera. Así «ningún
     método con recargo» devuelve 0, que es lo que significa.

     Se deja el filtro `emp.recargo > 0`: no sobra. Evita entrar a calcular
     un porcentaje sobre un recargo nulo cuando la empresa nunca configuró
     ese método.

   Se puede ejecutar más de una vez.
   Requiere: 00 … 32 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. LA FUNCIÓN
   ============================================================================ */
CREATE OR REPLACE FUNCTION core.fn_recargo_pago(
    p_empresa_id      INTEGER,
    p_metodo_pago_id  INTEGER,
    p_base            NUMERIC
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SET search_path TO 'core', 'public'
AS $fn$
    /* OJO con dónde va el COALESCE: envuelve la CONSULTA, no el valor.
       Puesto por dentro, un método sin recargo no devolvía 0 sino NULL,
       porque la consulta no encontraba ninguna fila. */
    SELECT COALESCE((
        SELECT GREATEST(round(
                   CASE WHEN emp.recargo_tipo = 'porcentaje'
                        THEN COALESCE(p_base, 0) * emp.recargo / 100
                        ELSE emp.recargo
                   END
               ), 0)
          FROM core.empresa_metodos_pago emp
         WHERE emp.empresa_id     = p_empresa_id
           AND emp.metodo_pago_id = p_metodo_pago_id
           AND emp.recargo > 0
    ), 0);
$fn$;

COMMENT ON FUNCTION core.fn_recargo_pago(INTEGER, INTEGER, NUMERIC) IS
    'Cuánto se le recarga al cliente por pagar con este método. Sin recargo configurado devuelve 0, nunca NULL.';


/* ============================================================================
   2. REVISIÓN

   No basta con que la función exista: hay que comprobar que para un método
   SIN recargo devuelve 0 y no NULL, que es exactamente lo que se rompió.
   ============================================================================ */
DO $blk$
DECLARE
    v_empresa  INTEGER;
    v_metodo   INTEGER;
    v_cero     NUMERIC;
    v_inexist  NUMERIC;
    v_malos    INTEGER;
BEGIN
    /* Un método real, de una empresa real, con recargo 0. */
    SELECT emp.empresa_id, emp.metodo_pago_id
      INTO v_empresa, v_metodo
      FROM core.empresa_metodos_pago emp
     WHERE COALESCE(emp.recargo, 0) = 0
     LIMIT 1;

    IF v_empresa IS NOT NULL THEN
        v_cero := core.fn_recargo_pago(v_empresa, v_metodo, 52000);
        IF v_cero IS NULL THEN
            RAISE EXCEPTION 'Un método sin recargo sigue devolviendo NULL: los pedidos seguirían fallando.';
        END IF;
        IF v_cero <> 0 THEN
            RAISE EXCEPTION 'Un método sin recargo devolvió %, y debería ser 0.', v_cero;
        END IF;
    END IF;

    /* Y una combinación que no existe en absoluto. */
    v_inexist := core.fn_recargo_pago(-1, -1, 52000);
    IF v_inexist IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'Una empresa/método inexistente devolvió % en vez de 0.', v_inexist;
    END IF;

    /* Ningún par empresa-método puede devolver NULL. */
    SELECT count(*) INTO v_malos
      FROM core.empresa_metodos_pago emp
     WHERE core.fn_recargo_pago(emp.empresa_id, emp.metodo_pago_id, 52000) IS NULL;

    IF v_malos > 0 THEN
        RAISE EXCEPTION '% combinaciones empresa-método siguen devolviendo NULL.', v_malos;
    END IF;

    RAISE NOTICE 'OK · ningún método devuelve NULL. Los pedidos vuelven a entrar.';
END;
$blk$;
