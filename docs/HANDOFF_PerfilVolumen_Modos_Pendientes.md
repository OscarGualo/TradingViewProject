# Handoff — Perfil de Volumen: modos pendientes (PDF §7)

> Documento de traspaso para implementar los **dos modos de anclaje del Perfil de
> Volumen que faltan** del PDF de especificación (sección 7). Está escrito para
> que alguien que no conoce el proyecto pueda ejecutarlo de principio a fin.
> Todo lo necesario (archivos, funciones a reusar, snippets copiables y
> verificación) está aquí.

---

## 1. Qué pide el PDF (§7) y qué falta

El PDF §7 ("Perfil de Volumen Avanzado") pide que el perfil de volumen proyecte
POC/VAH/VAL usando **tres modos de anclaje**:

| Modo §7 | Estado | Dónde |
|---|---|---|
| **Por Sesión** — segmenta por la apertura de cada sesión | ✅ **HECHO** | `Market::Indicators::SessionVolumeProfile` (SVP): un perfil por día. |
| **Por BOS / CHoCH** — el perfil ancla su **inicio y fin** en eventos BOS/CHoCH confirmados en HTF (1H, 2H, 4H, D, W) | ❌ **FALTA** | Se añade al AVP (ver §4). |
| **Contingencia (pasado lejano)** — fallback automático cuando no hay velas/eventos en el pasado reciente: ancla en inicio de sesión lejana o en evento macro HTF | ❌ **FALTA** | Se añade al AVP (ver §5). |

**Objetivo de este handoff:** implementar los dos modos que faltan **reutilizando
el motor de perfil ya existente y el patrón de anclajes automáticos del Anchored
VWAP** (que ya resuelve exactamente este problema para su propia línea).

---

## 2. Arquitectura actual (lo que ya existe y hay que reutilizar)

### 2.1 Motor de perfil (NO reescribir — reusar)
`Market/Indicators/VolumeProfile.pm`:
- **`Market::Indicators::VolumeProfile::compute_profile($candles_arrayref, %cfg)`**
  → función pura que dado un arrayref de velas devuelve:
  ```
  { rows => [ { price_lo, price_hi, up, down, total, in_va } ... ],
    poc_price, vah, val, total_vol, max_row_vol, top, bottom, n_rows }
  ```
  `%cfg` = `default_config()` = `{ rows_layout=>'rows', row_size=>1000,
  volume_mode=>'updown', value_area_pct=>70, tick_size=>0.25 }`.
- El indicador AVP mantiene una **lista de perfiles** (multipivot):
  `set_profiles(\@specs)` donde cada spec = `{ key, anchor_index, label, color, config }`.
  `calculate_all($md)` calcula cada perfil desde `anchor_index` hasta `last_index()`.
  `values()` → lista de perfiles con su `result`.

### 2.2 Overlay del AVP (reusar tal cual)
`Market/Overlays/VolumeProfile.pm` — dibuja cada perfil de la lista. No hay que
tocarlo: al agregar nuevos perfiles a la lista, se dibujan solos.

### 2.3 Wiring actual del AVP en `Market/ChartEngine.pm`
- Estado: `avp_manual => []` (lista de índices anclados por clic), `avp_overlay`.
- `_recalc_avp()` → `_rebuild_avp_profiles($vp)` + `calculate_all` (con
  `Market::ReplayProxy->new($market, $replay_cursor)` en Replay, o `$market` si no).
- `_rebuild_avp_profiles($vp)` construye los specs desde `avp_manual` y llama
  `$vp->set_profiles(\@specs)`.
- Se recalcula en: carga (`update_last`), cada paso de Replay
  (`_replay_recalc_indicators`) y cambio de TF (`set_timeframe`).
- Panel Overlays: sección **"Volume Profile"** (botones Anclar/Limpiar + modo).

### 2.4 PLANTILLA A COPIAR — anclajes automáticos del Anchored VWAP
El AVWAP **ya resuelve el problema idéntico** para su línea. Copiar su patrón:
- `%AVWAP_COLOR` (mapa tipo→color) en `ChartEngine.pm`.
- Estado `avwap_types => { session=>0, open=>0, bos=>0, choch=>0, poc=>0, swing=>0 }`.
- `_rebuild_avwap_series($v)`: tiene un array `@auto` de resolvers:
  ```perl
  my @auto = (
      [ 'session', 'Sesión',   sub { $self->_session_anchor($limit) } ],
      [ 'bos',     'BOS',      sub { $self->_event_anchor($limit, 'BOS') } ],
      [ 'choch',   'CHoCH',    sub { $self->_event_anchor($limit, 'CHoCH') } ],
      ...
  );
  ```
