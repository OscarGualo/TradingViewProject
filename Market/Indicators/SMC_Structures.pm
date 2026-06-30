package Market::Indicators::SMC_Structures;
use strict;
use warnings;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::SMC_Structures
#
# Cálculo algorítmico subyacente de estructuras de Smart Money Concepts.
# Según la arquitectura del PDF (Tabla 1):
#   "Cálculo algorítmico subyacente de BOS, CHoCH, FVG, niveles de Fibonacci
#    y su integración nativa con los vectores de liquidez."
#
# PUNTO 3.1 — Swing Points y máquina de estados HH/HL/LH/LL
# PUNTO 3.2 — BOS y CHoCH internal/external
# PUNTO 3.3 — FVG (Fair Value Gap) con mitigación y desvanecimiento
#
# Pendiente para 3.4 (otro archivo, Liquidity.pm, usará helpers de este):
#   - Fibonacci Retracement (se añade aquí mismo cuando llegue su turno)
#
# Sigue el mismo contrato que Market::Indicators::ATR para integrarse
# sin cambios en IndicatorManager:
#   new(%args) -> objeto
#   reset()    -> limpia el estado interno
#   values()   -> devuelve los datos calculados (arrayref)
#   calculate_all($market_data) -> recalcula todo desde cero
#
# Compatible con Market::ReplayProxy: calculate_all() solo usa
# $market_data->get_slice(0, $market_data->last_index()), exactamente
# igual que ATR.pm. Cuando se le pase un ReplayProxy en lugar del
# MarketData real, automáticamente respeta el límite del cursor de Replay
# sin ningún cambio adicional en este archivo.
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %args) = @_;
    my $self = {
        # Profundidad de vecindad para detectar un swing.
        # PDF 4.1: "valor inicial recomendado k = 3"
        depth => $args{depth} || 3,

        # Resultado del último calculate_all():
        #   swings: arrayref de hashrefs { index, price, type, label }
        #     type  => 'high' | 'low'           (Swing High o Swing Low)
        #     label => 'HH' | 'HL' | 'LH' | 'LL' (clasificación de tendencia)
        swings => [],

        # Índice de vela -> swing en ese índice (acceso O(1) para overlays)
        # Solo las velas que SON un swing point tienen entrada aquí.
        swings_by_index => {},

        # ── 3.2: eventos BOS y CHoCH ─────────────────────────────────────────
        # events: arrayref cronológico de hashrefs:
        #   { index, type, direction, scope, level_price, level_index }
        #     type      => 'BOS' | 'CHoCH'
        #     direction => 'up' | 'down'        (dirección de la ruptura)
        #     scope     => 'internal' | 'external'
        #     level_price => precio del swing roto
        #     level_index => índice de vela del swing roto
        events => [],

        # Índice de vela -> evento(s) confirmados en esa vela (puede haber
        # como máximo un BOS y un CHoCH en la misma vela, raro pero posible).
        events_by_index => {},

        # ── 3.3: Fair Value Gaps ──────────────────────────────────────────────
        # fvgs: arrayref cronológico de hashrefs:
        #   { index, direction, top, bottom, mitigated_at }
        #     index        => índice de la vela "central" (i) que formó el gap
        #     direction    => 'up' (alcista) | 'down' (bajista)
        #     top, bottom  => límites de precio del gap (top siempre > bottom)
        #     mitigated_at => índice de la vela donde el precio volvió a entrar
        #                     al rango del gap, o undef si sigue activo
        fvgs => [],

        # Índice de la vela de FORMACIÓN -> fvg (acceso O(1) para overlays)
        fvgs_by_index => {},
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{swings} = [];
    $self->{swings_by_index} = {};
    $self->{events} = [];
    $self->{events_by_index} = {};
    $self->{fvgs} = [];
    $self->{fvgs_by_index} = {};
}

# values() devuelve el arrayref de swings — es el contrato esperado por
# IndicatorManager::get('SMC_Structures') y slice_array().
sub values {
    my ($self) = @_;
    return $self->{swings};
}

# Acceso directo: swing en un índice de vela específico, o undef si esa
# vela no es un swing point. Usado por el Overlay para no iterar todo el
# array de swings en cada redibujo.
sub swing_at {
    my ($self, $index) = @_;
    return $self->{swings_by_index}{$index};
}

# Devuelve el evento (BOS/CHoCH) confirmado en una vela específica, o undef.
# Si hay más de uno en la misma vela (raro), devuelve un arrayref.
sub events_at {
    my ($self, $index) = @_;
    return $self->{events_by_index}{$index};
}

