/* ============================================================================
   TASECA · 36 · UNA EMPRESA NUEVA NACE CON NEQUI, DAVIPLATA Y BRE-B
   ----------------------------------------------------------------------------
   EL PROBLEMA

     api.sp_alta_empresa -lo que corre al crear una empresa desde el panel
     de Taseca- le daba tres métodos de pago:

         efectivo, datafono, transferencia

     «transferencia» es justo la que la migración 29 desactivó y renombró
     «Otra transferencia» al partirla en Nequi, Daviplata y Bre-B. Así que
     un cliente nuevo nacía SIN ninguna billetera y con un método muerto
     encendido. La 29 arregló los datos de las empresas que ya existían,
     pero no la función que crea las siguientes.

     Es el mismo descuido que el de rest.reportar_pago (migración 34): la
     29 tocó los datos y se dejó el código.

   QUÉ HACE ESTE SCRIPT

     1. Parchea api.sp_alta_empresa para que reparta los seis métodos, con
        las billeteras encendidas y la transferencia genérica apagada.
     2. Rellena las empresas que ya existan a las que les falte alguno.

   POR QUÉ UN replace() Y NO REESCRIBIR LA FUNCIÓN

     sp_alta_empresa es larga y hace muchas más cosas -módulos, categorías
     de gasto, consecutivos-. Reescribirla entera desde una copia de hoy
     perdería cualquier otro cambio que haya entrado en ella. Se tocan
     cuatro líneas, y si alguna no está, avisa en vez de seguir.

   Se puede ejecutar más de una vez.
   Requiere: 00 … 35 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. LA FUNCIÓN QUE CREA EMPRESAS
   ============================================================================ */
DO $blk$
DECLARE
    v_def   TEXT;
    v_nuevo TEXT;
    v_i     INTEGER;
    /* Cada par: lo que hay que encontrar, y por qué se cambia. Van de a una
       línea y sin saltos, para no depender de si la base guarda el cuerpo
       con CRLF o con LF. */
    v_busca TEXT[] := ARRAY[
        'mp.id, TRUE, x.descripcion, x.orden',
        '(VALUES (''efectivo'', ''Le pagas al domiciliario cuando recibas.'', 1),',
        '(''datafono'', ''El domiciliario lleva datáfono. Tarjeta débito o crédito.'', 2),',
        '(''transferencia'', ''Transfieres ahora y despachamos apenas confirmemos el pago.'', 3)) AS x (metodo, descripcion, orden)'
    ];
    v_pone TEXT[] := ARRAY[
        'mp.id, x.activo, x.descripcion, x.orden',
        '(VALUES (''efectivo'', TRUE, ''Le pagas al domiciliario cuando recibas.'', 1),',
        '(''datafono'', TRUE, ''El domiciliario lleva datáfono. Tarjeta débito o crédito.'', 2),',
        '(''nequi'', TRUE, ''Transfieres por Nequi y despachamos apenas confirmemos el pago.'', 3), ' ||
        '(''daviplata'', TRUE, ''Transfieres por Daviplata y despachamos apenas confirmemos el pago.'', 4), ' ||
        '(''breb'', TRUE, ''Pagas con tu llave Bre-B desde cualquier banco.'', 5), ' ||
        '(''transferencia'', FALSE, ''Transfieres ahora y despachamos apenas confirmemos el pago.'', 6)) AS x (metodo, activo, descripcion, orden)'
    ];
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'sp_alta_empresa';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'api.sp_alta_empresa no existe: falta la migración 15.';
    END IF;

    IF position('''nequi'', TRUE,' IN v_def) > 0 THEN
        RAISE NOTICE 'api.sp_alta_empresa ya repartía las billeteras. No se toca.';
    ELSE
        v_nuevo := v_def;
        FOR v_i IN 1 .. array_length(v_busca, 1) LOOP
            IF position(v_busca[v_i] IN v_nuevo) = 0 THEN
                RAISE EXCEPTION 'No se encontró en api.sp_alta_empresa: «%». La función cambió y esta migración hay que revisarla a mano.',
                    left(v_busca[v_i], 60);
            END IF;
            v_nuevo := replace(v_nuevo, v_busca[v_i], v_pone[v_i]);
        END LOOP;

        EXECUTE v_nuevo;
        RAISE NOTICE 'api.sp_alta_empresa: ahora reparte los seis métodos.';
    END IF;
END;
$blk$;


/* ============================================================================
   2. LAS EMPRESAS QUE YA EXISTEN

   A las que les falte alguno se lo añadimos. ON CONFLICT DO NOTHING: lo que
   ya está no se toca, así que si alguien apagó un método a mano, se queda
   apagado.
   ============================================================================ */
INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo, descripcion, orden)
SELECT e.id, mp.id, x.activo, x.descripcion, x.orden
  FROM core.empresas e
 CROSS JOIN (VALUES ('efectivo',      TRUE,  'Le pagas al domiciliario cuando recibas.', 1),
                    ('datafono',      TRUE,  'El domiciliario lleva datáfono. Tarjeta débito o crédito.', 2),
                    ('nequi',         TRUE,  'Transfieres por Nequi y despachamos apenas confirmemos el pago.', 3),
                    ('daviplata',     TRUE,  'Transfieres por Daviplata y despachamos apenas confirmemos el pago.', 4),
                    ('breb',          TRUE,  'Pagas con tu llave Bre-B desde cualquier banco.', 5),
                    ('transferencia', FALSE, 'Transfieres ahora y despachamos apenas confirmemos el pago.', 6)
            ) AS x (metodo, activo, descripcion, orden)
  JOIN core.metodos_pago mp ON mp.codigo = x.metodo
ON CONFLICT (empresa_id, metodo_pago_id) DO NOTHING;


/* ============================================================================
   3. REVISIÓN
   ============================================================================ */
DO $blk$
DECLARE
    v_def    TEXT;
    v_faltan INTEGER;
    v_emp    INTEGER;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'sp_alta_empresa';

    IF position('''nequi''' IN v_def) = 0
       OR position('''daviplata''' IN v_def) = 0
       OR position('''breb''' IN v_def) = 0 THEN
        RAISE EXCEPTION 'api.sp_alta_empresa no quedó repartiendo las tres billeteras.';
    END IF;

    IF position('(''transferencia'', FALSE,' IN v_def) = 0 THEN
        RAISE EXCEPTION 'La transferencia genérica debería quedar apagada en las empresas nuevas.';
    END IF;

    /* Ninguna empresa puede quedarse sin un método del catálogo. */
    SELECT count(*) INTO v_faltan
      FROM core.empresas e
     CROSS JOIN core.metodos_pago mp
     WHERE NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago emp
                        WHERE emp.empresa_id = e.id AND emp.metodo_pago_id = mp.id);

    IF v_faltan > 0 THEN
        RAISE EXCEPTION 'Quedaron % huecos empresa-método sin rellenar.', v_faltan;
    END IF;

    SELECT count(*) INTO v_emp FROM core.empresas;
    RAISE NOTICE 'OK · las % empresas tienen los % métodos del catálogo, y las nuevas nacerán igual.',
        v_emp, (SELECT count(*) FROM core.metodos_pago);
END;
$blk$;
