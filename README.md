# 🏁 NASCAR · Restaurante

Landing page y sistema de pedidos para el restaurante NASCAR (dos sucursales en Bogotá).

Funciona **sin instalar nada**: son archivos HTML, CSS y JavaScript. Se abren
directamente en el navegador.

---

## Cómo abrirlo

**Opción A — doble clic (lo más rápido)**

Abre `index.html`. Listo.

**Opción B — con servidor local (recomendado)**

Doble clic en `INICIAR.bat`. Abre el navegador solo y quedan disponibles:

| Pantalla | Dirección |
|---|---|
| Página pública | `http://localhost:8000/` |
| Panel interno | `http://localhost:8000/empleados.html` |
| Pedido de mesa | `http://localhost:8000/mesa.html?suc=1&mesa=5` |

El servidor usa Python (ya está instalado en este equipo). Para detenerlo, cierra la ventana negra.

> La opción B es mejor porque los enlaces de las mesas quedan limpios y el
> comportamiento es idéntico al que tendrá cuando se suba a internet.

**PIN del panel administrativo: `2580`** (se cambia en `js/data.js`).

---

## 🐘 Base de datos PostgreSQL

La carpeta [`database/`](database/README.md) tiene la base de datos completa del
proyecto para PostgreSQL (multiempresa, 3FN, PK SERIAL, vistas, triggers,
funciones y procedimientos almacenados), con la estructura real de NASCAR
cargada y 20 pruebas. Instrucciones para DBeaver en
[`database/README.md`](database/README.md).

### Conectada con PostgREST (fase 1)

