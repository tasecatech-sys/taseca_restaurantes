/* ============================================================================
   TASECA · 29 · CADA BILLETERA POR SU LADO
   ----------------------------------------------------------------------------
   Había un solo método llamado «Transferencia · Nequi, Daviplata o
   Bancolombia». Al cuadrar la caja eso no sirve: entra plata por tres sitios
   distintos y el informe sólo sabe decir «transferencia». Para saber cuánto
   entró por Nequi hay que abrir los pedidos uno por uno.

   Ahora son métodos separados: Nequi, Daviplata y Bre-B.

   LO QUE **NO** CAMBIA: EL ARQUEO

     `core.metodos_pago.grupo_caja` dice a qué columna del cruce va el
     dinero, y las tres van a 'transferencia', igual que el método viejo. El
     cruce de caja sigue mostrando UNA columna de transferencias, porque
     para el arqueo las tres son lo mismo: dinero que no está en el cajón.

     Separadas para el control, juntas para cuadrar. Si fueran a 'otros' o,
     peor, a 'efectivo', el arqueo de todos los días anteriores dejaría de
     cuadrar.

   EL MÉTODO VIEJO NO SE BORRA

     Los pedidos ya pagados apuntan a él (`metodo_pago_id` es FK con ON
     DELETE RESTRICT, y con razón: una factura tiene que seguir diciendo con
     qué se pagó). Se queda en el catálogo, se le cambia el nombre a «Otra
     transferencia» —que es lo que pasa a ser— y se APAGA para cada empresa.

     Apagarlo no borra nada y se deshace con un clic desde
     ⚙️ Configuración → 💳 Métodos de pago. Quien reciba por un banco que no
     sea de los tres lo vuelve a encender.

   POR QUÉ SE TOCA A TODAS LAS EMPRESAS

     `core.metodos_pago` es un catálogo global: los métodos nuevos quedan
     disponibles para todas. Y el genérico se apaga en todas porque el
     problema es el mismo en todas — mientras siga encendido, la gente lo
     sigue eligiendo y el control sigue sin servir.

   Ninguna venta cambia de valor ni de grupo. Se puede ejecutar más de una
   vez.
   Requiere: 00 … 28 instalados.
   ============================================================================ */

SET search_path = core, public;


/* ============================================================================
   1. LOS MÉTODOS NUEVOS, EN EL CATÁLOGO GLOBAL
   ============================================================================ */
INSERT INTO core.metodos_pago (codigo, nombre, grupo_caja) VALUES
    ('nequi',     'Nequi',     'transferencia'),
    ('daviplata', 'Daviplata', 'transferencia'),
    ('breb',      'Bre-B',     'transferencia')
ON CONFLICT (codigo) DO UPDATE
   SET nombre     = EXCLUDED.nombre,
       grupo_caja = EXCLUDED.grupo_caja;

/* El genérico pasa a ser lo que de verdad es: el cajón de sastre. */
UPDATE core.metodos_pago
   SET nombre = 'Otra transferencia'
 WHERE codigo = 'transferencia';


/* ============================================================================
   2. QUÉ OFRECE CADA EMPRESA

   Se le dan los tres a toda empresa que ya ofreciera transferencias: si no
   las ofrecía, no es asunto de este archivo meterle métodos nuevos.

   El `orden` sale del que tenía el genérico, para que aparezcan donde la
   gente ya está acostumbrada a buscarlos.
   ============================================================================ */
INSERT INTO core.empresa_metodos_pago (empresa_id, metodo_pago_id, activo, descripcion, orden)
SELECT viejo.empresa_id,
       nuevo.id,
       TRUE,
       x.descripcion,
       viejo.orden + x.desplazamiento
  FROM core.empresa_metodos_pago viejo
  JOIN core.metodos_pago mp_viejo ON mp_viejo.id = viejo.metodo_pago_id
                                 AND mp_viejo.codigo = 'transferencia'
 CROSS JOIN (VALUES
        ('nequi',     'Transfieres por Nequi y despachamos apenas confirmemos el pago.',     0),
        ('daviplata', 'Transfieres por Daviplata y despachamos apenas confirmemos el pago.', 1),
        ('breb',      'Pagas con tu llave Bre-B desde cualquier banco.',                     2)
     ) AS x (codigo, descripcion, desplazamiento)
  JOIN core.metodos_pago nuevo ON nuevo.codigo = x.codigo
ON CONFLICT (empresa_id, metodo_pago_id) DO NOTHING;

/* Y se apaga el genérico donde se acaban de poner los tres. Nunca se deja a
   una empresa sin NINGÚN método: si por lo que sea no entró ninguno de los
   nuevos, el viejo se queda encendido. */
UPDATE core.empresa_metodos_pago emp
   SET activo = FALSE
  FROM core.metodos_pago mp
 WHERE mp.id = emp.metodo_pago_id
   AND mp.codigo = 'transferencia'
   AND emp.activo
   AND EXISTS (
        SELECT 1
          FROM core.empresa_metodos_pago otro
          JOIN core.metodos_pago m2 ON m2.id = otro.metodo_pago_id
         WHERE otro.empresa_id = emp.empresa_id
           AND otro.activo
           AND m2.codigo IN ('nequi', 'daviplata', 'breb'));


/* ============================================================================
   3. COMPROBACIÓN
   ============================================================================ */
DO $$
DECLARE
    v_nuevos   INTEGER;
    v_grupos   INTEGER;
    v_sin_nada INTEGER;
BEGIN
    SELECT count(*) INTO v_nuevos
      FROM core.metodos_pago WHERE codigo IN ('nequi', 'daviplata', 'breb');

    SELECT count(*) INTO v_grupos
      FROM core.metodos_pago
     WHERE codigo IN ('nequi', 'daviplata', 'breb', 'transferencia')
       AND grupo_caja <> 'transferencia';

    /* Nadie puede quedarse sin forma de cobrar. */
    SELECT count(*) INTO v_sin_nada
      FROM core.empresas e
     WHERE EXISTS (SELECT 1 FROM core.empresa_metodos_pago x WHERE x.empresa_id = e.id)
       AND NOT EXISTS (SELECT 1 FROM core.empresa_metodos_pago x
                        WHERE x.empresa_id = e.id AND x.activo);

    IF v_nuevos <> 3 THEN
        RAISE EXCEPTION 'Faltan métodos nuevos: hay % de 3.', v_nuevos;
    END IF;
    IF v_grupos <> 0 THEN
        RAISE EXCEPTION '% método(s) de transferencia quedaron fuera del grupo «transferencia»: el arqueo no cuadraría.', v_grupos;
    END IF;
    IF v_sin_nada <> 0 THEN
        RAISE EXCEPTION '% empresa(s) se quedaron sin ningún método de pago activo.', v_sin_nada;
    END IF;

    RAISE NOTICE '✔ Nequi, Daviplata y Bre-B separados, los tres al grupo «transferencia».';
    RAISE NOTICE '  El genérico queda apagado; se reactiva desde Configuración → Métodos de pago.';
END;
$$;