- **`_event_anchor($limit, $type)`** (¡el resolver que necesitamos!):
  ```perl
  sub _event_anchor {
      my ($self, $limit, $type) = @_;
      my $smc = $self->{indicators}->get_indicator('SMC_Structures');
      return undef unless defined $smc && $smc->can('values_events');
      my $best;
      for my $ev (@{ $smc->values_events() }) {
          next unless $ev->{type} eq $type;      # 'BOS' | 'CHoCH'
          next if $ev->{index} > $limit;
          $best = $ev->{index} if !defined $best || $ev->{index} > $best;
      }
      return $best;
  }
  ```
- `_session_anchor($limit)` → índice del primer candle del día que contiene a `$limit`.
- `_replay_limit()` → devuelve el cursor en Replay (o `last_index()` fuera de él).

### 2.5 Fuente de eventos BOS/CHoCH
`Market::Indicators::SMC_Structures::values_events()` →
`[ { index, type=>'BOS'|'CHoCH', direction=>'up'|'down', scope=>'internal'|'external', level_price, level_index } ]`.
- **scope `'external'`** = estructura mayor (`major_depth=50`) ≈ eventos "HTF/relevantes".
  Para "eventos en HTF (1H/2H/4H/D/W)" del PDF, usar `scope eq 'external'` es la
  aproximación pragmática y suficiente (misma que ya usan los Order Blocks swing).
  *(Opción fiel avanzada: instanciar `SMC_Structures` sobre un proxy de cada TF
  superior y unir sus eventos — ver §6.)*

---

## 3. Concepto de los dos modos

- **Modo Por BOS/CHoCH**: el perfil se construye **entre dos eventos consecutivos**
  (inicio = evento_i, fin = evento_{i+1}); el perfil "vivo" va del último evento
  hasta el cursor. Es decir, cada tramo estructural entre rupturas tiene su propio
  POC/VAH/VAL. (PDF: "tomando como anclajes de inicio y fin los eventos confirmados".)
- **Modo Contingencia**: si NO hay eventos BOS/CHoCH recientes (p.ej. el usuario
  navegó a una zona sin estructura confirmada, o al arranque del histórico), anclar
  automáticamente en el **inicio de la sesión lejana** (primer candle del primer día
  disponible ≤ cursor) o en el **evento macro HTF (D/W)** más reciente.

---

## 4. Implementar **Modo Por BOS/CHoCH** (pasos)

Todo en `Market/ChartEngine.pm`. Reusa `compute_profile` vía el indicador AVP.

### 4.1 Estado nuevo
Junto a `avp_manual` (en `sub new`):
```perl
avp_types => { bos => 0, choch => 0 },   # modos de anclaje automático del AVP
```

### 4.2 Colores (junto a los del AVP o reusar %AVWAP_COLOR)
```perl
my %AVP_AUTO_COLOR = ( bos => '#089981', choch => '#f23645' );
```

### 4.3 Resolver: tramos entre eventos consecutivos
Añadir un método que devuelva **pares [inicio, fin]** de eventos externos de un tipo,
acotados al cursor. `fin` del último tramo = cursor.
```perl
# Tramos [start_idx, end_idx] entre eventos BOS/CHoCH (scope external) <= limit.
# El último tramo termina en el cursor (perfil "en desarrollo").
sub _avp_event_segments {
    my ($self, $limit, $type, $max_segments) = @_;
    $max_segments //= 3;
    my $smc = $self->{indicators}->get_indicator('SMC_Structures');
    return () unless defined $smc && $smc->can('values_events');
    my @idx = map { $_->{index} }
              grep { $_->{type} eq $type && $_->{scope} eq 'external' && $_->{index} <= $limit }
              @{ $smc->values_events() };
    return () unless @idx;
    @idx = sort { $a <=> $b } @idx;
    my @seg;
    for my $i (0 .. $#idx) {
        my $start = $idx[$i];
        my $end   = ($i < $#idx) ? $idx[$i + 1] : $limit;   # último = hasta el cursor
        next if $end <= $start;
        push @seg, [ $start, $end ];
    }
    # sólo los N tramos más recientes (evita saturar)
    @seg = @seg[ -$max_segments .. -1 ] if @seg > $max_segments;
    return @seg;
}
```

