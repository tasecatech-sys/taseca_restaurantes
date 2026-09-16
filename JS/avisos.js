/* ==========================================================================
   NASCAR · avisos.js
   Avisos sonoros del panel: que a cada quien le suene LO SUYO.

   QUÉ AVISA A CADA ROL
     👨‍🍳 Cocina         → entra un pedido nuevo a su unidad
     🍽️ Mesero          → un pedido de mesa queda LISTO para llevar
     🛵 Domiciliario     → un domicilio queda LISTO para salir
     💵 Caja             → entregaron un pedido y falta cobrarlo, o el
                           cliente reportó una transferencia
     👑 Administración   → cada pedido nuevo, y lo que queda por cobrar

   CÓMO FUNCIONA
     No consume red: mira los pedidos que el panel YA tiene en memoria
     (NASCAR.Store) cada pocos segundos y avisa de lo que cambió. En modo
     base de datos esos pedidos los refresca remoto.js; en modo local, el
     propio navegador.

     El sonido se genera con el navegador (Web Audio), sin archivos. Los
     navegadores no dejan sonar hasta que la persona toca la pantalla: por
     eso el primer clic en el panel "despierta" el audio.

     La preferencia (sonido sí/no, aviso del sistema sí/no) se guarda en
     ESTE navegador: es de cada equipo, no del negocio.
   ========================================================================== */

window.NASCAR = window.NASCAR || {};

