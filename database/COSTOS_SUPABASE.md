# 💰 ¿Cabe Taseca en Supabase Pro ($25/mes)?

**Respuesta corta: sí, con amplio margen, siempre que se apliquen tres cambios que
ya están hechos (auditoría liviana, refresco incremental de la app y comprobantes
fuera de la base).** Sin ellos, la salida de datos habría agotado el plan en días.

Todo lo que sigue sale de **medirlo**, no de suponerlo: se simularon 30 días de
operación real sobre PostgreSQL 17 y se midieron tamaños, tiempos y el peso de
cada respuesta de la API.

---

## 1. Cómo se midió

Operación simulada de **30 días** con los procedimientos reales (disparan los
mismos triggers que producción):

| Local | Pedidos/día | Contenido |
|---|---|---|
| COMIC'ENDO AREPA | 80 | 3 productos, 60 % mesa / 40 % domicilio |
| NASCAR Bar VIP | 60 | 2 productos, mesa |
| NASCAR-Comidas | 60 | plato del chef |
| Chicharrón Mental | 60 | plato del chef |
| **Total** | **260** | **7.800 pedidos en 30 días** |

Cada pedido pasa por todos sus estados; 3 % se cancela, 2 % se anula, ~15 %
paga por transferencia con comprobante. Además, cada día: 2 menús con 3 platos,
2 cierres de inventario revisados, 10 entradas, 4 bases de caja y 4 gastos.

---

## 2. Disco (8 GB incluidos)

### Antes y después de `10_optimizacion.sql`

| Tabla | Antes | Después |
|---|---|---|
| auditoria | **42 MB** (36.983 filas) | **0,4 MB** (413 filas) |
| pedidos | 7,8 MB | 5,6 MB |
| pedido_historial | 4,9 MB | 4,8 MB |
| pedido_items | 2,1 MB | 2,0 MB |
| resto | 4,2 MB | 4,2 MB |
| **Total por mes** | **61 MB** | **17 MB** |
| **Por pedido** | 8,2 KB | **2,35 KB** |

**Qué pasaba con la auditoría:** cada cambio de estado de un pedido guardaba la
fila completa dos veces (antes y después). Un pedido genera ~6 cambios, así que
la auditoría pesaba el doble que toda la operación. Ahora:

- guarda sólo las columnas que cambiaron;
- no audita lo que ya tiene historial propio (`pedido_historial`) ni lo que es
  inmutable (entradas, anulaciones);
- de las tablas operativas audita los **cambios**, no las altas (la fila nueva ya
  dice quién y cuándo);
- `api.sp_purgar_auditoria(365)` borra por lotes lo que tenga más de un año,
  programado con **pg_cron** (incluido en Supabase).

**Qué pasaba con pedidos:** tenía índices sobre el estado y el método de pago.
Cada cambio de estado tocaba esos índices, lo que impide que PostgreSQL reescriba
la fila en su sitio (actualización HOT) y la tabla se inflaba. Esos índices apuntan
a catálogos de 4-7 filas que nunca se borran: no servían para nada. Se quitaron y
se dejó espacio libre en cada página (`fillfactor 85`). Índices de pedidos: de
3,5 MB a 0,7 MB.

### Proyección

| Escenario | Por año | Años para llenar 8 GB |
|---|---|---|
| NASCAR hoy (260 pedidos/día) | ~0,2 GB | **~35 años** |
| NASCAR ×3 (780/día) | ~0,6 GB | ~12 años |
| 10 empresas como NASCAR | ~2 GB | ~4 años → luego $0,125/GB |
| Sin optimizar (NASCAR hoy) | ~0,73 GB | ~10 años |

A la base se suman ~30-60 MB de esquemas internos de Supabase y el margen del
WAL; no cambian la conclusión. Si algún día se pasa de 8 GB, 20 GB cuestan
**$1,50/mes** adicionales.

### ⚠️ Los comprobantes NO deben vivir en la base

Hoy `core.comprobantes_pago.archivo_url` puede guardar la imagen completa
(data URL) porque así funciona el MVP local. En la simulación hubo **~38
comprobantes diarios**. Con fotos de ~150 KB:

| Dónde | Por año | Costo del GB |
|---|---|---|
| En la base (disco) | ~2 GB | $0,125 · y engorda cada backup |
| **Supabase Storage** | ~2 GB | **$0,0213** · 100 GB incluidos |

Sólo las fotos triplicarían el crecimiento de la base. **Al migrar a Supabase, la
imagen se sube a Storage y en la tabla queda la ruta** (`comprobantes/2026/09/00027.jpg`),
que es exactamente lo que ya usa la simulación.

---

## 3. Salida de datos (250 GB incluidos)

### El problema que había

La primera versión de `js/remoto.js` pedía **todos los pedidos de 31 días cada 8
segundos** en cada pantalla del panel:

| Petición | Peso | Tiempo |
|---|---|---|
| 31 días completos (lo que hacía) | **14,9 MB** | 5,8 s |

Con 6 pantallas abiertas eso son **~560 GB por día**. El plan Pro se habría
agotado en menos de un día de operación normal, y la base habría estado ocupada
todo el tiempo armando esos 14 MB.

