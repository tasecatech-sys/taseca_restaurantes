/* ============================================================================
   TASECA · 32 · RECOGER EN EL LOCAL
   ----------------------------------------------------------------------------
   Un cuarto tipo de pedido. El cliente pide desde el portal como siempre,
   pero pasa por el local a recogerlo: no hay dirección, no hay zona y no hay
   domicilio que cobrar.

   CASI TODO ESTABA YA HECHO

     El esquema no guarda el tipo como texto suelto sino como una fila de
     core.tipos_pedido, y el flujo de estados no está escrito a mano en
     ninguna parte: core.fn_siguiente_estado se salta los estados marcados
     `solo_domicilio` para cualquier tipo que no sea 'domicilio'. O sea que
     «recoger» pasa nuevo → preparación → listo → entregado SIN tocar nada.

     El costo del domicilio tampoco hay que anularlo: sale de la zona, y un
     pedido para recoger va sin zona. Y el pedido mínimo de la zona, igual.

   LO QUE SÍ HAY QUE HACER

     1. La fila del tipo.
     2. Que api.sp_crear_pedido le pida nombre y teléfono -hacen falta para
        llamar al cliente cuando esté listo- y le abra ficha de cliente, que
        hoy sólo hace con los domicilios.

   POR QUÉ EL PASO 2 VA CON replace() Y NO REESCRITO ENTERO

     api.sp_crear_pedido tiene 120 líneas y lo único que cambia es UNA
     condición. Si lo reescribiera entero desde la copia que tengo hoy,
     cualquier otro cambio que haya entrado en ese procedimiento desde
     entonces se perdería al correr esta migración. Así se toca sólo lo que
     dice que toca, y si la línea no está, avisa en vez de seguir.

   Se puede ejecutar más de una vez.
   Requiere: 00 … 31 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. EL TIPO DE PEDIDO

   Sin INSERT … ON CONFLICT: no doy por hecho que `codigo` tenga índice único.
   El WHERE NOT EXISTS hace el trabajo y no depende de restricciones.
   ============================================================================ */
INSERT INTO core.tipos_pedido (codigo, nombre)
SELECT 'recoger', 'Recoge en el local'
 WHERE NOT EXISTS (SELECT 1 FROM core.tipos_pedido WHERE codigo = 'recoger');


/* ============================================================================
   2. NOMBRE Y TELÉFONO TAMBIÉN PARA QUIEN RECOGE

   El procedimiento abre ficha de cliente y exige nombre y celular sólo
   cuando el tipo es 'domicilio'. Para quien recoge hacen igual de falta:
   es a quien hay que llamar —o gritar en el mostrador— cuando salga el
   pedido. La dirección y la zona siguen llegando vacías, que es lo correcto.
   ============================================================================ */
DO $blk$
DECLARE
    v_def   TEXT;
    v_nuevo TEXT;
    v_viejo CONSTANT TEXT := 'IF p_tipo = ''domicilio'' THEN';
    v_bueno CONSTANT TEXT := 'IF p_tipo IN (''domicilio'', ''recoger'') THEN';
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'sp_crear_pedido';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'api.sp_crear_pedido no existe: falta alguna migración anterior.';
    END IF;

    IF position(v_bueno IN v_def) > 0 THEN
        RAISE NOTICE 'api.sp_crear_pedido ya contemplaba «recoger». No se toca.';
        RETURN;
    END IF;

    v_nuevo := replace(v_def, v_viejo, v_bueno);

    IF v_nuevo = v_def THEN
        RAISE EXCEPTION
            'No se encontró «%» en api.sp_crear_pedido: el procedimiento cambió y esta migración hay que revisarla a mano.',
            v_viejo;
    END IF;

    EXECUTE v_nuevo;
    RAISE NOTICE 'api.sp_crear_pedido: nombre y teléfono ahora también para «recoger».';
END;
$blk$;


/* ============================================================================
   3. REVISIÓN

   Se comprueba lo que de verdad importa: que el tipo exista, que el
   procedimiento lo contemple, y que el flujo de estados le quite «en camino»
   —que es lo que diferencia un pedido para recoger de un domicilio—.
   ============================================================================ */
DO $blk$
DECLARE
    v_tipos TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM core.tipos_pedido WHERE codigo = 'recoger') THEN
        RAISE EXCEPTION 'No quedó el tipo «recoger» en core.tipos_pedido.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'api' AND p.proname = 'sp_crear_pedido'
           AND pg_get_functiondef(p.oid) LIKE '%IF p_tipo IN (''domicilio'', ''recoger'')%'
    ) THEN
        RAISE EXCEPTION 'api.sp_crear_pedido no quedó parcheado.';
    END IF;

    /* «En camino» está marcado solo_domicilio, así que fn_siguiente_estado
       se lo salta a todo lo que no sea domicilio. Si alguien algún día le
       quita esa marca, un pedido para recoger se quedaría esperando un
       domiciliario que no existe. */
    IF EXISTS (SELECT 1 FROM core.estados_pedido WHERE codigo = 'camino' AND NOT solo_domicilio) THEN
        RAISE EXCEPTION '«En camino» dejó de ser solo_domicilio: los pedidos para recoger pasarían por ahí.';
    END IF;

    SELECT string_agg(codigo, ', ' ORDER BY id) INTO v_tipos FROM core.tipos_pedido;
    RAISE NOTICE 'OK · tipos de pedido: %', v_tipos;
    RAISE NOTICE '  Se ofrece en el portal a los locales que tengan dirección configurada.';
END;
$blk$;