# values_events() devuelve el arrayref cronológico de todos los eventos.
sub values_events {
    my ($self) = @_;
    return $self->{events};
}

# Devuelve el FVG formado en una vela específica (índice de formación), o undef.
sub fvg_at {
    my ($self, $index) = @_;
    return $self->{fvgs_by_index}{$index};
}

# values_fvgs() devuelve el arrayref cronológico de todos los FVG.
sub values_fvgs {
    my ($self) = @_;
    return $self->{fvgs};
}

# ─────────────────────────────────────────────────────────────────────────────
# calculate_all — recalcula todos los Swing Points y su clasificación
# HH/HL/LH/LL desde cero, sobre los datos visibles en $market_data.
#
# IMPORTANTE: usa get_slice(0, last_index()) igual que ATR.pm. Esto es lo
# que permite que el ReplayProxy (Fase 2) limite automáticamente los datos
# sin que este archivo necesite saber nada sobre el modo Replay.
# ─────────────────────────────────────────────────────────────────────────────
sub calculate_all {
    my ($self, $market_data) = @_;
    $self->reset();

    my $data = $market_data->get_slice(0, $market_data->last_index());
    my $k = $self->{depth};
    my $n = scalar @$data;

    return if $n < (2 * $k + 1);   # no hay suficientes velas para un swing

    # ── Paso 1: detección de Swing High / Swing Low ──────────────────────────
    # PDF 4.1 — Swing High en índice i si y solo si:
    #   High[i] > High[i-k..i-1]  Y  High[i] > High[i+1..i+k]
    # Swing Low en índice i si y solo si:
    #   Low[i]  < Low[i-k..i-1]   Y  Low[i]  < Low[i+1..i+k]
    my @raw_swings;   # lista cronológica de { index, price, type }

    for (my $i = $k; $i <= $n - 1 - $k; $i++) {
        my $c = $data->[$i];

        # Comprobar Swing High
        my $is_high = 1;
        for my $j (($i - $k) .. ($i - 1), ($i + 1) .. ($i + $k)) {
            if ($data->[$j]{high} >= $c->{high}) {
                $is_high = 0;
                last;
            }
        }
        if ($is_high) {
            push @raw_swings, { index => $i, price => $c->{high}, type => 'high' };
            next;   # una vela no puede ser swing high y swing low a la vez
        }

        # Comprobar Swing Low
        my $is_low = 1;
        for my $j (($i - $k) .. ($i - 1), ($i + 1) .. ($i + $k)) {
            if ($data->[$j]{low} <= $c->{low}) {
                $is_low = 0;
                last;
            }
        }
        if ($is_low) {
            push @raw_swings, { index => $i, price => $c->{low}, type => 'low' };
        }
    }

    # ── Paso 2: máquina de estados HH/HL/LH/LL ───────────────────────────────
    # Se recorre la secuencia cronológica de swings comparando cada swing
    # con el ANTERIOR DEL MISMO TIPO (high con high, low con low).
    #   Swing High más alto que el SH anterior  -> HH (Higher High)
    #   Swing High más bajo  que el SH anterior  -> LH (Lower High)
    #   Swing Low  más alto que el SL anterior  -> HL (Higher Low)
    #   Swing Low  más bajo  que el SL anterior  -> LL (Lower Low)
    # El primer swing de cada tipo no tiene comparación previa: se etiqueta
    # con el nombre genérico según su tipo (high -> HH, low -> LL) como punto
    # de partida neutral de la secuencia.
    my $last_high;   # último Swing High visto { index, price }
    my $last_low;    # último Swing Low visto  { index, price }

    for my $sw (@raw_swings) {
        my $label;

        if ($sw->{type} eq 'high') {
            if (defined $last_high) {
                $label = ($sw->{price} > $last_high->{price}) ? 'HH' : 'LH';
            } else {
                $label = 'HH';   # primer swing high de la serie
            }
            $last_high = { index => $sw->{index}, price => $sw->{price} };
        } else {
            if (defined $last_low) {
                $label = ($sw->{price} > $last_low->{price}) ? 'HL' : 'LL';
            } else {
                $label = 'LL';   # primer swing low de la serie
            }
            $last_low = { index => $sw->{index}, price => $sw->{price} };
        }

        my $entry = {
            index => $sw->{index},
            price => $sw->{price},
            type  => $sw->{type},
            label => $label,
        };

        push @{ $self->{swings} }, $entry;
        $self->{swings_by_index}{ $sw->{index} } = $entry;
    }

    # ── Paso 3: detección de BOS y CHoCH ─────────────────────────────────────
    $self->_detect_bos_choch($data);

    # ── Paso 4: detección de Fair Value Gaps ─────────────────────────────────
    $self->_detect_fvg($data);
}