### 4.4 Añadir los perfiles a la lista en `_rebuild_avp_profiles`
Localizar `_rebuild_avp_profiles($vp)` y, tras construir los specs manuales,
agregar los automáticos. **IMPORTANTE**: `compute_profile`/el AVP anclan de
`anchor_index` a `last_index()`. Para respetar el **fin** del tramo hace falta
acotar el rango. Dos caminos:

- **Camino A (mínimo cambio):** anclar sólo al ÚLTIMO evento (inicio = último BOS/CHoCH,
  fin = cursor). Esto reusa el AVP tal cual (spec con `anchor_index`), sin tocar el
  indicador. Cumple el espíritu "anclado en el evento" del modo.
  ```perl
  my $t = $self->{avp_types};
  for my $type_key (qw(bos choch)) {
      next unless $t->{$type_key};
      my $TYPE = uc $type_key;                       # 'BOS' | 'CHOCH'->'CHoCH'
      $TYPE = 'CHoCH' if $type_key eq 'choch';
      my $a = $self->_event_anchor($limit, $TYPE);   # reusa el resolver del AVWAP
      next unless defined $a && $a <= $limit;
      push @specs, {
          key          => "avp_$type_key",
          anchor_index => $a,
          label        => $TYPE,
          color        => $AVP_AUTO_COLOR{$type_key},
      };
  }
  ```
- **Camino B (fiel: perfil ENTRE eventos):** para que cada perfil termine en el
  evento siguiente (no en el cursor), el indicador AVP debe soportar `end_index`
  por spec. Añadir a `VolumeProfile.pm`:
  - en `set_profiles`, aceptar `end_index` opcional en cada spec;
  - en `calculate_all`, si `end_index` definido, usar `min(end_index, last_index())`
    como fin del rango en vez de `last_index()`.
  Luego generar un spec por cada `[start,end]` de `_avp_event_segments`.
  ```perl
  for my $type_key (qw(bos choch)) {
      next unless $self->{avp_types}{$type_key};
      my $TYPE = $type_key eq 'choch' ? 'CHoCH' : 'BOS';
      my @seg  = $self->_avp_event_segments($limit, $TYPE, 3);
      my $i = 0;
      for my $s (@seg) {
          push @specs, {
              key          => "avp_${type_key}_$i",
              anchor_index => $s->[0],
              end_index    => $s->[1],           # requiere soporte en VolumeProfile
              label        => $TYPE,
              color        => $AVP_AUTO_COLOR{$type_key},
          };
          $i++;
      }
  }
  ```
  > Recomendado: empezar por **Camino A** (funciona sin tocar el indicador) y, si se
  > quiere fidelidad total al "inicio y fin", pasar a **Camino B**.

### 4.5 Toggles en el panel
En la sección "Volume Profile" del panel (`sub run`, donde está `$avp_box`),
añadir dos checkbuttons que hagan:
```perl
$self->{avp_types}{'bos'} = $on; $self->_recalc_avp(); $self->draw();
```
(mismo patrón que los toggles del AVWAP `%vwap_auto`).

### 4.6 Recalcular
`avp_types` ya se resuelve dentro de `_rebuild_avp_profiles`, que es llamado por
`_recalc_avp()` en TODOS los paths (carga, Replay, cambio de TF). No hay que tocar
`set_timeframe` ni `_replay_recalc_indicators`. **Replay-safe** porque `$limit`
= `_replay_limit()` (cursor) y `calculate_all` corre sobre `ReplayProxy`.

---

## 5. Implementar **Modo Contingencia (pasado lejano)**