Servida por `http://`, la aplicación **lee y escribe en PostgreSQL** a través de
PostgREST (`INICIAR-POSTGREST.bat`, puerto 3000). Instalación en
[`database/README.md`](database/README.md#api-rest-con-postgrest-fase-1).

| Ya usa la base | Sigue en `localStorage` (fase 2) |
|---|---|
| Login con PIN (token JWT) · portal · mesa · crear pedido · seguimiento · cocina, mesero y entregas · estados · cancelar y anular · pagos y comprobantes · ventas · **edición de carta y menú del día** (fase 2 · bloque 1, `database/11_fase2_carta_menu.sql`) · **usuarios y unidades / locales** (fase 2 · bloque 2, `database/12_fase2_usuarios_unidades.sql`) · **stock, entradas y cierres de inventario**, también `cierre.html` (fase 2 · bloque 3, `database/13_fase2_inventario.sql`) · **base de caja, gastos y cruce de caja** (fase 2 · bloque 4, `database/14_fase2_caja_gastos.sql`) · **configuración, ajustes y panel de Taseca** (fase 2 · bloque 5, `database/15_fase2_configuracion_plataforma.sql`) | — (nada: la fase 2 está completa) |

- `js/remoto.js` es el único punto de contacto con la API: carga los datos en la
  memoria del Store con la forma de siempre, así que las pantallas no cambiaron.
- **Lo del servidor nunca se escribe en `localStorage`**: los datos del modo
  local de ese navegador quedan intactos.
- En modo base de datos sólo quedan bloqueadas las acciones masivas del modo
  local (importar, borrar todo, restablecer): avisan en vez de guardar.
- Si PostgREST está apagado, aparece un aviso rojo; no se mezcla con datos
  locales.
- `?backend=local` al final de la dirección trabaja en modo local como antes.
  Abierto como archivo (`NASCAR-movil.html`), siempre es local.
- Desde el celular por Wi-Fi funciona igual: la API se busca en el mismo equipo
  que sirve la página.

---

## 📱 Cómo abrirlo en el celular

Hay dos caminos. **El segundo es mejor**, pero el primero no necesita nada.

### Camino 1 — Mandar el archivo `NASCAR-movil.html`

`NASCAR-movil.html` es **todo el proyecto en un solo archivo** (212 KB). Mándalo
por WhatsApp, Drive o correo, y en el celular ábrelo con doble toque.

Trae las tres pantallas juntas, con una barra arriba para cambiar entre ellas:

| 🏁 Pedir | 🍽 Mesa | 📊 Panel |
|---|---|---|

En la pantalla de **Mesa** hay un selector de sucursal y mesa, porque en el
archivo suelto no existe una dirección por mesa.

> **Importante:** hay que mandar **solo ese archivo**. Si mandas `index.html`
> por separado, en el celular se ve sin diseño y sin funcionar, porque le
> faltan las carpetas `css/` y `js/`.

**Si cambias algo** (precios, sucursales, textos), hay que volver a generarlo:

```bash
py build-movil.py
```

Ese comando lee los archivos originales y regenera `NASCAR-movil.html`.
Nunca edites `NASCAR-movil.html` a mano: se sobrescribe.

**En iPhone y iPad este camino no sirve.** Al tocar un `.html` desde WhatsApp,
Archivos o el correo, iOS lo muestra como *vista previa* y no ejecuta la app:
es una restricción de Apple, no del sistema. El archivo lo detecta y muestra un
aviso que explica cómo abrirlo. En iPhone usa el **camino 2**.

**Limitación de este camino:** algunos navegadores de celular no dejan guardar
datos cuando se abre un archivo local. Si pasa, la app avisa una vez y sigue
funcionando completa, pero los pedidos se pierden al cerrar la pestaña. Para
mostrar el sistema funcionando sirve perfecto.

### Camino 2 — Desde el Wi-Fi del restaurante (recomendado)

Doble clic en **`INICIAR-EN-RED.bat`** en el computador. Te muestra en pantalla
una dirección tipo `http://192.168.1.20:8000/`.

En el celular, **conectado al mismo Wi-Fi**, escribe esa dirección en el navegador.

Funciona igual en **iPhone, iPad, Android y computador**, desde Safari, Chrome
o cualquier navegador. En iPhone se puede dejar como app: Safari → Compartir →
*Agregar a pantalla de inicio*.

Ventajas sobre el camino 1:
- Los datos sí se guardan bien en el celular.
- Los enlaces de mesa (`?suc=1&mesa=5`) funcionan tal cual, así que **los QR ya sirven**.
- No hay que regenerar nada al hacer cambios: se refresca y ya.

La primera vez Windows pregunta si permite Python en la red: hay que aceptar,
o el celular no podrá abrir la página. El computador debe quedar encendido y
con la ventana negra abierta.

> Ojo: aunque el celular y el computador vean la misma página, **cada uno
> guarda sus propios datos**. Un pedido hecho desde el celular no aparece en el
> panel del computador. Eso se resuelve con el paso siguiente (ver más abajo).

---

## Los tres portales

Tres puertas distintas, y no se cruzan. Cada una tiene su público, su
dirección y su forma de entrar.

```text
PORTAL CLIENTE            PORTAL OPERATIVO           PORTAL TASECA
index.html                empleados.html             taseca-admin.html
mesa.html                 cierre.html
      │                          │                          │
   pedir                  el equipo del negocio      la plataforma
```

Las direcciones viven en un solo sitio, `NASCAR.PORTALES` (`js/data.js`).
Fíjate en que **ninguna enlaza hacia arriba**: desde el mapa de rutas no hay
forma de que el portal del cliente conozca los otros.

### 1. Portal cliente — `index.html` · `mesa.html`

Quien viene a pedir. Ve la información del restaurante, la carta y el menú del
día; arma su pedido, elige mesa o domicilio, pone sus datos, adjunta el
comprobante si paga por transferencia y lo envía.

**Y nada más.** No hay «Iniciar sesión», ni «Administración», ni «Panel», ni
«Soy empleado». Tampoco enlaces escondidos con CSS: no existen en el marcado.

| | |
|---|---|
| **`index.html`** | La página pública: hero, menú del día, carta completa, sucursales y el pedido a domicilio. |
| **`mesa.html?suc=1&mesa=5`** | Lo que se abre al escanear el QR de la mesa. Es pantalla de **cliente**, no del mesero: el comensal pide desde su propio celular. |

### 2. Portal operativo — `empleados.html` · `cierre.html`

El equipo del negocio: Admin, Administrador, Caja, Mesero, Cocinero y
Domiciliario. Cada uno entra con su usuario y ve **sólo sus secciones**.

Es una dirección aparte, y **el portal del cliente no enlaza a ella**. Quien la
escriba a mano se encuentra el login.

`cierre.html` es la pantalla de registro del cierre que se reparte por WhatsApp
al equipo. **También pide usuario**: al abrirla sin sesión lo que se pinta es el
login —el mismo del sistema, no un segundo mecanismo—, y el cierre queda firmado
por quien entró.

La mesera usa **su propio perfil**, el mismo con el que toma los pedidos: el rol
`mesero` lleva el permiso `cierres_registrar`. Un cocinero o un domiciliario que
abran ese enlace ven **«Acceso no autorizado»**, con su nombre y su rol, y un
botón para entrar con otro usuario.

Por eso el campo «Quién registra» ya no se escribe a mano: es de sólo lectura y
sale de la sesión. El cierre guarda `usuarioId` y `usuarioNombre`, así que la
auditoría dice quién contó, no un nombre tecleado.

**No queda ninguna ruta operativa sin autenticación.**

### 3. Portal Taseca — `taseca-admin.html`

El administrador de la plataforma. Su propia dirección, su propia marca y su
propio login. **No se enlaza desde el portal del cliente ni desde el del
negocio**, ni siquiera desde su login: se entra escribiendo su dirección.

Ver **🏢 Taseca y las empresas clientes** más abajo.

### La protección no es ocultar el enlace

Quitar el enlace es la mitad. La otra:

- **`empleados.html`** comprueba la sesión **antes de pintar nada**. Sin ella no
  se muestra el panel y ningún dato del negocio llega al DOM — comprobado
  sembrando un pedido y un gasto y verificando que ni el plato, ni el cliente,
  ni los montos aparecen en el HTML. Con una sesión cuyo rol no tenga ninguna
  sección habilitada, sale **«Acceso no autorizado»** en vez de un panel vacío.
- **`taseca-admin.html`** exige además el **nivel**: `esPlataforma()` y el
  permiso `plataforma`. Un admin de empresa ve «Acceso denegado».
- Y cada acción vuelve a comprobar su permiso por su cuenta
  (`NASCAR.Auth.exigir`), esté o no visible el botón.

### Cliente y usuario interno son cosas distintas

Un pedido guarda los datos del cliente **dentro del propio pedido**
(`pedido.cliente`), y nada más. Nunca crea un usuario, ni una sesión, ni un rol.
Comprobado: después de que un cliente pida, la lista de usuarios sigue teniendo
exactamente los seis del equipo.

Los usuarios internos se crean sólo desde 👥 Usuarios (por el Admin de la
empresa) o en el alta de la empresa (por Taseca). No hay ninguna vía por la que
pedir convierta a nadie en empleado.

### Preparado para el despliegue

Hoy son archivos porque el MVP es local. El día del despliegue se cambia
`NASCAR.PORTALES` y ya:

```text
index.html          →  cliente.tienda.com
mesa.html           →  cliente.tienda.com/mesa
empleados.html      →  cliente.tienda.com/empleados
cierre.html         →  cliente.tienda.com/empleados/cierre
taseca-admin.html   →  platform.taseca.tech
```

El portal de Taseca queda en **otro dominio** a propósito: no cuelga de ninguna
empresa, ni siquiera en la URL.

### En la versión de un solo archivo

`NASCAR-movil.html` no tiene direcciones —es un archivo—, así que la separación
se hace en la barra de abajo: **sin sesión sólo se ofrece el portal del
cliente**. Los destinos operativos aparecen al entrar. Se llega a ellos
escribiendo `#panel` o `#cierre`, y ahí manda el login igual que en la versión
de varios archivos.

`taseca-admin.html` no viaja en ese archivo.

---

## 🧭 La barra lateral

Los dos paneles —el de Taseca y el de cada empresa— navegan con la **misma
barra lateral colapsable**. Es un solo componente, no dos:

```text
css/sidebar.css   la estructura: grid, colapso, drawer, transiciones
js/sidebar.js     el comportamiento: colapsar, recordar, cajón, aria
        │
        ├── piel de empresa   → css/styles.css  (tema del cliente)
        └── piel de Taseca    → css/taseca.css  (variables --platform-*)
```

Antes de esta fase sólo Taseca tenía barra lateral; el panel de empresa
navegaba con **pestañas horizontales** que se salían de la pantalla cuando el
rol tenía muchas secciones. Ahora los dos usan lo mismo.

### Expandido y colapsado

| | Ancho | Qué se ve |
|---|---|---|
| **Expandido** | 236 px (244 en Taseca) | Marca completa, icono + nombre de cada sección, contadores |
| **Colapsado** | 64 px (68 en Taseca) | Isotipo, iconos y el botón de expandir |

El botón vive en la propia barra y cambia con el estado: **←** «Contraer menú»
cuando está abierta, **→** «Expandir menú» cuando está encogida.

El punto de todo esto es el ancho: la columna del grid **se encoge de verdad**,
no se esconde detrás de un hueco reservado. El contenido gana **172 px** reales
en cualquier resolución, y las tablas, tarjetas y tableros lo aprovechan porque
dentro del panel el contenido ya no tiene el límite de 1200 px de la página
pública.

### Grupos por contexto de trabajo

Con 17 opciones el menú del Admin era una lista larga. Ahora van en cuatro
grupos que se abren y se cierran:

| Grupo | Opciones |
|---|---|
| **Operación** | Mesas · Pedidos · Cocina · Entregas |
| **Ventas y caja** | Ventas · Pagos · Cruce de caja · Gastos |
| **Productos e inventario** | Menú del día · Carta · Stock · Entradas · Registrar cierre · Cierres de inventario |
| **Administración** | Unidades / Locales · Usuarios · Configuración · Ajustes |

Hay **dos niveles** que se combinan:

1. **Barra completa / encogida** — el botón ← →.
2. **Grupos abiertos / cerrados** — clic en el título del grupo (▾ abierto, ▸ cerrado).

- Con la barra **encogida** no hay títulos: se ven todos los iconos a los que
  el perfil tiene acceso, con una línea fina entre grupos y su tooltip. Aunque
  un grupo esté cerrado sus iconos siguen ahí, para que la navegación no se
  pierda. Al expandir, cada grupo vuelve a como estaba.
- Si se **llega** a una sección cuyo grupo estaba cerrado (al entrar o desde un
  enlace), el grupo se abre. Si el usuario cierra el grupo de la sección en la
  que está, el título lo marca con la barra de color.
- El estado de cada grupo se recuerda por panel (`nascar.sidebar.grupos.empresa`).

**«Cierre» y «Cierres» no eran lo mismo.** *Cierre* es el formulario donde se
cuentan las existencias físicas de una jornada por área (permiso
`cierres_registrar`, el de la mesera); *Cierres* es la consulta de esos
cierres, su revisión y el cruce de inventario (permiso `cierres`). Los dos son
de **inventario** —el conteo no lleva dinero—, así que van en *Productos e
inventario* y con nombres que no se confunden: **Registrar cierre** y
**Cierres de inventario**. *Cruce* pasa a **Cruce de caja**, para no
confundirlo con el cruce de inventario.

**Los grupos no tocan permisos.** Cada `.tab` se sigue ocultando con
`aplicarPermisos()` exactamente igual, cada sección sigue comprobando el acceso
al abrirse, y un grupo que se queda sin opciones visibles desaparece entero:

| Rol | Lo que ve |
|---|---|
| Admin | Los 4 grupos completos (18 opciones) |
| Administrador | Operación (Pedidos) · Ventas y caja (4) · Productos e inventario (6) · Administración (Ajustes) |
| Caja | Ventas y caja (Pagos, Cruce de caja, Gastos) · Productos e inventario (Entradas) |
| Mesero | Operación (Mesas) · Productos e inventario (Registrar cierre) |
| Cocinero | Operación (Cocina) |
| Domiciliario | Operación (Entregas) |

### Tooltips

Con la barra encogida, el icono solo no basta. Al pasar el ratón sale el nombre
de la sección, pintado desde `data-titulo` —que se rellena solo con el texto
que ya tiene el botón, para que nunca se desincronicen—. Cada elemento lleva
además su `aria-label`, y el activo se distingue por **fondo y barra lateral**,
no sólo por color.

### Móvil y tablet

Por debajo de 900 px la barra se convierte en un **cajón** que entra desde la
izquierda, con fondo oscuro detrás. Se cierra al elegir una opción —si no,
taparía justo lo que se acaba de abrir—, al tocar fuera o con `Escape`. En el
cajón el menú va siempre completo: el colapso es cosa de escritorio.

### La preferencia se recuerda

Se guarda en `localStorage`, **una por panel**: se puede tener el de Taseca
encogido y el de la empresa abierto. Sobrevive a recargar, a navegar entre
secciones y a cambiar de usuario o de empresa. Y sólo la cambia el usuario:
navegar nunca abre ni cierra la barra por su cuenta.

### Los permisos no se tocaron

Esto es sólo presentación. Los botones del panel de empresa conservan su clase
`.tab` y su `data-tab`, así que `aplicarPermisos()` sigue decidiendo cuáles se
ven **exactamente igual** que cuando eran pestañas. `js/sidebar.js` no sabe de
roles, permisos ni módulos: no puede convertirse en una forma de saltárselos.

| Rol | Secciones |
|---|---|
| Admin | 17 · Administrador | 12 · Caja | 4 · Mesero | 2 · Cocinero | 1 · Domiciliario | 1 |

### Cada panel con su marca

La navegación **no se mezcla**: en Taseca van opciones de plataforma, en la
empresa las del negocio.

- **Taseca** — dorado `#d4a437`, Inter, y el isotipo del triángulo con su caja
  y su proporción intactas al colapsar.
- **Cada empresa** — sus propios colores y tipografía, que salen de su `theme`.
  NASCAR sigue en rojo `#e4002b` con Barlow Condensed; una empresa con tema
  morado y Poppins ve su barra morada y en Poppins. **Ninguna variable
  `--platform-*` llega al panel de una empresa.**

---

## 🏪 Unidades / locales

Una empresa cliente de Taseca no es necesariamente un solo restaurante. NASCAR,
por ejemplo, opera varios puntos distintos:

```text
TASECA PLATFORM
└── EMPRESA · NASCAR            datos, tema, módulos contratados, usuarios
    ├── NASCAR-Comidas          🍽️ Restaurante   · sólo menú del día
    ├── Chicharrón Mental       🍽️ Restaurante   · sólo menú del día
    ├── NASCAR Bar VIP          🍺 Bar           · carta + inventario (29 productos)
    └── COMIC'ENDO AREPA        🫓 Arepera        · carta (58) + inventario (18 insumos)
          └── operación propia: carta, categorías, menú del día, pedidos,
              ventas, pagos, gastos, base de caja, cruce, stock, entradas, cierres
```

Los cuatro locales están en la misma zona comercial: Av. Calle 80 # 102-52,
Local 14, Bogotá. Mismo teléfono y WhatsApp (320 212 0632). No tienen zonas de
domicilio configuradas. Comparten empresa, tema, módulos y usuarios; **no**
comparten carta, inventario ni caja.

- **Empresa** = el cliente de Taseca (NASCAR). Tiene sus datos, su tema, sus
  módulos (Básico, Stock, Cierre) y sus usuarios.
- **Unidad / local** = un punto de operación de esa empresa. Lo operativo le
  pertenece a ella.

### La unidad es la sucursal de siempre

No hay una entidad nueva paralela: la **sucursal** que ya existía es la
unidad, con campos añadidos. Se guarda en `nascar.sucursales.v1` y todo lo
operativo sigue apuntando a ella con `sucursalId`. Por eso **ningún pedido,
cierre, gasto, base o entrada histórico se reescribió**. En pantalla se llama
*Unidad / Local*.

| Campo | Qué es |
|---|---|
| `id`, `empresaId` | Identidad y dueño. El id se numera dentro de la empresa |
| `nombre`, `corto` | Nombre del local y nombre corto (único en la empresa; va en los códigos de cierre) |
| `tipoNegocio` | Restaurante · Bar · Arepera / Comidas · Cafetería · Frutería · Comidas rápidas · Heladería · Otro |
| `activa` → `estado` | ACTIVA / INACTIVA (el estado se deriva; se guarda un solo dato) |
| `direccion`, `ciudad`, `telefono`, `whatsapp`, `horario`, `mapa` | Contacto |
| `mesas`, `zonas` | Configuración operativa propia |
| `branding { logo, color }` | Identidad propia opcional. Vacía = usa la de la empresa |
| `creado` | Fecha de alta (null en las unidades anteriores a esta versión) |

### El tipo de negocio no es un módulo

Es un **atributo**: identifica la operación y servirá para personalizar y para
reportes. **No enciende ni apaga funciones**: una arepera tiene carta, pedidos,
stock, cierre, gastos y ventas igual que un restaurante, porque lo que decide
qué funciones hay son los **módulos de la empresa**. No existe un módulo
"Bar" ni "Arepas", y otra empresa puede tener una frutería sin programar nada.

### Qué es de cada unidad

| Dato | Cómo se separa |
|---|---|
| Carta, categorías | Cada producto y categoría lleva `sucursales`: las unidades que lo usan. Lo nuevo nace en UNA |
| Stock (catálogo de inventario) | Igual. `stockActual` de un producto de una sola unidad es el stock de esa unidad |
| Menú del día | Ya era por `sucursalId` + fecha |
| Pedidos, ventas, pagos | `sucursalId` del pedido. Un pedido no puede llevar productos de carta de otra unidad |
| Gastos, base de caja, cruce de caja | `sucursalId` |
| Entradas, cierres, cruce de inventario | `sucursalId`, y sólo con productos de esa unidad |
| Mesas, zonas de domicilio | Campos de la unidad |

**Producto de inventario ≠ producto de venta.** El stock es lo que se cuenta
(*Arepa, Queso, Pollo*); la carta es lo que se vende (*Arepa de pollo*). Siguen
siendo dos catálogos distintos, unidos sólo por el enlace opcional `ventaRefIds`
(qué producto de la carta descuenta ese stock en el cruce). No hay recetas ni
consumo por ingredientes todavía.

### El catálogo real de NASCAR

No todos los locales trabajan igual, y el sistema no los obliga a hacerlo. Lo
que cambia no es el programa: es **lo que cada unidad tiene cargado**.

| Local | Carta | Inventario | Menú del día |
|---|---|---|---|
| NASCAR-Comidas | — | — | ✅ es su operación |
| Chicharrón Mental | — | — | ✅ es su operación |
| NASCAR Bar VIP | 29 productos | 29 productos (planilla del bar) | — |
| COMIC'ENDO AREPA | 58 productos | 18 insumos (planilla diaria) | — |

- **Los restaurantes sólo arman el menú del día.** No tienen carta ni
  inventario, así que el portal y la pantalla de mesa **ocultan la sección de
  carta** en vez de mostrarla vacía. Traen cinco menús del chef de ejemplo
  (tres y dos) para que se vea cómo se publica; se cambian cada mañana desde
  *Productos e inventario → Menú del día*.
- **El bar y la arepera llevan inventario**, que es justo lo que se cuenta en
  las planillas de papel que ya usan. El código de cada producto **conserva el
  número (CD) de la planilla**: `BAR-01`…`BAR-31` (el 18 y el 21 no existen en
  el papel y aquí tampoco) y `CE-01`…`CE-18`. Quien cuenta reconoce su lista.
- **La carta del bar está cargada con precio 0** a propósito: la planilla da los
  nombres, no los precios de venta. Hay que ponerlos en *Carta* antes de abrir
  la venta del bar — un producto en 0 se vende como gratis.
- Los nombres del bar se transcribieron de la planilla corrigiendo lo evidente
  (*Clud → Club*, *Wisky → Whisky*, *Tekila → Tequila*). *Traiden* se dejó tal
  cual porque no está claro qué marca es: se renombra desde el panel.

En COMIC'ENDO se ve bien la diferencia entre los dos catálogos: el inventario
cuenta *pan de hamburguesa, carne, quesos*; la carta vende *Hamburguesa doble
carne*. Sólo las gaseosas se venden tal cual, y son las únicas con
`ventaRefIds` — las demás esperan al módulo de recetas.

### La unidad activa

La unidad en la que se trabaja es parte del **contexto**, como la empresa. Se
elige una vez en la cabecera del panel (*Unidad / Local*) y todas las
secciones —pedidos, ventas, gastos, cruce, stock, entradas, cierres, carta,
menú del día, cocina, mesas— trabajan sobre ella. Ya no existe la vista
"Todas las sucursales": al cambiar de unidad no queda nada de la anterior.

- Se recuerda **por empresa** en `nascar.unidadActiva.v1`: sobrevive a recargar.
- Un usuario **asignado** a una unidad (`sucursalId` en su ficha) trabaja
  siempre en la suya y no puede cambiarla; el selector se ve, bloqueado.
- Si la recordada se desactiva, se pasa a la primera activa.

En el **portal público** el cliente elige el local (*¿Dónde quieres pedir?*) o
llega con un enlace `index.html?unidad=ID`. La carta, las categorías y el menú
del día son los de ese local, y cada pedido sale de uno solo: si cambia de local
con productos en el carrito, se le avisa y se vacía. `mesa.html?suc=ID&mesa=N`
ya era por unidad.

### Unidad inactiva

Conserva toda su información, pero **no admite operación nueva**: ni pedidos,
ni gastos, ni bases, ni cierres, ni entradas, ni menú del día. No aparece en el
selector ni en el portal. Las unidades nunca se eliminan, y siempre debe quedar
al menos una activa.

### Administración

*Administración → 🏪 Unidades / Locales* (permiso `config_sucursales`, el
mismo que ya tenía la antigua pestaña de sucursales: sólo el Admin). Tarjetas
con nombre, tipo, estado y cifras (carta, stock, pedidos), y acciones
**Consultar**, **Editar**, **Activar / Desactivar** y **Trabajar aquí**.

El alta es corta: nombre, tipo de negocio, estado, dirección, teléfono,
WhatsApp y logo. Nombre corto, ciudad, horario, mesas, colores y zonas quedan
en *Configuración avanzada*, plegada. Una unidad nueva empieza con su carta y su
stock **vacíos**: no hereda los de otra.

### Usuarios y permisos

No cambió ninguna regla de permisos. El campo `sucursalId` del usuario ya
permitía **una unidad** o **todas** (vacío); ahora se llama *Unidad asignada*.
Asignar varias unidades concretas a una persona queda para cuando haga falta.
`guardarSucursal` comprueba el permiso también en el store (doble barrera).

### Migración (versión 8)

`migrarUnidades()` corre al abrir y al restaurar un respaldo, y sólo completa lo
que falta:

1. A cada unidad sin tipo le pone `restaurante` (lo que eran) e identidad vacía.
2. Los productos de carta, categorías y productos de stock que decían
   `sucursales: []` —"en todas"— pasan a listar **las unidades que la empresa
   tenía en ese momento**. Significan lo mismo, así que nadie deja de ver nada;
   pero una unidad creada después ya no los hereda.

No borra ni reescribe nada operativo.

### Migración (versión 9)

`cargarCatalogoReal()` pone en su sitio el catálogo que trae `data.js` para
cada local. Corre una sola vez, al abrir y al restaurar un respaldo.

- Es **aditiva**: agrega el producto, la categoría o el insumo que falte, y
  **nunca** toca uno que ya exista. Un precio que el administrador haya
  cambiado se queda como está.
- La correspondencia entre `data.js` y lo guardado se hace **por nombre de
  unidad**, no por id: en una instalación que ya venía funcionando la arepera
  puede ser la unidad 7 aunque en `data.js` sea la 4 (`mapaSemillaUnidades`).
- Los cinco menús de ejemplo sólo se siembran en la unidad que **no tenga nada
  publicado hoy**.
- *Restaurar la carta (o el stock) de fábrica* de una unidad ya sólo devuelve
  **lo suyo**: restaurar la arepera no le mete los licores del bar
  (`semillaDeUnidad`).

### Migración (versión 10)

La semilla de `data.js` sólo se copia la primera vez, así que un navegador que
ya tenía la demostración guardada nunca veía los cuatro locales.
`ajustarUnidadesReales()` los crea (con un id nuevo, reconociéndolos por
nombre), desactiva las sucursales de `NASCAR.UNIDADES_RETIRADAS` y vuelve a
correr la carga del catálogo, que es aditiva.

Las dos sucursales de demostración (*NASCAR Circuito Norte* y *NASCAR Box Sur*)
quedaron **inactivas**, no borradas: conservan sus pedidos y sus cierres de
prueba, pero no aparecen en el portal ni en el selector.

---

## 🍽️ Menú del día: armado o del chef

Cada **sucursal**, en cada **fecha**, publica **una** de dos modalidades. Se
configura en *Productos e inventario → Menú del día*: se elige sucursal y fecha,
se marca el tipo y se arma el menú.

| | Menú armado | Menú del chef |
|---|---|---|
| Para qué | El cliente arma su almuerzo: una sopa, un principio, una proteína, un jugo… | Platos completos con nombre y descripción |
| Precio | Uno solo, el del menú | Cada plato el suyo |
| Se configura | **Categorías**: crear, renombrar, icono, obligatoria u opcional, activar/desactivar, ordenar, eliminar. **Opciones** de cada categoría: crear (se escribe y Enter), editar, activar/desactivar, ordenar, eliminar | **Platos**: nombre, descripción, precio, emoji, cupos, disponible, orden |
| Se guarda en | El documento del día, en `nascar.menusdia.v1` | Un registro por plato, en `nascar.platosdia.v1` |

Un menú armado nuevo arranca con **Sopa, Principio, Proteína y Jugos**
(`NASCAR.CATEGORIAS_ARMADO` en `data.js`), vacías: las opciones las pone el
restaurante. Todo se cambia desde el panel, sin tocar código.

### Empresa, sucursal y fecha

```text
nascar.menusdia.v1   { id, empresaId, sucursalId, fecha, tipo: 'armado' | 'chef',
                       armado: { nombre, descripcion, precio, disponible, vendidos,
                                 categorias: [{ id, nombre, icono, orden, obligatoria, activa,
                                                opciones: [{ id, nombre, activa, orden }] }] } }
nascar.platosdia.v1  { id, empresaId, sucursalId, fecha, nombre, desc, precio, emoji,
                       disponible, orden, cupos, vendidos }
```

- Como mucho **un documento por empresa + sucursal + fecha**: sólo una
  modalidad activa por día y sede. Nada es global; cada pantalla lee sólo lo de
  su empresa y todas las escrituras respetan la lista completa de las demás.
- **Cambiar de tipo no borra nada**: lo de la otra modalidad se conserva y
  deja de mostrarse.
- **Datos de antes**: una sucursal sin documento se comporta como siempre —
  menú del chef con los platos que ya tenía—. No hubo que migrar ni borrar.
- **Copiar el de ayer / a mañana** copia la modalidad, el menú armado y los
  platos de la sucursal elegida. Si la fecha destino ya tiene menú no se toca:
  copiar nunca pisa ni duplica.

### Qué ve el cliente

`index.html`, `mesa.html` y la toma de pedidos del mesero usan el mismo pintor,
`js/menu-dia.js`, con los colores del tema de la empresa:

- **Chef**: una tarjeta por plato disponible, en el orden elegido, con emoji,
  descripción, precio y «Disponible» o «Quedan N».
- **Armado**: una tarjeta con las categorías activas y sus opciones activas.
  Cada categoría dice cuántas opciones admite: **«Elige 1»** (botones de radio)
  o **«Elige hasta 2»** (casillas), y si es obligatoria u opcional. Al llegar al
  máximo, las opciones restantes se deshabilitan y se explica por qué. Si falta
  algo al pulsar *Agregar*, la categoría se marca en rojo y se dice cuál falta.

  **Varios menús en el mismo pedido.** Al agregar, la combinación se va al
  carrito con su propio detalle y el configurador se limpia y ofrece
  **«+ Agregar otro menú»**: la segunda persona arma la suya desde cero. Dos
  combinaciones distintas son dos líneas; la misma repetida suma cantidad.

  **Máximo por categoría.** Lo define el administrador en cada categoría
  (`maxSeleccion`), no el nombre: Sopa 1, Principio 2, Proteína 1, Jugos 1 en
  los menús nuevos. Los menús anteriores no traen el campo y valen 1, como
  funcionaban. En el detalle, dos opciones de una categoría se listan juntas:
  `Principio: Arroz, Ensalada`.

### El texto que ve el cliente

El título y el mensaje que aparecen encima del menú del día **no están escritos
en `index.html` ni en `mesa.html`**: los escribe el administrador en *Menú del
día → Lo que ve el cliente*, y ahí va también el horario («de 12:00 m. a 3:00
p.m.»), que antes estaba fijo en el HTML.

Se resuelven en tres niveles, del más concreto al más general:

1. el texto propio de **esa fecha**;
2. el texto de **la unidad** (todos los días) — lo normal, se escribe una vez;
3. el de fábrica, en `data.js` (`NASCAR.TEXTO_MENU_DIA`), único sitio donde
   vive el valor por defecto.

Cada unidad tiene el suyo: el mensaje de la arepera no aparece en el bar. El
texto de la unidad se guarda en el mismo almacén del menú, en un documento con
fecha `*`; el de una fecha, dentro del menú de ese día, y **se copia** al usar
«Copiar el de ayer». Un botón devuelve la fecha al texto de la unidad.

El panel dice en todo momento si el menú **se ve o no en el portal y por qué**:
un menú armado sólo se publica si está disponible, tiene precio y al menos una
categoría con opciones activas.

En el pedido, el menú armado es **una línea** con el nombre del menú y lo
elegido en `detalle` («Sopa: Sancocho · Proteína: Pollo…»), que se ve en el
carrito, en cocina, en el detalle, en el ticket y en el WhatsApp. Va aparte de
las notas para que una nota nunca lo borre. Igual que los platos del chef, no
descuenta inventario.

### Permisos

Todo exige el permiso `menu` (Admin y Administrador). La pestaña no se ve para
los demás perfiles, cada botón lo comprueba antes de actuar y **el store lo
vuelve a comprobar** (`exigirPermisoMenu`) si hay una sesión abierta.

---

## 🏢 Taseca y las empresas clientes

Hay **dos niveles**, y conviene no confundirlos nunca:

```text
TASECA  ·  la plataforma  (taseca.tech)
   │
   ├── SuperAdmin
   │
   └── Empresas clientes
         ├── NASCAR  ── Admin · Administrador · Caja · Mesero · Cocinero · Domiciliario
         ├── Empresa 2
         └── …
```

**Taseca es la dueña del sistema. NASCAR es uno de sus clientes**, el que se ha
usado para construir el MVP. Taseca no pertenece a NASCAR ni a ninguna otra
empresa, y ninguna empresa está por encima de otra.

| | Nivel 1 · Taseca | Nivel 2 · Empresa cliente |
|---|---|---|
| Quién | SuperAdmin | Admin, Administrador, Caja, Mesero, Cocinero, Domiciliario |
| Qué administra | Empresas, módulos, activación | Restaurante: pedidos, carta, stock, cierre, gastos, cruce, sucursales, usuarios, su configuración |
| Dónde | `taseca-admin.html` | `empleados.html` |

### Dos puertas, no una

```text
taseca-admin.html → login Taseca → panel Taseca → elegir empresa → administrarla
empleados.html        → login de la empresa → panel de la empresa
```

Son **entradas independientes**. Al panel de Taseca no se llega pasando por una
empresa, y por eso el portal de la empresa **no tiene ningún enlace** a él: se
entra por su propia dirección. Tampoco existe un botón «entrar como SuperAdmin»
dentro del panel de un restaurante.

### `scope`: cómo se distinguen los dos niveles

Cada rol y cada sesión llevan un `scope`:

```javascript
// SuperAdmin de Taseca
{ usuarioId, nombre, rol: 'superadmin', scope: 'platform',
  empresaId: null, empresaContext: null }

// Cualquier usuario de una empresa
{ usuarioId, nombre, rol: 'admin', scope: 'empresa',
  empresaId: 'empresa_nascar', sucursalId }
```

El SuperAdmin tiene **`empresaId: null`**: no pertenece a ninguna empresa, ni de
mentira. Antes se le ponía un `empresaId` inventado para esconderlo; ahora
`getUsuarios()` excluye a los de plataforma por su `scope`, que es lo que
realmente son.

Por eso **no existe «NASCAR → SuperAdmin»**: ese rol no se ofrece al crear
usuarios de una empresa, no sale en su tabla de roles, no aparece en su lista de
usuarios y no se puede fabricar desde su panel.

### `empresaContext`: administrar sin dejar de ser Taseca

Cuando el SuperAdmin entra a una empresa, **cambia el contexto, no la
identidad**:

```javascript
S.setEmpresaContexto('empresa_nascar');
// rol  = superadmin   (igual)
// scope = platform    (igual)
// empresaContext = empresa_nascar   ← lo único que cambia
```

Ese contexto vive **en la sesión** y muere con ella. No se escribe en
`localStorage`, así que **no pisa la empresa que ven los usuarios de esa
empresa**: el SuperAdmin puede mirar Empresa 2 y, cuando después entre alguien
de NASCAR, seguirá viendo NASCAR.

Mientras administra, el panel muestra arriba una barra azul:

```text
Taseca · administrando   NASCAR              ← Volver a Taseca
```

«Volver a Taseca» suelta el contexto y devuelve al panel de plataforma — no al
login de la empresa.

Los registros que el SuperAdmin cree mientras administra quedan firmados a su
nombre y con `scope: 'platform'`, y pertenecen a la empresa administrada. La
auditoría no miente sobre quién hizo qué.

### La puerta de Taseca

`taseca-admin.js` comprueba **dos** cosas antes de dibujar nada:

```javascript
function esBienvenido() {
  return A.esPlataforma() && A.puede('plataforma');
}
```

El **nivel** y el **permiso**. Hace falta el nivel porque el rol `admin` lleva el
comodín `'*'`; y hace falta el permiso porque `'*'` no alcanza a los permisos de
plataforma (ver `PERMISOS_PLATAFORMA` en `auth.js`). Con una sesión de empresa,
la dirección directa no pinta ni la tabla ni el tablero: sale «Acceso denegado».

Y no es sólo la pantalla: `store.setEmpresaContexto()` y `salirDeEmpresa()`
rechazan cualquier sesión que no sea de plataforma, igual que ya hacían
`guardarEmpresa()` y `setModulos()`.

### La marca del panel

El panel de plataforma tiene **identidad propia**, tomada de
[taseca.tech](https://taseca.tech/): dorado y cian sobre azul casi negro,
**Orbitron** para los títulos, **Inter** para el cuerpo y **JetBrains Mono** para
los datos. El logotipo es el corporativo — triángulo dorado, ojo de analítica y
barras de datos — embebido como SVG.

Nada de esto se parece a NASCAR, y es a propósito: al abrirlo tiene que quedar
claro que es el panel de **Taseca**, no el de un restaurante.

Estructura: barra lateral con la marca y el menú, y el contenido a la derecha.

```text
🏠 Dashboard   🏢 Empresas   🧩 Módulos   ⚙️ Configuración   👤 Perfil Taseca
```

| Sección | Qué muestra |
|---|---|
| **Dashboard** | Empresas (total, activas, inactivas), módulos (cuántas tienen cada uno) y actividad: altas recientes y reparto por plan |
| **Empresas** | Crear, buscar, ver, editar, activar/desactivar, administrar módulos, administrar identidad visual y entrar al contexto |
| **Módulos** | Qué vende la plataforma y qué empresa tiene cada módulo |
| **Configuración** | Con qué nace una empresa nueva y estado del almacenamiento |
| **Perfil Taseca** | La identidad con la que se está administrando |

La **actividad** sale sólo de lo que existe en los datos —la fecha de alta de
cada empresa—. La plataforma no guarda métricas de uso de los negocios, así que
no se inventan.

### Lo que el panel de Taseca NO muestra

Pedidos, ventas, gastos, stock ni cierres de ninguna empresa. Eso es operación
del negocio y se ve entrando a su contexto. Taseca administra la plataforma, no
el restaurante — y está comprobado sembrando datos en NASCAR y verificando que
ni el código de pedido, ni el monto, ni el gasto, ni la base asoman por el panel.

### Dar de alta una empresa

Taseca → Empresas → **Nueva empresa**. Un asistente de tres pasos:

| Paso | Qué se define |
|---|---|
| **1 · Información** | Nombre comercial, razón social, NIT, teléfono, WhatsApp, correo, dirección, ciudad y estado |
| **2 · Identidad visual** | Plantilla de partida, los cuatro colores, tipografía, logo, favicon, logotipo de texto y lema — con **vista previa** de cómo verá el cliente su panel |
| **3 · Módulos y acceso** | Qué módulos contrata y, opcionalmente, su administrador inicial |

Al pulsar **Crear empresa**, `store.altaEmpresa()` deja todo listo de una vez:

1. Id único y **estable** (no derivado del nombre, que puede cambiar).
2. Sus módulos, sólo los marcados.
3. Su tema.
4. Su primera sede, con la dirección y la ciudad del alta.
5. Su configuración propia, partiendo de los valores de fábrica.
6. Su administrador inicial, si se pidió.

**Sin tocar código, sin copiar carpetas, sin duplicar HTML ni CSS.**

### El tema de una empresa

`theme` es **cómo se ve**. `modulos` es **qué contrató**. Van aparte porque son
preguntas distintas:

```javascript
empresa = {
  id, nombre,
  modulos: { basico, stock, cierre },
  theme: { logo, favicon, logoTexto, logoAcento,
           primary, secondary, accent, background,
           fontFamily, iniciales, lema }
}
```

La personalización es **controlada**: los colores tienen que ser hexadecimales,
las imágenes sólo pueden venir como `data:` de imagen, y la tipografía sale de
una **lista cerrada** (`NASCAR.TIPOGRAFIAS`: Barlow, Inter, Poppins, Lora, del
sistema). No se admite CSS arbitrario por ninguna vía.

Una empresa nueva parte del **tema base de Taseca** —sobrio y neutro— y desde
ahí se personaliza. Nunca hereda el tema de otra.

### Cómo se aplica el tema

`js/tema.js` lo carga cada página de empresa (`index`, `mesa`, `cierre`,
`admin`) y escribe el tema sobre las variables que `css/styles.css` ya usaba:

```text
theme.primary     → --azul
theme.secondary   → --rojo
theme.accent      → --azul-claro
theme.background  → --negro-900
theme.fontFamily  → --f-body   (y carga la fuente si hace falta)
```

Esto es lo que hace que **una sola aplicación** sirva a muchas empresas. No hay
una copia por cliente: hay una app que carga empresa + tema + módulos +
configuración.

**Y por eso NASCAR no cambia**: su tema guarda exactamente los valores que
llevaban años escritos en el CSS (`#0b5fff`, `#e4002b`, Barlow, `NAS`+`CAR`).
Al aplicarse escribe encima lo mismo que ya había.

### Plantillas

Restaurante, Bar, Cafetería, Comercio, Servicios y Personalizado. Son **sólo un
punto de partida**: proponen tema y módulos iniciales, nada más. No hay lógica
propia de cada sector en ninguna parte, y si algún día la hubiera, se colgaría
de aquí.

### El administrador inicial

Opcional, en el paso 3. Se crea con rol `admin` de **esa** empresa, con su
`scope: 'empresa'` y su `empresaId`. Nunca es SuperAdmin —`guardarUsuario()` lo
rechazaría— y no aparece en ninguna otra empresa. El acceso se valida **antes**
de crear nada: si estuviera repetido, mejor fallar que dejar una empresa a
medio montar.

### Aislamiento

Una empresa nueva no hereda **nada**: ni pedidos, ni ventas, ni gastos, ni
stock, ni cierres, ni usuarios, ni la configuración de otra. Todo lo suyo se
crea desde cero, y lo que no se crea simplemente no existe todavía.

Y en la otra dirección: una empresa **no puede** tocar el tema de Taseca, ni su
logo, ni los módulos de nadie, ni la ficha de otra empresa. `setTheme()`,
`setModulos()`, `altaEmpresa()` y `guardarEmpresa()` exigen todas la marca de
SuperAdmin **y** que la sesión sea de plataforma.

### Los dos temas, separados

| | Dónde vive | Quién lo cambia |
|---|---|---|
| **Taseca Platform Theme** | `css/taseca.css`, variables `--platform-*` | Nadie desde la aplicación: es la marca de la plataforma |
| **Empresa Theme** | `empresa.theme`, aplicado por `js/tema.js` | El SuperAdmin, desde la ficha de esa empresa |

`taseca-admin.html` **no carga** `js/tema.js`, y las páginas de empresa **no
cargan** `css/taseca.css`. No pueden mezclarse.

### Cómo están aislados los estilos### Cómo están aislados los estilos

Dos candados, para que la marca de Taseca no pueda tocar a ninguna empresa:

1. **Archivo aparte.** `css/taseca.css` lo carga únicamente
   `taseca-admin.html`. Ninguna página de empresa (index, mesa, cierre, admin)
   lo enlaza.
2. **Todo bajo `.taseca`.** Cada regla cuelga de esa clase, que es la del
   `<body>` del panel de plataforma. Aunque alguien enlazara la hoja desde otra
   página, sin esa clase no se aplicaría nada.

`css/styles.css` —el de NASCAR— **no se tocó**. La hoja de Taseca va después y
reutiliza su estructura de componentes (`.kpi`, `.tabla`, `.caja`, `.btn`,
`.badge`, `.campo`), sólo cambiándoles la piel: no se duplican componentes.

### Variables de plataforma

Todo el color vive en un bloque. Ningún valor se repite suelto por la hoja: si
cambia la marca, se cambia ahí.

```css
.taseca {
  --platform-primary: #d4a437;      /* dorado Taseca   */
  --platform-secondary: #00e5ff;    /* cian de datos   */
  --platform-background: #05070f;
  --platform-surface: #0f1424;
  --platform-text: #e8ecf5;
  --platform-muted: #8a93a8;
  --platform-border: rgba(0, 229, 255, .18);
  /* …y las variantes soft, los estados, las tipografías y las medidas */
}
```

### Responsive

- **Escritorio** — barra lateral fija de 248 px.
- **Tablet** (≤1000 px) — la lateral pasa a una tira horizontal arriba, con el
  menú completo.
- **Móvil** (≤640 px) — el menú se reduce a iconos y la marca deja sólo el
  logotipo. Verificado a 375 px sin desbordamiento horizontal.

### Entrar a Taseca

Usuario `super`, PIN `9000`, en `taseca-admin.html`. Desde ahí: ver, crear,
editar, activar y desactivar empresas; encender y apagar sus módulos; ver sus
usuarios; y entrar a administrar cualquiera de ellas.

Una empresa nueva nace con su id estable, sólo el módulo Básico y su primera
sede ya creada, sin heredar nada de NASCAR.

### Nota sobre los nombres de las claves

Las claves de `localStorage` siguen con el prefijo `nascar.` — es de cuando el
sistema era un solo restaurante. **No es una dependencia**: los datos de la
plataforma (`empresas`, usuarios con `scope: 'platform'`) no cuelgan de ninguna
empresa cliente. Renombrarlas a `taseca.` sería una migración de las quince
claves; se puede hacer en cualquier momento, pero no cambia nada estructural y
por eso no se hizo aquí.

---

## 👥 Roles y usuarios

Cada persona entra al panel con **su usuario** y ve solamente lo suyo.
En la pantalla de entrada hay botones de acceso rápido para probar cada perfil.

| Usuario | PIN | Rol | Ve |
|---|---|---|---|
| `admin` | 2580 | 👑 Admin | Todo, incluida la configuración |
| `gerencia` | 1234 | 📋 Administrador | Toda la operación, sin configuración sensible |
| `mesero` | 1111 | 🍽️ Mesero | Las mesas y el registro del cierre |
| `cocina` | 2222 | 👨‍🍳 Cocinero | Sólo la cola de cocina |
| `domicilios` | 3333 | 🛵 Domiciliario | Sólo las entregas |
| `caja` | 4444 | 💵 Caja | Pagos, entradas de mercancía y gastos |

**El administrador NO puede**: crear usuarios, cambiar los métodos de pago,
ni tocar los datos del local o de las sucursales. Eso es sólo del Admin.

Los permisos están definidos en un solo sitio ([js/auth.js](js/auth.js)).
Esconder un botón no basta: **cada acción vuelve a comprobar el permiso**
antes de ejecutarse, así que no se puede saltar por la consola del navegador.

### 💵 La vista de Caja

Caja es el rol que **mueve el dinero del punto**. Ve exactamente tres pestañas:

| Pestaña | Qué hace |
|---|---|
| **💳 Pagos** | Ver los domicilios pendientes, abrir el comprobante adjunto, confirmar o rechazar el pago |
| **📥 Entradas** | Registrar la mercancía que llega, consultarla y corregirla |
| **💰 Gastos** | Registrar, consultar y confirmar gastos |

No puede tocar la carta, los precios, el stock maestro, los usuarios, la
configuración, los métodos de pago ni los cierres. Tampoco ve el cruce de
inventario ni los reportes de ventas.

Todo lo que hace queda firmado: **quién, qué día y a qué hora**. Un pago
confirmado guarda `confirmadoPor` y `confirmadoEn`; una entrada y un gasto
guardan el usuario, su rol y su historial.

> Anular un gasto sigue siendo de administración: caja registra y confirma,
> pero deshacer un movimiento ya registrado no es suyo.

### Las tres vistas de piso

- **🍽️ Mesero** — rejilla de mesas (verde = pedido listo para llevar). Toca una
  mesa, arma el pedido y lo envía a cocina.
- **👨‍🍳 Cocinero** — cola de pedidos, el más antiguo primero, en rojo si lleva
  más de 20 minutos. Dos botones: *Empezar a preparar* y *Marcar listo*.
- **🛵 Domiciliario** — pedidos listos y en ruta, con dirección, teléfono para
  llamar, indicaciones y **cuánto hay que cobrar**. Si el pago no está
  confirmado, avisa antes de cerrar la entrega.

### Flujo de estados

```
Mesa       Nuevo → En preparación → Listo → Entregado
Domicilio  Nuevo → En preparación → Listo → En camino → Entregado
```

Cada rol sólo puede mover el tramo que le toca: cocina no entrega, el mesero no
despacha domicilios, el domiciliario no cierra mesas.

---

## ⚙️ Configuración: ya no hay que tocar código

Todo esto se administra desde el panel:

| Pestaña | Qué se administra |
|---|---|
| **🍽 Carta** | Crear, editar y eliminar productos y categorías. Precio, orden, etiqueta, en qué sucursales se vende, agotado/oculto. |
| **📦 Stock** | El catálogo de inventario: códigos, unidades, stock actual y mínimo. Es la **línea base** con la que arranca un producto que todavía no se ha contado en ningún cierre. |
| **👥 Usuarios** | Personas, roles y sucursal asignada. |
| **⚙️ Configuración** | Nombre, NIT, **WhatsApp**, teléfono, correo, horarios, cuentas de transferencia, tiempos, hora de corte, sucursales completas y métodos de pago. |

Los cambios se ven **de inmediato** en la página pública, en el pedido a
domicilio y en las pantallas de mesa: no hay que recargar ni republicar.

`js/data.js` sigue siendo la fuente de los valores **iniciales**. La primera vez
que se abre el sistema se copian a `localStorage`; a partir de ahí manda lo que
haya configurado el administrador. El botón *Restaurar* de cada pestaña vuelve a
los valores de fábrica.

### El WhatsApp

Se configura en **⚙️ Configuración → WhatsApp del restaurante**, y cada sucursal
puede tener el suyo. Todos los botones de WhatsApp del sistema usan ese número;
no queda escrito en ningún HTML ni JS.

---

## 📎 Comprobantes de pago

Cuando el cliente elige **transferencia** puede adjuntar una foto o captura del
pago (JPG, PNG o WEBP). La imagen se reduce en el navegador antes de guardarla
—máximo 1000 px de lado, JPEG— porque en este MVP todo vive en `localStorage`,
que es pequeño. Si aun comprimida no cabe, se avisa con un mensaje claro en
lugar de fallar en silencio.

En **Pagos**, los pedidos con comprobante muestran un chip *📎 Comprobante
adjunto*. Al abrirlo se ve la imagen y ahí mismo están los botones de
**confirmar** y **rechazar**.

---

## 💰 Gastos

Todo lo que **sale** de caja: compras a proveedor, nómina, vales, servicios,
operación y otros. Panel → **💰 Gastos**.

### Qué se guarda de cada gasto

Fecha y hora del gasto, sucursal, categoría, concepto, proveedor o persona,
valor, método de pago, observaciones, y la auditoría completa: **quién lo
registró, quién lo confirmó y quién lo anuló**, cada uno con su fecha.

Cada gasto lleva un consecutivo legible por sucursal y día: `G1-260828-004`.

### Estados

```
Registrado ──▶ Confirmado
     └───────▶ Anulado
```

- Mientras está **registrado** se puede editar.
- Al **confirmar** queda cerrado: ya no se edita.
- **Anular** no borra nada. El gasto se queda con el motivo y el nombre de
  quien lo anuló, y deja de sumar en los totales. Se pide el motivo por escrito.

### Quién puede qué

| Permiso | Admin | Administrador | Caja |
|---|:--:|:--:|:--:|
| `gastos` — registrar y consultar | ✓ | ✓ | ✓ |
| `gastos_confirmar` | ✓ | ✓ | ✓ |
| `gastos_anular` | ✓ | ✓ | — |

Mesero, cocinero y domiciliario no ven el módulo.

Caja registra y confirma; **anular** sigue siendo de administración.

### Gastos y ventas van por separado

Un gasto **no** se resta de las ventas ni las modifica. La pestaña Ventas
sigue mostrando exactamente lo mismo que antes. Cruzar ingresos con egresos
es trabajo del módulo de Caja, que no existe todavía.

### Métodos de pago y categorías

Los métodos de pago son **los mismos** que administra ⚙️ Configuración: no hay
un segundo catálogo. Las categorías están en `NASCAR.CATEGORIAS_GASTO`
(`js/data.js`).

> `TIPOS_ENTRADA` también tiene «Compra a proveedor», pero es otra cosa: aquel
> es un movimiento de **inventario** (entra mercancía) y este es una salida de
> **dinero**. Una compra genera los dos, y se registran por separado.

---

## 🚦 Alertas de stock

Dentro del propio módulo 📦 Stock, no aparte. Clasifica el catálogo en tres
estados y dice qué toca pedir.

### Los tres estados

| | Regla |
|---|---|
| 🟢 **Stock normal** | Existencia por encima del mínimo |
| 🟡 **Stock bajo** | Existencia > 0 y `existencia <= stockMinimo` |
| 🔴 **Sin stock** | `existencia = 0` |

Un producto **sin mínimo configurado** nunca puede estar «bajo»: no hay contra
qué comparar. Sí puede estar «sin stock», que no depende del mínimo. Como el
catálogo de fábrica viene sin cantidades ni mínimos, una instalación nueva sale
entera en rojo — correcto, pero engañoso, así que la pantalla avisa cuántos
productos no tienen mínimo y dónde se define.

El mínimo se configura producto a producto desde **Editar**.

### Arriba: tarjetas y filtros

Cuatro tarjetas —Total, 🟢 Normal, 🟡 Bajo, 🔴 Sin stock— y unos chips que
filtran la tabla con un clic, cada uno con su contador. Hay también un chip
**Inactivos**, que sustituye al antiguo desplegable de estado.

### 🛒 Productos por pedir

Debajo de la tabla, lo que está en cero o bajo mínimo, con lo que está en cero
primero y dentro de cada grupo lo más urgente arriba:

```text
Producto | Stock actual | Stock mínimo | Diferencia | Estado
Carne    |            3 |           10 |         +7 | 🟡 Stock bajo
```

**Cantidad sugerida = `stockMinimo − existencia`**, y sólo como referencia: el
sistema **no genera órdenes de compra**. Si el producto no tiene mínimo, no se
inventa un número — dice «sin mínimo».

Dos accesos rápidos, los dos reutilizando lo que ya existe:

- **Ver producto** abre la ficha del propio módulo Stock.
- **Registrar entrada** lleva a la pestaña 📥 Entradas con el área, el producto
  y la cantidad sugerida ya puestos, para que quien recibe confirme la cantidad
  de verdad. Sólo aparece con permiso de `entradas`. **No hay un segundo
  sistema de compras.**

Ojo con una cosa: registrar la entrada **no mueve por sí sola el stock actual**.
En este sistema las entradas alimentan el campo `EN` del cruce, y el stock se
actualiza a mano o al aplicar los saldos de un cierre. La pantalla lo dice, para
que nadie espere que el semáforo cambie solo al recibir la mercancía.

### Sucursales

Aquí hay que ser preciso, porque la arquitectura no es la que parece: **el
catálogo de stock es de la EMPRESA, no de la sede**. `stockActual` es un solo
número. Lo que sí es por sucursal son los **cierres**, donde cada sede cuenta su
inventario físico.

Así que:

- **Sin sucursal elegida** — se muestra el stock del catálogo de la empresa.
- **Con una sucursal elegida** — se muestran las existencias que *esa sede*
  contó en su último cierre. Lo que esa sede nunca ha contado se marca con `◇` y
  se muestra con el stock del catálogo.

Es la misma idea de `getSaldoInicial()`, que ya alimenta el campo `IN` del
cruce. **No se creó un segundo inventario ni un campo nuevo por sucursal.**

Con esto, el ejemplo del enunciado sale solo: si Norte contó 3 y Sur contó 25,
Norte aparece 🟡 y Sur 🟢, y Carne desaparece de la lista de «por pedir» de Sur.

En la vista de empresa el stock actual se edita en la tabla, como siempre. En la
vista de una sede no: el campo del catálogo es uno solo, y dejarlo editable
mirando una sucursal daría a entender que se toca el stock de esa sede.

### Empresas

`estadoAbastecimiento()` filtra por la empresa activa. Dos empresas pueden tener
el mismo código de producto con datos distintos sin mezclarse.

### Quién ve qué

| Rol | Stock maestro | Registrar entradas |
|---|---|---|
| Admin | ✓ ver y administrar | ✓ |
| Administrador | ✓ | ✓ |
| Caja | ✗ | ✓ |
| Mesero · Cocinero · Domiciliario | ✗ | ✗ |

**No se cambió ningún permiso**: son los de siempre. Caja registra entradas pero
no entra al Stock maestro, que es lo que tenía. Si hiciera falta que consulte el
catálogo, sería añadir un permiso de sólo lectura — dilo y se hace.

---

## ❌ Anulación de facturas

Echar atrás una venta que ya se hizo, devolviendo al inventario lo que había
consumido. **Sólo el Admin.**

### Anular no es cancelar

Son dos cosas distintas y tienen permisos distintos:

| | Qué es | Quién |
|---|---|---|
| **Cancelar** (`pedidos_cancelar`) | El pedido no llegó a cumplirse. Se hace sobre un pedido en curso. | Admin, Administrador |
| **Anular** (`pedidos_anular`) | La venta se hizo y se echa atrás. Motivo obligatorio y retorno de inventario. | **Sólo Admin** |

Por eso anular tiene su propio permiso y no cuelga del de cancelar: el
Administrador cancela, pero no anula. Caja, mesero, cocinero y domiciliario, ni
lo uno ni lo otro.

### Nada se borra

La factura pasa a estado `anulado` y ahí se queda: con su historial, su pago y
sus datos. Deja de contar como venta efectiva, pero sigue estando y se puede
consultar. En el detalle sale un bloque rojo con **ANULADA**, el motivo, quién
la anuló y cuándo, y desaparecen los botones de operar: no se cambia de estado,
no se cobra, no se cancela y no se vuelve a anular.

**Una sola vez.** Un segundo intento se niega, y con él el segundo retorno de
inventario.

### Auditoría

En `pedido.anulacion` queda:

```javascript
{
  motivo,                                   // obligatorio
  usuarioId, usuarioNombre, rol,            // quién
  ts, fecha, hora,                          // cuándo
  empresaId, sucursalId, sucursalNombre,    // dónde
  total, metodoPago, estadoPagoAlAnular,    // qué se anuló
  jornadaOriginal, jornadaRetorno,          // retorno de inventario
  productos, areasRetornadas, areasDiferidas,
  cierresBloqueantes, entradas, diferido,
}
```

Y una línea en el historial del pedido, con el detalle del retorno.

### Retorno de inventario

Se usa **la misma relación que el cruce del cierre: `ventaRefIds`**. No hay
recetas ni un segundo mapeo. Un plato sin producto de inventario asociado no
consume nada, y al anular tampoco devuelve nada.

Conviene recordar cómo funciona el inventario aquí: **una venta nunca resta del
`stockActual`**. Lo que hace es sumar a la columna `Z` del cruce, que se calcula
en vivo a partir de los pedidos. Así que «devolver al inventario» es deshacer
esa `Z`, no tocar un contador.

Dónde se imputa el retorno depende de si la jornada ya se cerró, y **se decide
área por área** (puede estar cerrado comidas y no bar):

**Sin cierre de esa área** — el retorno va a la jornada original. El pedido sale
de la `Z` de ese día y el saldo calculado sube solo. No hace falta ningún
movimiento: para el inventario, esa venta nunca ocurrió.

**Con cierre completado o revisado** — el histórico **no se toca**. El pedido
sigue contando en la `Z` de aquel día, el cruce de esa fecha queda exactamente
como estaba, y la mercancía vuelve como una **entrada** de tipo
`retorno_anulacion` en la primera jornada posterior que no tenga cierre hecho.

Nunca las dos cosas a la vez: sería devolver el inventario dos veces.

La entrada lleva el código, la cantidad en positivo, el usuario, la fecha y una
observación con la factura y el motivo. Es una entrada normal del módulo de
Entradas — **no hay un segundo sistema de inventario** — sólo que la genera el
sistema, no una persona: por eso su tipo no aparece en el desplegable de
registro manual.

### Qué cambia en cada módulo

| Módulo | Efecto |
|---|---|
| **Ventas** | La anulada deja de sumar. Sigue en la tabla, marcada **Anulada** en rojo. |
| **Pagos** | Sale de la lista por cobrar. El movimiento de pago **no se borra**: la factura conserva su método y su estado de pago tal como estaban al anular. |
| **Cruce** | No cuenta como venta efectiva: no mueve el efectivo esperado ni el RC. Aparece en su propia fila, *«Facturas anuladas (no cuentan)»*, y en el CSV. |
| **Cierre** | Antes del cierre, la `Z` se corrige sola. Después, el cierre firmado queda intacto y el retorno se ve como movimiento de la jornada siguiente. |
| **Stock** | El `stockActual` no se toca, porque las ventas tampoco lo tocan. Lo que se registra es el movimiento. |
| **Gastos** | Sin cambios. |

### Doble barrera

La pantalla oculta el botón y `abrirAnularFactura()` exige el permiso antes de
abrir el diálogo. Pero `store.anularPedido()` **también** comprueba el rol de la
sesión: anular una venta y devolver mercancía es demasiado gordo para dejarlo
sólo en la pantalla. Sin sesión se permite, que es como trabajan la consola y
las semillas — mismo criterio que `setModulos()` y `guardarEmpresa()`.

---

## 📊 Cruce de información

El informe de caja de la jornada: **cómo va el dinero**. Pestaña 📊 Cruce.

Es una **capa de consulta**. Lee ventas, gastos y cierres y los pone en la
misma página; no crea pedidos, no toca gastos y no modifica cierres. Lo único
que se registra desde aquí es la **base de caja**, que no existía en ninguna
otra parte.

### No confundirlo con el cruce del Cierre

Son dos preguntas distintas y cada una tiene su pestaña:

| | Pregunta que responde |
|---|---|
| 🔄 **Cierres** | ¿Qué pasó con el **inventario físico**? `IN + EN − Z = SLDC` |
| 📊 **Cruce** | ¿Qué pasó con el **dinero** de la jornada? |

El Cruce no calcula saldos de productos y el Cierre no calcula plata. Cuando
hay un cierre de la misma jornada, el Cruce ofrece el enlace **«Ver cierre de
esta jornada»** y nada más.

### 💵 Base de caja

Con cuánto dinero físico se abrió el cajón. Va por **sucursal y jornada**, no
por área: el cajón es uno solo para comidas y bar, y ni las ventas ni los
gastos se separan por área. El área sigue siendo cosa del Cierre, que cuenta
inventario y no dinero.

Se guarda en `nascar.bases.v1`:

```javascript
{
  id, empresaId,
  sucursalId, sucursalNombre,     // copia del nombre: el histórico no miente
  fecha,                          // la JORNADA (fecha operativa)
  hora, valor, observaciones,
  usuarioId, usuarioNombre, rol,  // quién la registró
  estado: 'activa' | 'corregida',
  registrada,
  corrigeA, motivoCorreccion,     // rastro de la corrección
  efectivoContado, arqueadaPor, arqueada,   // arqueo: hueco preparado
}
```

**Una sola base por jornada.** Si ya hay una, no se pisa: hay que pedir la
corrección a propósito y escribir el motivo. La anterior queda con estado
`corregida`, con su valor y su firma intactos, y la nueva apunta a ella. Nunca
se modifica un registro histórico, igual que en pedidos, gastos y cierres. El
botón **Historial** muestra el rastro completo.

Los tres campos de arqueo están **preparados pero vacíos**: ninguna pantalla
los llena todavía. Cuando exista el conteo físico del cajón, el informe podrá
comparar esperado contra contado sin tocar nada más — y sin alterar el Cierre.

### Las fórmulas

```text
Base de caja
+ Ventas en efectivo
− Gastos en efectivo
────────────────────
= Efectivo esperado   ( = RC, reposición de caja )
```

**RC y efectivo esperado son el mismo número.** Se muestra con los dos nombres
porque es lo que la administradora busca: cuánto debería quedar en el cajón al
terminar la jornada, antes de cualquier retiro.

Las transferencias van **aparte y nunca suman al RC**: una transferencia sube
el dinero recibido, pero no el que hay en el cajón.

```text
Recibido por transferencia
− Gastos por transferencia
──────────────────────────
= Neto por transferencia
```

**RC no son las ventas totales**, y el informe lo dice con las dos cifras a la
vista.

### Vendido contra cobrado

Son dos cosas distintas y el módulo las separa:

- **Vendido** — lo que se facturó (todo lo no cancelado).
- **Cobrado** — el dinero que **ya entró** (pago confirmado).

El arqueo del cajón se hace con lo **cobrado**. Si se usara lo vendido, un
domicilio por confirmar cuadraría plata que nadie ha recibido. Lo que falta por
cobrar se muestra en su propia fila y con un aviso, para que las dos cifras
reconcilien y nada quede escondido.

Los pagos **rechazados** no cuentan ni como cobrado ni como pendiente: ese
dinero ni entró ni se espera. Los gastos **anulados** tampoco restan.

### Efectivo, transferencia y otros

La columna a la que va cada método se declara en `NASCAR.GRUPO_DE_METODO`:

```javascript
NASCAR.GRUPO_DE_METODO = {
  efectivo: 'efectivo',
  transferencia: 'transferencia',
  // datafono -> otros
};
```

Se declara en vez de adivinarse por el nombre, que el administrador puede
cambiar cuando quiera. **Lo que no esté en la lista cuenta como «otros»**, que
es lo prudente: un método de pago nuevo nunca se suma al efectivo por
accidente y nunca descuadra el arqueo.

Esto **no es un catálogo paralelo**: los métodos siguen siendo los de
⚙️ Configuración → 💳 Métodos de pago. Aquí sólo se dice a qué columna va cada
uno. La tabla «Por método de pago» lista los configurados **más** cualquiera
que aparezca en los datos aunque ya se haya desactivado: un pedido viejo pudo
pagarse con un método que después se quitó, y ese dinero existió.

### Quién lo ve

| Rol | Ver el cruce | Registrar la base |
|---|---|---|
| Admin | ✓ | ✓ |
| Administrador | ✓ | ✓ |
| Caja | ✓ | ✓ |
| Mesero | ✗ | ✗ |
| Cocinero | ✗ | ✗ |
| Domiciliario | ✗ | ✗ |

Son dos permisos (`informe` y `base_caja`) y no uno, para poder dar consulta
sin dejar tocar el dinero con el que se abre el cajón. El mesero conserva
exactamente lo que ya tenía: registrar el cierre de inventario.

Quien está atado a una sucursal ve la suya y no puede elegir otra, igual que en
el resto del panel.

### Multiempresa

Las bases llevan `empresaId` y `sucursalId`, y todas las consultas del informe
filtran por la empresa activa. La empresa no es un desplegable aquí — se
muestra a la derecha de los filtros, y cambiarla es cosa del SuperAdmin.

Sin sucursal concreta el informe suma las bases de todas las sedes de la
jornada; para registrar o corregir hay que elegir una, porque una base es de un
cajón.

---

## 📦 Cierre de caja e inventario

Reemplaza las dos plantillas de papel (Inventario Diario Comidas / Bar) y el
cruce manual que hacía la administradora en casa.

### Quién puede hacer qué

El cierre está repartido en tres permisos, porque son tareas distintas:

| Permiso | Qué permite | Quién lo tiene |
|---|---|---|
| `cierres_registrar` | Contar y guardar el inventario | Mesero, Administrador, Admin |
| `cierres` | Ver el historial, el cruce y las entradas | Administrador, Admin |
| `cierres_revisar` | Dar un cierre por revisado | Administrador, Admin |

El mesero registra pero **no ve el cruce con las ventas ni puede dar nada por
revisado**. El botón «✓ Revisar» ni siquiera se le dibuja, y si se intenta
llamar la acción por otro camino, también se bloquea.

### La noche, en el restaurante

La mesera entra al panel con su usuario y abre la pestaña **📦 Cierre**
(o abre **`cierre.html`** directo en el celular, sin pasar por el panel):

1. **Sucursal**, **fecha del cierre** y **área** (Comidas, Bar, o las dos).
2. Cuenta y registra el saldo físico de cada producto — con `−` / `+` o
   escribiendo el número.
3. **Guardar cierre**, o **Guardar borrador** si tiene que dejarlo a medias.

Tiene buscador, filtro de pendientes, contador de progreso (*18 / 22
registrados*) y un botón para poner en 0 todo lo que quede sin contar.

Un **borrador** guarda lo que lleve y queda esperando: al volver a esa fecha y
área el sistema le ofrece *Continuar este cierre* con los saldos ya puestos, y
al terminarlo pasa a *completado*. Abajo ve la lista de cierres registrados en
su sucursal, sólo para consultar.

> El formulario es el mismo en la pestaña del panel y en `cierre.html`: vive en
> `js/inventario.js` y las dos pantallas lo montan, así no hay dos versiones
> que se separen con el tiempo.

### Después, la administradora

Panel → pestaña **📦 Cierres**, con tres sub-pestañas:

| Sub-pestaña | Para qué |
|---|---|
| **Cierres registrados** | Historial completo. Ver un cierre tal como quedó, saltar a su cruce, marcarlo como *revisado*. |
| **Cruce de inventario** | La tabla `CD · PRODUCTOS · IN · EN · Z · SD · SLDC · DF` calculada sola, con resumen, veredicto, detalle de diferencias, CSV e impresión. |

Las **entradas de mercancía** (el campo `EN`) tienen su propia pestaña
**📥 Entradas**, con su propio permiso: quien recibe la mercancía no tiene por
qué ver el cruce con las ventas. Una entrada se puede corregir mientras el
cierre de esa jornada no haya sido **revisado**; después queda *Cerrada*,
porque cambiarla alteraría un cruce que alguien ya dio por bueno.

### De dónde sale cada número

| Campo | Origen |
|---|---|
| **IN** — saldo inicial | Automático, por producto: el saldo del **último cierre en que ese producto se contó**; si nunca se ha contado, el **stock actual** configurado en 📦 Stock; si tampoco hay, 0. En la tabla, un `◇` junto al IN indica que viene del stock y no de un conteo. |
| **EN** — entradas | De las compras registradas en la sub-pestaña *Entradas*. **Si no hay entradas registradas, es 0** — el sistema nunca inventa cantidades. |
| **Z** — ventas | Automático, de los pedidos que ya existen en el sistema. No se digita ni se duplica nada. |
| **SD** — saldo físico | Lo que registró la mesera. La administradora no lo vuelve a escribir. |
| **SLDC** — saldo calculado | `IN + EN − Z` |
| **DF** — diferencia | `SD − SLDC` → 🟢 OK (0) · 🟡 Sobrante (>0) · 🔴 Faltante (<0) |

### ⏰ El cierre de madrugada

Este es el punto delicado y está resuelto de forma explícita.

El sistema distingue la **jornada operativa** de la **fecha del reloj**. Un
pedido tomado a la 1:30 a.m. del 29 pertenece a la jornada del **28**, y por
eso cuenta en el cierre del 28.

- La mesera **elige** la fecha del cierre; nunca se asume la del celular.
- Si registra de madrugada, la pantalla le propone la jornada anterior y le
  explica por qué.
- Se guardan las dos fechas: `fechaCierre` (la jornada) y `fechaRegistro`
  (el instante real). En la tabla de cierres se ven ambas.

El corte está en las **6:00 a.m.** y se cambia en `js/data.js` →
`NASCAR.CONFIG.horaCorteOperativa`. Súbelo si el restaurante cierra más tarde.

> Los reportes de la pestaña **Ventas** no cambiaron: siguen usando la fecha
> calendario, que es la que la administradora ya conoce.

### Reglas que aplica el sistema

- **Sin duplicados.** `sucursal + fecha + área` es único. Si ya existe, avisa
  y ofrece consultarlo o corregirlo; nunca crea un segundo cierre en silencio.
- **Nada se mezcla.** Norte y Sur son independientes, y Comidas y Bar también.
  Los saldos iniciales tampoco se cruzan entre sucursales.
- **Saldos válidos.** Sólo enteros ≥ 0, y sólo códigos que existan en el catálogo.
- **Estados.** `borrador → completado → revisado`. Un cierre ya revisado por
  administración no lo puede tocar la mesera.
- **Auditoría.** Cada cierre guarda quién lo registró, cuándo, y el historial
  de correcciones.

### El ciclo Stock ↔ Cierre

```
📦 Stock  ──línea base (IN)──▶  Cierre del día  ──IN del día siguiente──▶  Cierre siguiente
   ▲                                  │
   └────── "Llevar saldos al stock" ───┘
```

- **Stock** es el catálogo y el estado actual del inventario.
- **Cierre** es una fotografía histórica de una fecha: una vez guardado, no
  cambia aunque después se renombre, se recodifique o se desactive el producto.
- Un producto **nuevo** en Stock aparece en el siguiente cierre con su stock
  actual como saldo inicial. A partir del primer conteo, la cadena la llevan
  los cierres entre sí.
- El botón **📦 Llevar saldos al stock** (Cierres → Cruce) actualiza el stock
  actual con lo que se contó. Es manual y con confirmación a propósito: el
  sistema no da por buenas las diferencias sin que alguien las revise.

La pantalla de conteo **no muestra** el saldo esperado: si lo mostrara, la
mesera tendería a escribir ese número en vez de contar.

### ⚠️ El catálogo de inventario es provisional

El restaurante todavía no tiene un catálogo con códigos propios, así que
`NASCAR.INVENTARIO` (en `js/data.js`) **se derivó de la carta real**: los 33
platos que ya vende, con códigos `C001–C027` (comidas) y `B001–B006` (bar).
No se inventó ningún producto.

Cuando existan los códigos reales que ya usan las meseras en el papel, se
reemplaza esa lista completa. Cada producto lleva un campo `ventaRefIds` que
lo enlaza con lo que se vende — de ahí sale Z. Un producto que no se venda
directamente lleva `ventaRefIds: []` y su Z queda en 0 hasta que exista un
módulo de recetas.

---

## Cómo funcionan los pagos

**Entregar no es cobrar.** Todo pedido —de mesa o a domicilio, con cualquier
método— queda con el pago **pendiente** y aparece en **Ventas y caja → Pagos**.
Marcarlo *Entregado* (el mesero o el domiciliario) sólo cambia lo que ve el
cliente. La cajera confirma cuando tiene el dinero y elige **con qué pagó** el
cliente; un pago confirmado ya no se cambia.

| Método | Qué pasa |
|---|---|
| **Efectivo** | Pendiente hasta que el dinero llega a caja (el domiciliario lo entrega). Si el cliente dijo con cuánto paga, el panel calcula las vueltas. |
| **Datáfono** | Pendiente hasta que caja confirma con el voucher. |
| **Transferencia** | El cliente puede dejar el número o la foto del comprobante. Caja lo verifica en el banco y confirma o rechaza. |

En mesa el pedido se toma sin método: caja lo registra al cobrar. En Ventas,
«por método de pago» sólo cuenta lo cobrado; lo demás sale como **Por cobrar en
caja**. Los pedidos **cancelados no cuentan** en las ventas.

---

## Avisos sonoros: a cada quien le suena lo suyo

El panel avisa **con sonido** de lo que le toca a cada rol, sin que nadie tenga
que estar mirando la pantalla:

| Rol | Cuándo suena |
|---|---|
| 👨‍🍳 Cocina | Entra un pedido nuevo a su unidad |
| 🍽️ Mesero | Un pedido de mesa queda **listo** para llevar |
| 🛵 Domiciliario | Un domicilio queda **listo** para salir |
| 💵 Caja | Entregaron un pedido y falta cobrarlo · el cliente reportó una transferencia |
| 👑 Administración | Cada pedido nuevo y lo que queda por cobrar |

Cada aviso tiene su propio tono, así se distingue sin mirar. Además del sonido
aparece el mensaje en pantalla y, si se autoriza, la **notificación del sistema**
(la del escritorio o la del celular) cuando la pestaña está en segundo plano.

- Se activa o silencia con el botón **🔔** de la barra superior, y se configura en
  **⚙️ Ajustes → Avisos sonoros** (con un botón para probar el sonido).
- La preferencia es **de cada equipo**: la tablet de cocina puede sonar y el
  computador de la oficina estar en silencio.
- Los navegadores no dejan sonar hasta que alguien toca la pantalla: el primer
  clic en el panel deja el sonido listo.
- Sólo avisa de la unidad que corresponde: la suya si tiene una asignada, o la que
  esté viendo si es administración.
- No gasta datos: mira los pedidos que el panel ya tiene. Con la pestaña
  escondida y los avisos activos, consulta cada 30 segundos en vez de cada 8.

---

## Qué se edita y dónde

| Qué quieres cambiar | Archivo | Dónde exactamente |
|---|---|---|
| Platos de la carta, precios base, descripciones | `js/data.js` | `NASCAR.CARTA` |
| Categorías de la carta | `js/data.js` | `NASCAR.CATEGORIAS` |
| Direcciones, teléfonos, horarios, número de mesas | `js/data.js` | `NASCAR.SUCURSALES` |
| Zonas de domicilio, costo y pedido mínimo | `js/data.js` | `NASCAR.SUCURSALES[].zonas` |
| PIN del panel, cuentas Nequi/Bancolombia, NIT, WhatsApp | `js/data.js` | `NASCAR.CONFIG` |
| Colores, tipografías, tamaños | `css/styles.css` | Sección `01. TOKENS` |
| Textos de la página (títulos, secciones) | `index.html` | Directamente en el HTML |
| Productos y códigos de inventario | `js/data.js` | `NASCAR.INVENTARIO` |
| Hora en que se considera que empieza el día | `js/data.js` | `NASCAR.CONFIG.horaCorteOperativa` |

Los precios base están en `data.js`; lo que se cambia desde el panel son
**ajustes temporales** encima de esa base. El botón *Restaurar precios originales*
los devuelve a lo que dice `data.js`.

---

## ⚠️ Lo importante que hay que saber

**1. Los datos viven en el navegador de cada equipo.**

Los pedidos, el menú del día y los ajustes se guardan en el `localStorage` del
navegador donde se abrió la página. Esto significa:

- El celular del cliente **no ve** los pedidos que están en el computador de caja.
- El computador de la sucursal Norte **no ve** los de la Sur.
- Si borras el historial/datos del navegador, **se pierde todo**.

Sirve perfecto para **demostrar el sistema, capacitar al personal y validar el
flujo con el cliente**. Para operar de verdad con las dos sucursales
sincronizadas hace falta el paso siguiente (ver abajo).

**Mientras tanto:** entra a *Ajustes → Descargar respaldo* al cierre de cada día.

**2. El PIN no es seguridad real.**

El PIN está escrito en el código que llega al navegador; cualquiera que sepa
mirar el código lo encuentra. Sirve para que nadie entre por curiosidad, no
para proteger información.

---

## El paso siguiente (cuando el restaurante lo necesite)

Para que los pedidos se sincronicen entre sucursales, celulares y caja en
tiempo real, hay que agregar un servidor. La buena noticia: **el proyecto ya
está preparado para eso**.

Toda la lectura y escritura de datos pasa por un solo archivo:
[`js/store.js`](js/store.js). Ninguna pantalla toca `localStorage`
directamente. Para migrar solo hay que reescribir las funciones de ese archivo
para que hagan `fetch()` a una API — las tres pantallas siguen funcionando sin
cambios.

Eso además traería:
- Login real con usuario y contraseña por empleado.
- Los pedidos de mesa entrando a la pantalla de cocina al instante.
- Ventas consolidadas de las dos sucursales.
- Historial que no se pierde.

### Qué falta específicamente para el módulo de inventario

El módulo ya está diseñado para migrar: los objetos son planos y
serializables, sin nada que dependa de `localStorage`.

| Pendiente | Detalle |
|---|---|
| **Catálogo real** | Reemplazar `NASCAR.INVENTARIO` en `data.js` por los códigos que ya usan las meseras en el papel. |
| **API** | Reescribir en `store.js` los métodos de inventario para que hagan `fetch()`. Las pantallas no cambian. |
| **Usuarios reales** | Los cierres ya guardan `usuarioId` (hoy `null`) y `usuarioNombre`. Falta conectarlos a un login por empleado. |
| **Recetas / consumo** | Hoy Z sólo cuenta lo que se vende como producto terminado. Para descontar insumos (una hamburguesa consume 1 pan, 1 carne) hace falta un módulo de recetas; el campo `ventaRefIds` es el punto de enganche. |
| **Módulo de compras** | Las entradas se digitan a mano. Lo natural es que lleguen desde facturas de proveedor. |
| **Bloqueo por concurrencia** | El id único evita duplicados, pero dos dispositivos sin conexión entre sí no se ven hasta que haya servidor. |

### Qué falta para el resto del sistema

| Pendiente | Detalle |
|---|---|
| **Login real** | Hoy los PIN están en el código. `auth.js` ya pregunta por permisos, nunca por el rol directamente: al conectar un backend sólo cambia de dónde sale `getUsuarioActual()`. |
| **Imágenes** | Los comprobantes van a `localStorage` comprimidos. Con servidor irían a almacenamiento de archivos y el pedido guardaría sólo la URL. |
| **Imágenes de productos** | El campo `imagen` de la carta acepta una URL, pero todavía no se muestra en la página pública. |
| **Sincronización** | Cada dispositivo tiene sus propios datos hasta que exista el servidor. |

---

## Estructura de archivos

```
Proyecto_jhon/
│
├── index.html          Página pública (landing + carta + domicilios)
├── mesa.html           Pedido desde la mesa (QR)
├── cierre.html         Registro de inventario para las meseras
├── empleados.html          Panel interno
│
├── NASCAR-movil.html   ★ Todo en un archivo, para el celular (generado)
├── build-movil.py      Regenera el archivo de arriba
│
├── INICIAR.bat         Servidor local (solo este computador)
├── INICIAR-EN-RED.bat  Servidor visible desde celulares del mismo Wi-Fi
├── README.md           Este archivo
│
├── css/
│   └── styles.css      Tema NASCAR (azul, rojo, blanco, negro)
│
└── js/
    ├── data.js         ← Valores INICIALES: carta, stock, sucursales, config, usuarios
    ├── store.js        ← Guardado y reglas de negocio (la capa a migrar)
    ├── ui.js           Utilidades: pesos, modales, carrito, WhatsApp, imágenes
    ├── auth.js         Roles, permisos y sesión
    ├── app.js          Página pública
    ├── mesa.js         Pedido de mesa (QR)
    ├── inventario.js   Cierre de caja e inventario
    ├── gestion.js      Administrar carta, stock, usuarios y configuración
    ├── operacion.js    Vistas de mesero, cocina y entregas
    ├── gastos.js       Gastos (salidas de dinero)
    └── admin.js        Armazón del panel y pedidos/pagos/ventas
```

### Dónde vive cada dato

Todo en `localStorage`, escrito **sólo** desde `store.js`:

| Clave | Contenido |
|---|---|
| `nascar.empresas.v1` | Las empresas del sistema |
| `nascar.empresaActual.v1` | En qué empresa se está trabajando |
| `nascar.config.v1` | Configuración **por empresa**: `{ empresaId: {…} }` |
| `nascar.sucursales.v1` | Unidades / locales (antes sucursales) con su tipo de negocio y zonas |
| `nascar.unidadActiva.v1` | Unidad en la que se trabaja, por empresa |
| `nascar.categorias.v1` | Categorías de la carta |
| `nascar.carta.v2` | Productos de la carta |
| `nascar.stock.v1` | Catálogo de inventario (el que usan los cierres) |
| `nascar.usuarios.v1` | Usuarios y roles |
| `nascar.comprobantes.v1` | Imágenes de los comprobantes |
| `nascar.gastos.v1` | Gastos (salidas de dinero) |
| `nascar.pedidos.v1` | Pedidos |
| `nascar.cierres.v1` | Cierres de inventario |
| `nascar.entradas.v1` | Entradas de mercancía |
| `nascar.platosdia.v1` | Menú del día: platos del chef (uno por registro) |
| `nascar.menusdia.v1` | Menú del día: modalidad por sucursal y fecha, y el menú armado |
| `nascar.consecutivo.v1` | Numeración de pedidos |
| `nascar.migracion.v1` | Marca de que ya se copiaron los valores iniciales |

**El respaldo de Ajustes incluye todas estas claves.** Un respaldo hecho con la
versión anterior se puede restaurar sin problema: lo que no traiga se completa
con los valores de `data.js`.

---

## Detalles de diseño

- **Colores:** negro `#06080C` de fondo, azul de carrera `#0B5FFF`, rojo `#E4002B`, blanco.
- **Tipografías:** Archivo Black (títulos), Barlow Condensed (etiquetas y cifras), Barlow (texto). Cargan de Google Fonts; sin internet caen a fuentes del sistema y la página se ve bien igual.
- **Motivos de carrera:** bandera a cuadros, franja tricolor, líneas de velocidad diagonales, números de sucursal grandes al fondo.
- Funciona en celular, tablet y computador.
- Respeta la preferencia de *reducir movimiento* del sistema operativo.
- Las comandas y los reportes salen bien al imprimir.

---

## Precios de referencia

La carta trae 33 platos con precios de referencia del mercado bogotano
(entradas $14.000–26.000, parrilla $32.000–78.000, tradicional $28.000–42.000,
burgers $18.000–34.000, bebidas $4.000–12.000, postres $10.000–15.000).

**Ajústalos a los precios reales antes de mostrárselo al cliente.**