# ─────────────────────────────────────────────────────────────────────────────
# _detect_bos_choch — Punto 3.2
#
# Recorre las velas cronológicamente. En cada vela comprueba si el CIERRE
# rompe el último Swing High o Swing Low relevante. La clasificación sigue
# la relación estructural del PDF (sección 5):
#
#   BOS (Break of Structure)   — confirma la tendencia vigente:
#     · Alcista: Close > último HH  (la estructura de máximos sigue creciendo)
#     · Bajista: Close < último LL  (la estructura de mínimos sigue cayendo)
#
#   CHoCH (Change of Character) — señala una reversión de tendencia:
#     · Alcista a bajista: Close < último HL (rompe el último mínimo creciente)
#     · Bajista a alcista: Close > último LH (rompe el último máximo decreciente)
#
#   scope 'internal' vs 'external':
#     · internal: la ruptura solo supera el nivel del swing inmediatamente
#       anterior del tipo relevante (estructura de corto plazo).
#     · external: la ruptura además supera el swing ANTERIOR a ese — un nivel
#       de mayor jerarquía estructural dentro del mismo timeframe activo.
#       (La proyección desde TF superiores —HTF real— se añade en 3.4/3.5
#        cuando el módulo de Liquidez aporte el contexto multi-temporal).
#
# Una vez resuelto un evento, el nivel roto se considera "consumido" y no
# vuelve a generar el mismo tipo de evento hasta que aparezca un nuevo swing
# del tipo correspondiente — así se evita spamear el mismo BOS en cada vela
# que sigue cerrando por encima de un nivel ya roto.
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_bos_choch {
    my ($self, $data) = @_;

    # Snapshots ordenados cronológicamente de cada tipo de swing, para poder
    # ubicar "el último swing antes de la vela i" con un puntero avanzando.
    my @highs = grep { $_->{type} eq 'high' } @{ $self->{swings} };
    my @lows  = grep { $_->{type} eq 'low'  } @{ $self->{swings} };

    # Punteros de avance: cuántos swings de cada tipo ya han ocurrido
    # antes o en la vela actual.
    my $hi_ptr = 0;   # próximo índice en @highs aún no consumido por el puntero
    my $lo_ptr = 0;

    # Niveles "activos" disponibles para romper en cada momento.
    # last_high_1 = último HH/LH visto, last_high_2 = el anterior a ese (external)
    my ($last_high_1, $last_high_2);
    my ($last_low_1,  $last_low_2);

    # Bandera de "ya consumido": evita reportar el mismo BOS/CHoCH en cada
    # vela subsiguiente que sigue cerrando más allá del mismo nivel.
    my $bos_up_done    = 0;
    my $bos_down_done  = 0;
    my $choch_up_done  = 0;
    my $choch_down_done = 0;

    # Tendencia vigente, inferida de forma simple a partir de la secuencia
    # de swings: arranca 'unknown' y se fija con el primer BOS confirmado.
    my $trend = 'unknown';

    for (my $i = 0; $i < scalar(@$data); $i++) {
        my $close = $data->[$i]{close};

        # Avanzar los punteros de swings hasta incorporar todo lo que ya
        # ocurrió en índices <= i (un swing en el índice i mismo ya es
        # información válida porque depende de velas pasadas, no futuras,
        # gracias a la ventana de profundidad k usada en el paso 1).
        while ($hi_ptr <= $#highs && $highs[$hi_ptr]{index} <= $i) {
            $last_high_2 = $last_high_1;
            $last_high_1 = $highs[$hi_ptr];
            $hi_ptr++;
            # Nuevo swing high disponible: resetear banderas de consumo
            # relativas a niveles de "high" (BOS alcista, CHoCH bajista).
            $bos_up_done   = 0;
            $choch_down_done = 0;
        }
        while ($lo_ptr <= $#lows && $lows[$lo_ptr]{index} <= $i) {
            $last_low_2 = $last_low_1;
            $last_low_1 = $lows[$lo_ptr];
            $lo_ptr++;
            $bos_down_done = 0;
            $choch_up_done = 0;
        }

        # ── BOS alcista: Close > último Swing High ───────────────────────────
        if (defined $last_high_1 && $close > $last_high_1->{price} && !$bos_up_done) {
            my $scope = (defined $last_high_2 && $close > $last_high_2->{price})
                ? 'external' : 'internal';
            $self->_push_event($i, 'BOS', 'up', $scope,
                $last_high_1->{price}, $last_high_1->{index});
            $bos_up_done = 1;
            $trend = 'up';
        }

        # ── BOS bajista: Close < último Swing Low ────────────────────────────
        if (defined $last_low_1 && $close < $last_low_1->{price} && !$bos_down_done) {
            my $scope = (defined $last_low_2 && $close < $last_low_2->{price})
                ? 'external' : 'internal';
            $self->_push_event($i, 'BOS', 'down', $scope,
                $last_low_1->{price}, $last_low_1->{index});
            $bos_down_done = 1;
            $trend = 'down';
        }

        # ── CHoCH bajista: en tendencia alcista, Close < último Swing Low ────
        # (rompe el último HL — la estructura de mínimos crecientes se rompe)
        if ($trend eq 'up' && defined $last_low_1
            && $close < $last_low_1->{price} && !$choch_down_done) {
            my $scope = (defined $last_low_2 && $close < $last_low_2->{price})
                ? 'external' : 'internal';
            $self->_push_event($i, 'CHoCH', 'down', $scope,
                $last_low_1->{price}, $last_low_1->{index});
            $choch_down_done = 1;
            $trend = 'down';
        }

        # ── CHoCH alcista: en tendencia bajista, Close > último Swing High ───
        # (rompe el último LH — la estructura de máximos decrecientes se rompe)
        if ($trend eq 'down' && defined $last_high_1
            && $close > $last_high_1->{price} && !$choch_up_done) {
            my $scope = (defined $last_high_2 && $close > $last_high_2->{price})
                ? 'external' : 'internal';
            $self->_push_event($i, 'CHoCH', 'up', $scope,
                $last_high_1->{price}, $last_high_1->{index});
            $choch_up_done = 1;
            $trend = 'up';
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _detect_fvg — Punto 3.3
#
# Un Fair Value Gap (FVG) es un desequilibrio de precio: un hueco entre las
# mechas de dos velas separadas por una vela central, que el mercado tiende
# a "rellenar" más adelante. Definición del PDF (mecánica estándar SMC):
#
#   FVG alcista (up):   Low[i+1]  > High[i-1]
#     El hueco queda entre High[i-1] (abajo) y Low[i+1] (arriba).
#
#   FVG bajista (down): High[i+1] < Low[i-1]
#     El hueco queda entre High[i+1] (abajo) y Low[i-1] (arriba).
#
# Donde "i" es el índice de la vela CENTRAL (la vela impulsiva que crea el
# gap entre la vela anterior i-1 y la siguiente i+1).
#
# Mitigación: un FVG se considera mitigado en la primera vela posterior a
# su formación cuyo rango [low, high] vuelve a tocar el rango del gap
# [bottom, top]. A partir de ese índice, mitigated_at queda fijo — el FVG
# es histórico y no vuelve a "desmitigarse".
#
# El desvanecimiento progresivo (la opacidad visual) NO se calcula aquí:
# es responsabilidad del Overlay (3.5), que con índice de formación +
# índice actual del gráfico calcula cuántas velas han pasado y reduce la
# opacidad en consecuencia. Este indicador solo expone los datos crudos.
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_fvg {
    my ($self, $data) = @_;
    my $n = scalar @$data;

    return if $n < 3;

    for (my $i = 1; $i < $n - 1; $i++) {
        my $prev = $data->[$i - 1];
        my $next = $data->[$i + 1];

        my $fvg;

        # FVG alcista: el mínimo de la vela siguiente queda por encima
        # del máximo de la vela anterior — hueco sin solapamiento.
        if ($next->{low} > $prev->{high}) {
            $fvg = {
                index        => $i,
                direction    => 'up',
                top          => $next->{low},
                bottom       => $prev->{high},
                mitigated_at => undef,
            };
        }
        # FVG bajista: el máximo de la vela siguiente queda por debajo
        # del mínimo de la vela anterior.
        elsif ($next->{high} < $prev->{low}) {
            $fvg = {
                index        => $i,
                direction    => 'down',
                top          => $prev->{low},
                bottom       => $next->{high},
                mitigated_at => undef,
            };
        }

        next unless defined $fvg;

        # ── Búsqueda de mitigación ────────────────────────────────────────
        # Recorre las velas posteriores a la formación (desde i+2, ya que
        # i+1 es la vela que confirmó el gap y por definición no lo toca)
        # buscando la primera que vuelve a entrar al rango [bottom, top].
        for (my $j = $i + 2; $j < $n; $j++) {
            my $c = $data->[$j];
            if ($c->{low} <= $fvg->{top} && $c->{high} >= $fvg->{bottom}) {
                $fvg->{mitigated_at} = $j;
                last;
            }
        }

        push @{ $self->{fvgs} }, $fvg;
        $self->{fvgs_by_index}{$i} = $fvg;
    }
}

# Helper interno: registra un evento BOS/CHoCH en las dos estructuras de
# almacenamiento (lista cronológica + índice por vela).
sub _push_event {
    my ($self, $index, $type, $direction, $scope, $level_price, $level_index) = @_;

    my $event = {
        index       => $index,
        type        => $type,
        direction   => $direction,
        scope       => $scope,
        level_price => $level_price,
        level_index => $level_index,
    };

    push @{ $self->{events} }, $event;

    if (exists $self->{events_by_index}{$index}) {
        # Ya hay un evento en esta vela: convertir a arrayref si hace falta
        my $existing = $self->{events_by_index}{$index};
        if (ref($existing) eq 'ARRAY') {
            push @$existing, $event;
        } else {
            $self->{events_by_index}{$index} = [ $existing, $event ];
        }
    } else {
        $self->{events_by_index}{$index} = $event;
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers de consulta — usados por overlays y por 3.2 (BOS/CHoCH) más adelante
# ─────────────────────────────────────────────────────────────────────────────

# Devuelve el último Swing High registrado antes (o en) un índice dado.
# undef si no hay ninguno. Útil para BOS/CHoCH: "¿cuál es el último SH
# relevante para comparar con el precio actual?"
sub last_swing_high_before {
    my ($self, $index) = @_;
    my $found;
    for my $sw (@{ $self->{swings} }) {
        last if $sw->{index} > $index;
        $found = $sw if $sw->{type} eq 'high';
    }
    return $found;
}

# Equivalente para Swing Low.
sub last_swing_low_before {
    my ($self, $index) = @_;
    my $found;
    for my $sw (@{ $self->{swings} }) {
        last if $sw->{index} > $index;
        $found = $sw if $sw->{type} eq 'low';
    }
    return $found;
}

# Devuelve todos los swings dentro de un rango de índices [start, end].
# Usado por el Overlay para no iterar swings fuera de la ventana visible.
sub swings_in_range {
    my ($self, $start, $end) = @_;
    return [ grep { $_->{index} >= $start && $_->{index} <= $end } @{ $self->{swings} } ];
}

# Equivalente a swings_in_range pero para eventos BOS/CHoCH.
# Usado por el Overlay (3.5) para dibujar solo los eventos visibles.
sub events_in_range {
    my ($self, $start, $end) = @_;
    return [ grep { $_->{index} >= $start && $_->{index} <= $end } @{ $self->{events} } ];
}

# Devuelve solo los eventos de un tipo dado ('BOS' o 'CHoCH') dentro de un rango.
sub events_in_range_by_type {
    my ($self, $start, $end, $type) = @_;
    return [
        grep { $_->{index} >= $start && $_->{index} <= $end && $_->{type} eq $type }
        @{ $self->{events} }
    ];
}

# Devuelve los FVG cuyo rango de "vida visual" intersecta [start, end].
# Un FVG sigue siendo relevante para dibujar mientras no ha sido mitigado,
# o si la mitigación ocurrió dentro o después del rango visible — así el
# Overlay puede mostrar el rectángulo hasta el punto exacto de mitigación.
sub fvgs_in_range {
    my ($self, $start, $end) = @_;
    return [
        grep {
            $_->{index} <= $end
            && (!defined $_->{mitigated_at} || $_->{mitigated_at} >= $start)
        } @{ $self->{fvgs} }
    ];
}

# Devuelve solo los FVG todavía activos (sin mitigar) hasta un índice dado.
# Útil para el Overlay cuando solo interesa "lo que sigue siendo zona de
# reacción válida" en el momento actual del gráfico (incluye Replay).
sub active_fvgs_at {
    my ($self, $index) = @_;
    return [
        grep {
            $_->{index} <= $index
            && (!defined $_->{mitigated_at} || $_->{mitigated_at} > $index)
        } @{ $self->{fvgs} }
    ];
}

1;