### Cómo quedó (ya aplicado)

| Petición | Cuándo | Peso medido | Tiempo |
|---|---|---|---|
| Pedidos de hoy y ayer | al abrir el panel | ~1 MB (520 pedidos) | < 1 s |
| **Sólo lo que cambió** | cada 8 s | **2 bytes** si no hay cambios · **1,4 KB** por pedido cambiado | 15-23 ms |
| Historial de 31 días | una vez, al entrar a **Ventas** | 14,9 MB | 2-6 s |
| Catálogo (carta, menú, unidades) | al abrir y cada 5 min | 41 KB | 15 ms |
| Pantalla oculta (otra pestaña) | — | **0**: no consulta | — |

### Estimación mensual

Supuestos: 260 pedidos/día, **6 pantallas** del panel abiertas 14 horas, 400
visitas diarias al portal, Ventas abierto 5 veces al día.

| Concepto | Por mes |
|---|---|
| Refrescos incrementales vacíos (6 pantallas × 6.300/día) | 0,3 GB |
| Pedidos que cambian (260 × 6 cambios × 6 pantallas) | 0,6 GB |
| Aperturas del panel (6 × 4 al día × 1 MB) | 0,7 GB |
| Historial de Ventas (5 × 15 MB al día) | 2,3 GB |
| Catálogo en el panel (cada 5 min) | 1,2 GB |
| Portal de clientes (400 visitas) | 1,0 GB |
| Comprobantes vistos por caja | 0,2 GB |
| **Total** | **~6 GB de 250 GB (2,5 %)** |

El mayor consumo restante es el historial de Ventas. En la fase 2 se reemplaza por
las vistas agregadas que ya existen (`api.v_ventas_diarias`, `api.v_ventas_producto`):
de 15 MB a unos pocos KB.

> Los archivos de la aplicación (HTML, JS, CSS) no se sirven desde Supabase en
> este cálculo. Si se alojan en Supabase Storage, suman ~1 MB por visita nueva
> (con caché del navegador, mucho menos).

---

## 4. Cómputo — lo que no aparece en tu lista y más importa

El plan Pro incluye **$10 de crédito de cómputo**, que cubre la instancia más
pequeña (**Micro**: 1 GB de RAM, 2 núcleos ARM compartidos). Es lo que determina
si la base aguanta, más que el disco.

| Operación medida | Tiempo |
|---|---|
| Crear un pedido completo (con triggers) | **1 ms** |
| Refresco incremental del panel | 3-15 ms |
| Catálogo público | 15 ms |
| Historial de 31 días | 2-6 s ⚠️ |

En hora pico (~40 pedidos/hora y 6 pantallas refrescando cada 8 s ≈ 1 consulta
por segundo) una Micro está prácticamente ociosa. Lo único pesado es el historial
de Ventas; por eso se descarga sólo a pedido y en la fase 2 pasa a vistas
agregadas.

---

## 5. Veredicto

| Recurso | Incluido | Uso estimado (NASCAR) | Estado |
|---|---|---|---|
| Disco | 8 GB | ~0,2 GB/año | ✅ sobra |
| Salida | 250 GB/mes | ~6 GB/mes | ✅ sobra |
| Salida en caché | 250 GB/mes | ~0 | ✅ |
| Storage (comprobantes) | 100 GB | ~2 GB/año | ✅ sobra |
| Usuarios activos (MAU) | 100.000 | 0 (el login es propio, no Supabase Auth) | ✅ |
| Cómputo | Micro ($10 incluidos) | carga baja | ✅ |
| Backups | 7 días | — | ✅ |
| **Total** | **$25/mes** | **sin cobros adicionales** | ✅ |

**Con 10 empresas del tamaño de NASCAR** el plan sigue alcanzando: ~60 GB de
salida al mes y ~2 GB de disco al año. Lo primero que se agotaría, dentro de
varios años, es el disco, a $0,125 por GB adicional.

---

## 6. Qué verificar al migrar a Supabase

Estos puntos no se pueden probar sin un proyecto de Supabase real:

1. **Tokens (JWT).** Hoy la base firma su propio token. El Data API de Supabase
   (que ya es PostgREST) valida los tokens con las claves del proyecto: hay que
   firmar con esa misma clave o mover el login a Supabase Auth / una Edge
   Function. Es el cambio más importante de la migración.
2. **Esquema expuesto.** En *Settings → API → Exposed schemas* agregar `rest`.
   Los roles `taseca_anon` / `taseca_app` se mapean a `anon` / `authenticated`.
3. **Crear la base.** Supabase ya trae la base `postgres`: `00_crear_base_datos.sql`
   no aplica. El orden alfabético en español se logra con
   `COLLATE "es-CO-x-icu"` en las consultas que lo necesiten.
4. **pg_cron.** Activar la extensión y programar
   `api.sp_purgar_auditoria(365)` y `api.sp_refrescar_reportes()` (instrucciones al
   final de `10_optimizacion.sql`).
5. **Comprobantes a Storage** (ver sección 2).
6. **Tiempo real.** Supabase Realtime puede reemplazar el refresco cada 8 s: cero
   peticiones mientras no pase nada.