Fallback automático. En `_rebuild_avp_profiles`, tras intentar los anclajes
BOS/CHoCH, si NO se generó ningún perfil automático (no hay eventos recientes),
anclar por contingencia:
```perl
# Contingencia: sin eventos estructurales recientes -> anclar en sesión lejana
# o en el evento macro HTF (D/W) más reciente.
if ($any_auto_enabled && !$generated_any_auto) {
    my $a = $self->_event_anchor($limit, 'BOS');          # ¿algún BOS histórico?
    $a = $self->_session_anchor_far($limit) unless defined $a;  # inicio sesión lejana
    if (defined $a) {
        push @specs, { key => 'avp_contingency', anchor_index => $a,
                       label => 'Contingencia', color => '#9c27b0' };
    }
}
```
Donde `_session_anchor_far` ancla en el primer candle del primer día disponible
≤ cursor (o el más lejano dentro de un lookback grande):
```perl
sub _session_anchor_far {
    my ($self, $limit) = @_;
    return undef if $limit < 0;
    # primer candle del PRIMER día disponible <= limit (sesión lejana)
    my $c0 = $self->{market}->get_candle(0);
    return defined $c0 ? 0 : undef;   # inicio del histórico
    # (variante: primer candle del día de hace N días — usar epoch/índice.)
}
```
Criterio de activación (según PDF): "cuando no existan datos o velas en el pasado
reciente". Traducción práctica: si `_event_anchor(cursor)` es `undef` o está a más
de `X` velas del cursor, activar contingencia.

---

## 6. (Opcional) Eventos BOS/CHoCH realmente en HTF (1H/2H/4H/D/W)

`scope eq 'external'` del SMC del TF activo es la aproximación pragmática. Para
eventos calculados **específicamente** en cada HTF:
```perl
use Market::Indicators::SMC_Structures;
my $htf_smc = Market::Indicators::SMC_Structures->new(depth => 5, major_depth => 50);
# Proxy que expone el TF superior como si fuera el activo, acotado al cursor:
$htf_smc->calculate_all($proxy_en_TF_superior);
my @htf_events = @{ $htf_smc->values_events() };   # con epoch, reproyectar a índices del TF activo
```
Reproyectar cada evento del HTF a un índice del TF activo con
`MarketData::index_at_epoch($event_epoch)`. Es más trabajo; sólo hacerlo si se
exige fidelidad literal a "1H/2H/4H/D/W".

---

## 7. Verificación (headless + real)

Crear un script tipo `verify_avp_modes.pl` (mirar los `verify_*.pl` existentes):
1. `perl -I. -c` de los archivos tocados.
2. **Headless** con los 4 CSV reales:
   - `_event_anchor($limit,'BOS')` / `_avp_event_segments` devuelven eventos
     `scope=external` con `index <= limit` (varios `$limit`, incluido un cursor de Replay).
   - Construir el AVP con esos anchors y verificar **conservación de volumen**
     (`Σ filas == Σ volumen del rango`) — igual que en `verify_avp.pl`.
   - **Replay sin fuga**: a un cursor C, ningún anchor ni punto del perfil supera C.
   - **Contingencia**: forzar un cursor en una zona sin eventos y comprobar que se
     genera el perfil de contingencia anclado en la sesión lejana.
3. **Arranque real** `perl market.pl`: panel Overlays → Volume Profile → activar
   "BOS"/"CHoCH" → aparecen perfiles anclados en los eventos; en Replay se re-anclan
   al avanzar; cambiar TF re-resuelve. Sin errores en consola (excluir el warning
   pre-existente de `_round_to_tick`).

---

## 8. Checklist de entrega
- [ ] `avp_types` en estado + toggles en panel "Volume Profile".
- [ ] `_avp_event_segments` (o Camino A con `_event_anchor`) implementado.
- [ ] Perfiles BOS/CHoCH añadidos en `_rebuild_avp_profiles`.
- [ ] Modo contingencia con criterio de activación + `_session_anchor_far`.
- [ ] (Opcional B) `end_index` por spec en `VolumeProfile.pm`.
- [ ] Verificación headless (conservación + replay + contingencia) OK.
- [ ] Arranque real OK, sin errores.

## 9. Archivos involucrados
- `Market/ChartEngine.pm` — estado `avp_types`, resolvers, `_rebuild_avp_profiles`,
  toggles del panel. (Reusa `_event_anchor`, `_session_anchor`, `_replay_limit`.)
- `Market/Indicators/VolumeProfile.pm` — SÓLO si se hace el Camino B (`end_index`).
- `Market/Overlays/VolumeProfile.pm` — sin cambios (dibuja lo que haya en la lista).
- Referencia de patrón: buscar `_rebuild_avwap_series`, `avwap_types`,
  `_event_anchor`, `%AVWAP_COLOR` en `ChartEngine.pm`.