NASCAR.Avisos = (function () {
  'use strict';

  const S = NASCAR.Store;
  const A = NASCAR.Auth;
  const U = NASCAR.UI;

  const CLAVE = 'nascar.avisos.v1';
  const CADA_MS = 4000;

  /* Qué avisa cada evento, a quién y cómo suena.
     `permiso` = quién lo oye · `tonos` = [Hz, …] · `ms` = duración de cada tono */
  const EVENTOS = {
    nuevo: {
      permisos: ['pedidos_cocina', 'pedidos_gestionar'],
      titulo: 'Pedido nuevo',
      tonos: [880, 1175],
      ms: 130,
      texto: (p) => (p.tipo === 'mesa' ? 'Mesa ' + p.mesa : 'Domicilio') + ' · ' + U.money(p.total),
    },
    listoMesa: {
      permisos: ['pedidos_listos', 'pedidos_mesa', 'pedidos_gestionar'],
      titulo: 'Listo para llevar a la mesa',
      tonos: [660, 880, 1320],
      ms: 120,
      texto: (p) => 'Mesa ' + p.mesa + ' · ' + p.items.length + ' producto' + (p.items.length === 1 ? '' : 's'),
    },
    listoDomicilio: {
      permisos: ['pedidos_domicilio', 'pedidos_gestionar'],
      titulo: 'Domicilio listo para salir',
      tonos: [784, 988, 1319],
      ms: 120,
      texto: (p) => (p.cliente.direccion || p.cliente.nombre || 'Domicilio') + ' · ' + U.money(p.total),
    },
    porCobrar: {
      permisos: ['pagos'],
      titulo: 'Entregado sin cobrar',
      tonos: [523, 392],
      ms: 160,
      texto: (p) => 'Confirma el pago en Ventas y caja · ' + U.money(p.total),
    },
    pagoReportado: {
      permisos: ['pagos'],
      titulo: 'El cliente reportó su pago',
      tonos: [700, 700],
      ms: 110,
      texto: (p) => 'Verifícalo antes de confirmar · ' + U.money(p.total),
    },
  };

  /* El orden importa: un Admin tiene casi todos los permisos y sólo debe
     sonarle UNA vez por cada cosa que pasa. */
  const ORDEN = ['nuevo', 'listoMesa', 'listoDomicilio', 'porCobrar', 'pagoReportado'];

  let vistos = null;     // id del pedido -> "estado|estadoPago"
  let timer = null;
  let audio = null;      // AudioContext, creado al primer sonido
  let despierto = false; // el navegador ya dejó sonar

  /* =====================================================================
     PREFERENCIA DE ESTE NAVEGADOR
     ===================================================================== */
  function prefs() {
    try {
      return Object.assign({ sonido: true, sistema: false }, JSON.parse(localStorage.getItem(CLAVE) || '{}'));
    } catch (e) {
      return { sonido: true, sistema: false };
    }
  }

  function guardarPrefs(cambios) {
    const p = Object.assign(prefs(), cambios || {});
    try {
      localStorage.setItem(CLAVE, JSON.stringify(p));
    } catch (e) {
      /* navegador sin almacenamiento: la preferencia dura lo que la pestaña */
    }
    pintarBoton();
    return p;
  }

  /* =====================================================================
     SONIDO
     ===================================================================== */
  function despertarAudio() {
    if (!audio) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return false;
      try {
        audio = new AC();
      } catch (e) {
        return false;
      }
    }
    if (audio.state === 'suspended') audio.resume().catch(() => {});
    despierto = audio.state === 'running';
    return despierto;
  }

  function sonar(tonos, ms) {
    if (!prefs().sonido || !despertarAudio()) return;
    const inicio = audio.currentTime + 0.02;
    tonos.forEach(function (hz, i) {
      const osc = audio.createOscillator();
      const vol = audio.createGain();
      const t0 = inicio + (i * ms) / 1000;
      const t1 = t0 + ms / 1000;
      osc.type = 'sine';
      osc.frequency.setValueAtTime(hz, t0);
      // Entra y sale suave: un pitido seco suena a error
      vol.gain.setValueAtTime(0.0001, t0);
      vol.gain.exponentialRampToValueAtTime(0.28, t0 + 0.02);
      vol.gain.exponentialRampToValueAtTime(0.0001, t1);
      osc.connect(vol).connect(audio.destination);
      osc.start(t0);
      osc.stop(t1 + 0.02);
    });
  }

  /* =====================================================================
     AVISO DEL SISTEMA (la notificación del escritorio o del celular)
     ===================================================================== */
  function pedirPermisoSistema() {
    if (!('Notification' in window)) return Promise.resolve('no-soportado');
    if (Notification.permission !== 'default') return Promise.resolve(Notification.permission);
    return Notification.requestPermission().catch(() => 'denied');
  }

  function avisoDelSistema(titulo, cuerpo) {
    if (!prefs().sistema || !('Notification' in window) || Notification.permission !== 'granted') return;
    // Si la pestaña está a la vista, el toast ya se ve: no hace falta molestar
    if (!document.hidden) return;
    try {
      new Notification(titulo, { body: cuerpo, tag: 'nascar-aviso', renotify: false });
    } catch (e) {
      /* algunos navegadores sólo permiten notificaciones desde un service worker */
    }
  }

  /* =====================================================================
     QUÉ PASÓ CON CADA PEDIDO
     ===================================================================== */
  function firma(p) {
    return p.estado + '|' + p.estadoPago;
  }

  /* Sólo los pedidos que le tocan a quien está conectado:
       · con unidad asignada  → la suya y nada más
       · administración       → la unidad que está mirando en el panel
       · resto sin unidad (un domiciliario que cubre varios locales) → todas
         las que le llegan, que ya vienen filtradas por su empresa. */
  function esMio(p) {
    const suya = A.sucursalDelUsuario();
    if (suya) return Number(p.sucursalId) === Number(suya);
    if (!A.puede('pedidos_gestionar')) return true;
    const activa = S.unidadActivaId ? S.unidadActivaId() : null;
    return !activa || Number(p.sucursalId) === Number(activa);
  }

  function reciente(p) {
    const ts = Date.parse(p.actualizado || p.creado);
    return !isFinite(ts) || Date.now() - ts < 15 * 60 * 1000;
  }

  function evtListo(p) {
    return p.tipo === 'mesa' ? 'listoMesa' : 'listoDomicilio';
  }

  function eventoDe(p, antes) {
    if (p.estado === 'cancelado' || p.estado === 'anulado') return null;

    /* Primera vez que se ve este pedido (lo acaba de traer el refresco).
       Puede llegar ya preparado si se hizo todo entre dos refrescos, así
       que también cuenta como "listo". Lo viejo no despierta a nadie. */
    if (!antes) {
      if (!reciente(p)) return null;
      if (p.estado === 'nuevo') return 'nuevo';
      if (p.estado === 'listo') return evtListo(p);
      return null;
    }

    const estadoAntes = antes.split('|')[0];
    const pagoAntes = antes.split('|')[1];

    if (p.estado !== estadoAntes) {
      if (p.estado === 'listo') return evtListo(p);
      if (p.estado === 'entregado' && p.estadoPago !== 'confirmado') return 'porCobrar';
      return null;
    }
    if (p.estadoPago !== pagoAntes && p.estadoPago === 'reportado') return 'pagoReportado';
    return null;
  }

  function loOye(evento) {
    return EVENTOS[evento].permisos.some((permiso) => A.puede(permiso));
  }

  /* =====================================================================
     RONDA
     ===================================================================== */
  function revisar() {
    if (!S.estaAutenticado || !S.estaAutenticado()) return;

    let lista;
    try {
      lista = S.getPedidos({});
    } catch (e) {
      return; // el panel todavía no tiene datos
    }

    // Primera vuelta: se toma la foto y no suena nada de lo que ya estaba
    if (!vistos) {
      vistos = {};
      lista.forEach((p) => (vistos[p.id] = firma(p)));
      return;
    }

    const nuevos = {};
    const pendientes = [];

    lista.forEach(function (p) {
      const antes = vistos[p.id];
      nuevos[p.id] = firma(p);
      if (antes === nuevos[p.id]) return;
      if (!esMio(p)) return;

      const evento = eventoDe(p, antes);
      if (evento && loOye(evento)) pendientes.push({ evento: evento, pedido: p });
    });

    // Los pedidos que ya no están en memoria (jornadas viejas) dejan de seguirse
    vistos = nuevos;
    if (!pendientes.length) return;

    /* Varios cambios a la vez (por ejemplo al volver a la pestaña): suena
       UNA sola vez, con el aviso más importante, y el resto se cuenta. */
    pendientes.sort((a, b) => ORDEN.indexOf(a.evento) - ORDEN.indexOf(b.evento));
    const principal = pendientes[0];
    const def = EVENTOS[principal.evento];
    const otros = pendientes.length - 1;

    const texto =
      principal.pedido.codigo + ' · ' + def.texto(principal.pedido) +
      (otros ? ' · y ' + otros + ' aviso' + (otros === 1 ? '' : 's') + ' más' : '');

    sonar(def.tonos, def.ms);
    if (U && U.toast) U.toast(def.titulo + ' — ' + texto, 'info');
    avisoDelSistema(def.titulo, texto);
  }

  /* =====================================================================
     BOTÓN DE LA BARRA
     ===================================================================== */
  function pintarBoton() {
    const b = document.getElementById('btnAvisos');
    if (!b) return;
    const p = prefs();
    b.textContent = p.sonido ? '🔔' : '🔕';
    b.title = p.sonido
      ? 'Avisos sonoros activados' + (p.sistema ? ' (con aviso del sistema)' : '') + '. Clic para silenciar.'
      : 'Avisos silenciados. Clic para activarlos.';
    b.setAttribute('aria-pressed', p.sonido ? 'true' : 'false');
    b.classList.toggle('is-apagado', !p.sonido);
  }

  function alternar() {
    const p = prefs();
    if (p.sonido) {
      guardarPrefs({ sonido: false });
      if (U && U.toast) U.toast('Avisos silenciados en este equipo.', 'info');
      return;
    }
    guardarPrefs({ sonido: true });
    despertarAudio();
    probar();
    pedirPermisoSistema().then(function (estado) {
      guardarPrefs({ sistema: estado === 'granted' });
      if (U && U.toast) {
        U.toast(
          estado === 'granted'
            ? 'Avisos activados. También sonarán con la pestaña en segundo plano.'
            : 'Avisos activados en esta pestaña.',
          'info'
        );
      }
    });
  }

  function probar() {
    sonar(EVENTOS.nuevo.tonos, EVENTOS.nuevo.ms);
  }

  /* =====================================================================
     ARRANQUE
     ===================================================================== */
  function iniciar() {
    if (timer) return;
    pintarBoton();

    const b = document.getElementById('btnAvisos');
    if (b) b.addEventListener('click', alternar);

    /* El navegador sólo deja sonar después de que la persona toque algo:
       el primer clic en cualquier parte del panel despierta el audio. */
    document.addEventListener('click', function despertar() {
      despertarAudio();
      if (despierto) document.removeEventListener('click', despertar);
    });

    revisar();                       // foto inicial, sin sonido
    timer = setInterval(revisar, CADA_MS);
  }

  return {
    iniciar: iniciar,
    probar: probar,
    prefs: prefs,
    guardarPrefs: guardarPrefs,
    pedirPermisoSistema: pedirPermisoSistema,
    // Para la pantalla de Ajustes
    EVENTOS: EVENTOS,
  };
})();
