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
# Piezas del cronograma 29/06 (Tabla 4 del PDF) implementadas en este archivo:
#   - Order Blocks (OB): última vela opuesta antes de un BOS
#   - Support/Resistance: niveles horizontales de reacción repetida del precio
#   - Trendlines/Channels: líneas conectando swings consecutivos del mismo tipo
#   - "Near daily candle's body & wick": proximidad del precio actual a la
#     vela diaria más reciente
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
        depth => $args{depth} // 5,   # LuxAlgo default para 1m: 5

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

        # ── Order Blocks ────────────────────────────────────────────────────
        # order_blocks: arrayref cronológico de hashrefs:
        #   { index, direction, top, bottom, bos_index, mitigated_at }
        #     index        => índice de la vela OB (última opuesta antes del BOS)
        #     direction    => 'bullish' | 'bearish'
        #     top, bottom  => rango de precio del OB (high/low de esa vela)
        #     bos_index    => índice del BOS que originó este OB
        #     mitigated_at => índice donde el precio volvió a tocar el OB, o undef
        order_blocks => [],
        order_blocks_by_index => {},

        # ── Support / Resistance ────────────────────────────────────────────
        # support_resistance: arrayref de hashrefs:
        #   { price, kind, touches, first_index, last_index }
        #     kind    => 'support' | 'resistance'
        #     touches => arrayref de índices donde el precio reaccionó en este nivel
        support_resistance => [],

        # ── Trendlines / Channels ───────────────────────────────────────────
        # trendlines: arrayref de hashrefs:
        #   { kind, point1, point2, slope, intercept }
        #     kind   => 'support' (conecta Swing Lows) | 'resistance' (Swing Highs)
        #     point1, point2 => { index, price } — los dos swings que definen la línea
        #     slope, intercept => y = slope*x + intercept, para extender la línea
        trendlines => [],

        # ── Near daily candle's body & wick ─────────────────────────────────
        # daily_proximity: hashref con la referencia de la vela diaria más
        # reciente y la posición del precio actual respecto a su cuerpo/mecha.
        daily_proximity => undef,
    };
    bless $self, $class;
    return $self;
}


# ─────────────────────────────────────────────────────────────────────────────
# _offset_indices — suma $base a todos los índices (locales -> globales) tras un
# cálculo por ventana (Market::WindowProxy). NO toca daily_proximity->{daily_index}
# porque ese es un índice del array 'D', no del 1m. Reconstruye los hashes *_by_index.
# ─────────────────────────────────────────────────────────────────────────────
sub _offset_indices {
    my ($self, $base) = @_;
    return if !$base;

    for my $sw (@{ $self->{swings} }) { $sw->{index} += $base; }
    for my $ev (@{ $self->{events} }) {
        $ev->{index}       += $base;
        $ev->{level_index} += $base if defined $ev->{level_index};
    }
    for my $f (@{ $self->{fvgs} }) {
        $f->{index}        += $base;
        $f->{mitigated_at} += $base if defined $f->{mitigated_at};
    }
    for my $ob (@{ $self->{order_blocks} }) {
        $ob->{index}        += $base;
        $ob->{bos_index}    += $base if defined $ob->{bos_index};
        $ob->{mitigated_at} += $base if defined $ob->{mitigated_at};
    }
    for my $lvl (@{ $self->{support_resistance} }) {
        $lvl->{first_index} += $base;
        $lvl->{last_index}  += $base;
        $_ += $base for @{ $lvl->{touches} };
    }
    for my $tl (@{ $self->{trendlines} }) {
        $tl->{point1}{index} += $base;
        $tl->{point2}{index} += $base;
        # slope/intercept se recalculan en índices globales:
        my ($p1,$p2) = ($tl->{point1}, $tl->{point2});
        my $dx = $p2->{index} - $p1->{index};
        if ($dx != 0) {
            $tl->{slope}     = ($p2->{price} - $p1->{price}) / $dx;
            $tl->{intercept} = $p1->{price} - $tl->{slope} * $p1->{index};
        }
    }

    # Reconstruir los índices O(1) por vela
    $self->{swings_by_index} = {};
    $self->{swings_by_index}{ $_->{index} } = $_ for @{ $self->{swings} };
    $self->{events_by_index} = {};
    for my $ev (@{ $self->{events} }) {
        my $k = $ev->{index};
        if (exists $self->{events_by_index}{$k}) {
            my $e = $self->{events_by_index}{$k};
            $self->{events_by_index}{$k} = ref($e) eq 'ARRAY' ? [@$e,$ev] : [$e,$ev];
        } else { $self->{events_by_index}{$k} = $ev; }
    }
    $self->{fvgs_by_index} = {};
    $self->{fvgs_by_index}{ $_->{index} } = $_ for @{ $self->{fvgs} };
    $self->{order_blocks_by_index} = {};
    $self->{order_blocks_by_index}{ $_->{index} } = $_ for @{ $self->{order_blocks} };
}


sub reset {
    my ($self) = @_;
    $self->{swings} = [];
    $self->{swings_by_index} = {};
    $self->{events} = [];
    $self->{events_by_index} = {};
    $self->{fvgs} = [];
    $self->{fvgs_by_index} = {};
    $self->{order_blocks} = [];
    $self->{order_blocks_by_index} = {};
    $self->{support_resistance} = [];
    $self->{trendlines} = [];
    $self->{daily_proximity} = undef;
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

# Devuelve el Order Block formado en una vela específica, o undef.
sub order_block_at {
    my ($self, $index) = @_;
    return $self->{order_blocks_by_index}{$index};
}

sub values_order_blocks {
    my ($self) = @_;
    return $self->{order_blocks};
}

sub values_support_resistance {
    my ($self) = @_;
    return $self->{support_resistance};
}

sub values_trendlines {
    my ($self) = @_;
    return $self->{trendlines};
}

sub daily_proximity {
    my ($self) = @_;
    return $self->{daily_proximity};
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

    # ── Paso 1 + 2: Swing Points con alternancia forzada (estilo LuxAlgo) ──────
    #
    # Algoritmo en dos fases:
    #   A) Candidatos: velas que son extremo local dentro de la ventana ±k.
    #   B) Zigzag con alternancia estricta: en rachas del mismo tipo (high/high
    #      o low/low) conservar solo el extremo más pronunciado. Esto produce
    #      una secuencia high→low→high→... limpia, igual que LuxAlgo SMC.
    #
    # Esto elimina el 99% de las etiquetas duplicadas/consecutivas y produce
    # la misma densidad visual que TradingView (5-10 swings en 200 velas).

    # Fase A: candidatos extremo local
    my @cand;
    for (my $i = $k; $i <= $n - 1 - $k; $i++) {
        my $c = $data->[$i];

        my $is_high = 1;
        for my $j (($i - $k) .. ($i - 1), ($i + 1) .. ($i + $k)) {
            if ($data->[$j]{high} >= $c->{high}) { $is_high = 0; last; }
        }
        if ($is_high) {
            push @cand, { index => $i, price => $c->{high}, type => 'high' };
            next;
        }

        my $is_low = 1;
        for my $j (($i - $k) .. ($i - 1), ($i + 1) .. ($i + $k)) {
            if ($data->[$j]{low} <= $c->{low}) { $is_low = 0; last; }
        }
        if ($is_low) {
            push @cand, { index => $i, price => $c->{low}, type => 'low' };
        }
    }

    # Fase B: zigzag con alternancia estricta
    # En rachas del mismo tipo conservar el extremo más pronunciado (igual
    # que hace el ZZMTF). Produce secuencia limpia high/low/high/...
    my @zz;
    for my $c (@cand) {
        if (!@zz) { push @zz, $c; next; }
        my $last = $zz[-1];
        if ($last->{type} eq $c->{type}) {
            # mismo tipo: conservar el más extremo
            if ($c->{type} eq 'high') {
                $zz[-1] = $c if $c->{price} > $last->{price};
            } else {
                $zz[-1] = $c if $c->{price} < $last->{price};
            }
        } else {
            push @zz, $c;
        }
    }

    # Fase C: etiquetar HH/HL/LH/LL comparando cada swing con el anterior
    # del mismo tipo (igual que antes pero ahora la serie ya está alternada)
    my $last_high;
    my $last_low;

    for my $sw (@zz) {
        my $label;
        if ($sw->{type} eq 'high') {
            $label = defined $last_high
                   ? ($sw->{price} > $last_high->{price} ? 'HH' : 'LH')
                   : 'HH';
            $last_high = $sw;
        } else {
            $label = defined $last_low
                   ? ($sw->{price} > $last_low->{price} ? 'HL' : 'LL')
                   : 'LL';
            $last_low = $sw;
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

    # ── Paso 5: Order Blocks (última vela opuesta antes de cada BOS) ────────
    $self->_detect_order_blocks($data);

    # ── Paso 6: Support / Resistance (niveles con reacción repetida) ────────
    $self->_detect_support_resistance($data);

    # ── Paso 7: Trendlines / Channels (líneas entre swings consecutivos) ────
    $self->_detect_trendlines();

    # ── Paso 8: proximidad a la vela diaria más reciente ─────────────────────
    $self->_calc_daily_proximity($market_data, $data);

    # Ordenar trendlines por point1.index para habilitar búsqueda binaria
    @{ $self->{trendlines} } = sort { $a->{point1}{index} <=> $b->{point1}{index} }
                                @{ $self->{trendlines} };

    # Índice de buckets para FVG y OB (O(1) lookup en draw)
    $self->_build_bucket_index();

    # Windowing (Market::WindowProxy): convertir índices locales -> globales.
    my $base = (ref($market_data) && $market_data->can('base_index'))
             ? $market_data->base_index : 0;
    $self->_offset_indices($base) if $base;
}

# ─────────────────────────────────────────────────────────────────────────────
# _build_bucket_index — asigna cada FVG y OB a todos los buckets que solapa.
# Un FVG/OB vive desde {index} hasta {mitigated_at} (o ∞). Se añade al bucket
# de su {index} y al de su fin, para que fvgs_in_range los encuentre aunque
# el rango visible caiga en el medio de su "vida".
# ─────────────────────────────────────────────────────────────────────────────
sub _build_bucket_index {
    my ($self) = @_;
    my $B = 1000;
    $self->{_bucket_size} = $B;

    my (%fvg_idx, %ob_idx);
    for my $fvg (@{ $self->{fvgs} }) {
        my $b0 = int($fvg->{index} / $B);
        my $b1 = defined $fvg->{mitigated_at}
               ? int($fvg->{mitigated_at} / $B)
               : $b0 + 200;   # activos: cubrimos 200k velas hacia adelante
        $b1 = $b0 + 200 if $b1 - $b0 > 200;
        push @{ $fvg_idx{$_} }, $fvg for $b0 .. $b1;
    }
    for my $ob (@{ $self->{order_blocks} }) {
        my $b0 = int($ob->{index} / $B);
        my $b1 = defined $ob->{mitigated_at}
               ? int($ob->{mitigated_at} / $B)
               : $b0 + 200;
        $b1 = $b0 + 200 if $b1 - $b0 > 200;
        push @{ $ob_idx{$_} }, $ob for $b0 .. $b1;
    }
    $self->{_fvg_bucket_idx} = \%fvg_idx;
    $self->{_ob_bucket_idx}  = \%ob_idx;
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

    # ── Algoritmo alineado con LuxAlgo SMC ──────────────────────────────────
    # Principios clave observados en TradingView:
    #
    # 1. ALTERNANCIA ESTRUCTURAL: la tendencia alterna entre BOS y CHoCH.
    #    En tendencia alcista: BOS up confirman, CHoCH down señala reversión.
    #    En tendencia bajista: BOS down confirman, CHoCH up señala reversión.
    #
    # 2. UN EVENTO POR SWING: una vez que se rompe un nivel (swing_index),
    #    ese nivel queda "consumido". No se emite otro evento para el mismo
    #    nivel aunque el precio siga cerrando más allá.
    #
    # 3. CHoCH + BOS simultáneos: cuando el mismo close rompe el nivel del
    #    CHoCH Y el del BOS, se emiten ambos — el CHoCH con el nivel del
    #    swing contrario roto, el BOS con el nivel del swing a favor.
    #
    # 4. CUERPO de la vela: la ruptura se confirma con max(open,close) para
    #    alcistas y min(open,close) para bajistas. Las mechas no cuentan.
    #
    # 5. NIVEL CORRECTO: BOS up usa last_high_1 (el swing high más reciente),
    #    BOS down usa last_low_1. El "external" usa el swing anterior.

    my @highs = grep { $_->{type} eq 'high' } @{ $self->{swings} };
    my @lows  = grep { $_->{type} eq 'low'  } @{ $self->{swings} };

    my $hi_ptr = 0;
    my $lo_ptr = 0;
    my ($last_high_1, $last_high_2);
    my ($last_low_1,  $last_low_2);

    # Índices de los swings ya "consumidos" por un evento
    my %consumed_high;
    my %consumed_low;

    my $trend = 'unknown';

    for (my $i = 0; $i < scalar(@$data); $i++) {

        # Avanzar punteros incorporando swings hasta el índice actual
        while ($hi_ptr <= $#highs && $highs[$hi_ptr]{index} <= $i) {
            $last_high_2 = $last_high_1;
            $last_high_1 = $highs[$hi_ptr];
            $hi_ptr++;
        }
        while ($lo_ptr <= $#lows && $lows[$lo_ptr]{index} <= $i) {
            $last_low_2 = $last_low_1;
            $last_low_1 = $lows[$lo_ptr];
            $lo_ptr++;
        }

        next unless defined $last_high_1 && defined $last_low_1;

        # Cuerpo de la vela (mechas excluidas)
        my $body_high = $data->[$i]{close} > $data->[$i]{open}
                      ? $data->[$i]{close} : $data->[$i]{open};
        my $body_low  = $data->[$i]{close} < $data->[$i]{open}
                      ? $data->[$i]{close} : $data->[$i]{open};

        # ── CHoCH bajista: tendencia up, cuerpo rompe bajo el último HL ─────
        if (($trend eq 'up' || $trend eq 'unknown')
            && !$consumed_low{ $last_low_1->{index} }
            && $body_low < $last_low_1->{price}) {

            my $scope = (defined $last_low_2 && $body_low < $last_low_2->{price})
                      ? 'external' : 'internal';
            $self->_push_event($i, 'CHoCH', 'down', $scope,
                $last_low_1->{price}, $last_low_1->{index});
            $consumed_low{ $last_low_1->{index} } = 1;
            $trend = 'down';
        }

        # ── CHoCH alcista: tendencia down, cuerpo rompe sobre el último LH ──
        if (($trend eq 'down' || $trend eq 'unknown')
            && !$consumed_high{ $last_high_1->{index} }
            && $body_high > $last_high_1->{price}) {

            my $scope = (defined $last_high_2 && $body_high > $last_high_2->{price})
                      ? 'external' : 'internal';
            $self->_push_event($i, 'CHoCH', 'up', $scope,
                $last_high_1->{price}, $last_high_1->{index});
            $consumed_high{ $last_high_1->{index} } = 1;
            $trend = 'up';
        }

        # ── BOS alcista: tendencia up, cuerpo rompe sobre un swing high ─────
        if ($trend eq 'up'
            && !$consumed_high{ $last_high_1->{index} }
            && $body_high > $last_high_1->{price}) {

            my $scope = (defined $last_high_2 && $body_high > $last_high_2->{price})
                      ? 'external' : 'internal';
            # Usar el nivel más relevante que se rompió
            my $lvl = (defined $last_high_2 && $body_high > $last_high_2->{price})
                    ? $last_high_2 : $last_high_1;
            $self->_push_event($i, 'BOS', 'up', $scope,
                $lvl->{price}, $lvl->{index});
            $consumed_high{ $last_high_1->{index} } = 1;
        }

        # ── BOS bajista: tendencia down, cuerpo rompe bajo un swing low ──────
        if ($trend eq 'down'
            && !$consumed_low{ $last_low_1->{index} }
            && $body_low < $last_low_1->{price}) {

            my $scope = (defined $last_low_2 && $body_low < $last_low_2->{price})
                      ? 'external' : 'internal';
            my $lvl = (defined $last_low_2 && $body_low < $last_low_2->{price})
                    ? $last_low_2 : $last_low_1;
            $self->_push_event($i, 'BOS', 'down', $scope,
                $lvl->{price}, $lvl->{index});
            $consumed_low{ $last_low_1->{index} } = 1;
        }
    }
}


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

# ─────────────────────────────────────────────────────────────────────────────
# _detect_order_blocks — "OB: Inside Order Blocks" (cronograma 29/06)
#
# Un Order Block es la última vela de dirección OPUESTA a un movimiento
# impulsivo, justo antes de que ese movimiento confirme un BOS. Representa
# la zona donde "smart money" habría acumulado posiciones antes de mover
# el precio — definición estándar ICT/LuxAlgo:
#
#   OB alcista (bullish): para un BOS alcista (direction='up'), es la
#   última vela BAJISTA (close < open) en el rango [level_index, event_index)
#   del evento BOS. Su rango de precio es [low, high] de esa vela.
#
#   OB bajista (bearish): para un BOS bajista (direction='down'), es la
#   última vela ALCISTA (close > open) en ese mismo rango.
#
# Mitigación: el OB se considera mitigado en la primera vela posterior al
# BOS cuyo rango vuelve a tocar el rango de precio del OB — el precio
# "regresó a recoger" esa liquidez.
#
# Solo se generan Order Blocks a partir de eventos BOS (no CHoCH), ya que
# el OB representa el origen de una continuación de tendencia confirmada.
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_order_blocks {
    my ($self, $data) = @_;
    my $n = scalar @$data;

    for my $ev (@{ $self->{events} }) {
        next unless $ev->{type} eq 'BOS';

        my $is_bullish_bos = ($ev->{direction} eq 'up');
        my $search_start    = $ev->{level_index};
        my $search_end      = $ev->{index};
        next if $search_end <= $search_start;

        # Buscar hacia atrás desde el evento la última vela de dirección opuesta
        my $ob_index;
        for (my $j = $search_end - 1; $j >= $search_start; $j--) {
            my $c = $data->[$j];
            my $is_opposite = $is_bullish_bos
                ? ($c->{close} < $c->{open})    # vela bajista para OB alcista
                : ($c->{close} > $c->{open});   # vela alcista para OB bajista
            if ($is_opposite) {
                $ob_index = $j;
                last;
            }
        }
        next unless defined $ob_index;

        my $ob_candle = $data->[$ob_index];
        my $ob = {
            index        => $ob_index,
            direction    => $is_bullish_bos ? 'bullish' : 'bearish',
            top          => $ob_candle->{high},
            bottom       => $ob_candle->{low},
            bos_index    => $ev->{index},
            mitigated_at => undef,
        };

        # Buscar mitigación: primera vela posterior al BOS que vuelve a
        # tocar el rango del Order Block.
        for (my $j = $ev->{index} + 1; $j < $n; $j++) {
            my $c = $data->[$j];
            if ($c->{low} <= $ob->{top} && $c->{high} >= $ob->{bottom}) {
                $ob->{mitigated_at} = $j;
                last;
            }
        }

        push @{ $self->{order_blocks} }, $ob;
        $self->{order_blocks_by_index}{$ob_index} = $ob;
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _detect_support_resistance — "Support/Resistence: below support or above
# resistance levels" (cronograma 29/06)
#
# Agrupa los Swing Highs en niveles de Resistencia y los Swing Lows en
# niveles de Soporte: cuando varios swings del mismo tipo caen dentro de
# una tolerancia de precio entre sí (misma idea de EQH/EQL pero acumulando
# TODOS los toques, no solo pares), se consolidan en un único nivel con
# la lista de índices donde el precio reaccionó ahí.
#
# Solo se reportan niveles con 2 o más toques — un solo swing aislado no
# es un nivel de "soporte/resistencia", es solo un Swing Point normal.
#
# Tolerancia: se usa un porcentaje fijo simple (0.15% del precio del
# primer toque) para no depender del ATR de Liquidity.pm — este archivo
# se mantiene autocontenido según la Tabla 1 del PDF.
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_support_resistance {
    my ($self, $data) = @_;
    my $tolerance_pct = 0.0015;   # 0.15%

    for my $kind_info (
        { type => 'high', kind => 'resistance' },
        { type => 'low',  kind => 'support' },
    ) {
        # OPTIMIZADO: en vez de O(n^2) comparando todos los pares, ordenamos
        # los pivotes por precio y agrupamos clústeres contiguos dentro de
        # tolerancia. O(n log n). Produce los mismos niveles de S/R.
        my @pivots = sort { $a->{price} <=> $b->{price} }
                     grep { $_->{type} eq $kind_info->{type} } @{ $self->{swings} };
        my $i = 0;
        while ($i <= $#pivots) {
            my $base_price = $pivots[$i]{price};
            my $tolerance  = $base_price * $tolerance_pct;
            my @touches    = ($pivots[$i]{index});
            my $sum_price  = $base_price;
            my $count      = 1;
            my $j = $i + 1;
            while ($j <= $#pivots
                   && abs($pivots[$j]{price} - $base_price) <= $tolerance) {
                push @touches, $pivots[$j]{index};
                $sum_price += $pivots[$j]{price};
                $count++;
                $j++;
            }
            if ($count >= 2) {
                @touches = sort { $a <=> $b } @touches;
                push @{ $self->{support_resistance} }, {
                    price       => $sum_price / $count,
                    kind        => $kind_info->{kind},
                    touches     => \@touches,
                    first_index => $touches[0],
                    last_index  => $touches[-1],
                };
            }
            $i = $j;
        }
    }

    # Ordenar cronológicamente por el primer toque, para consistencia visual.
    @{ $self->{support_resistance} } =
        sort { $a->{first_index} <=> $b->{first_index} } @{ $self->{support_resistance} };
}

# ─────────────────────────────────────────────────────────────────────────────
# _detect_trendlines — "Trendlines/Channels: below or above" (cronograma 29/06)
#
# Conecta SWINGS CONSECUTIVOS del mismo tipo con una línea recta:
#   - Línea de resistencia: conecta cada par de Swing Highs consecutivos
#     (la línea queda "arriba" del precio — channel superior).
#   - Línea de soporte: conecta cada par de Swing Lows consecutivos
#     (la línea queda "abajo" del precio — channel inferior).
#
# Cada trendline se expresa como y = slope*x + intercept (en términos de
# índice de vela como x y precio como y) para que el Overlay pueda
# extender la línea más allá del segundo punto y dibujar el canal completo.
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_trendlines {
    my ($self) = @_;

    for my $type ('high', 'low') {
        my @pivots = grep { $_->{type} eq $type } @{ $self->{swings} };
        next if @pivots < 2;

        for (my $i = 0; $i < $#pivots; $i++) {
            my $p1 = $pivots[$i];
            my $p2 = $pivots[$i + 1];

            my $dx = $p2->{index} - $p1->{index};
            next if $dx == 0;

            my $slope     = ($p2->{price} - $p1->{price}) / $dx;
            my $intercept = $p1->{price} - $slope * $p1->{index};

            push @{ $self->{trendlines} }, {
                kind      => ($type eq 'high') ? 'resistance' : 'support',
                point1    => { index => $p1->{index}, price => $p1->{price} },
                point2    => { index => $p2->{index}, price => $p2->{price} },
                slope     => $slope,
                intercept => $intercept,
            };
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _calc_daily_proximity — "near daily candle's body & wick" (cronograma 29/06)
#
# Calcula la posición del PRECIO ACTUAL (cierre de la última vela visible)
# respecto al cuerpo y la mecha de la vela DIARIA más reciente. Útil como
# referencia visual de "qué tan cerca está el precio de zonas relevantes
# del día" — exactamente lo que TradingView/LuxAlgo muestran con niveles
# "Previous Day High/Low" combinados con el cuerpo de la vela.
#
# Requiere acceso al MarketData completo (no solo al slice del TF activo)
# para leer la temporalidad 'D' independientemente de en qué TF esté
# navegando el usuario — mismo patrón que el volumen multi-temporal del
# PDF 4.4 en Liquidity.pm.
#
# Resultado almacenado en daily_proximity:
#   {
#     daily_index,        # índice de la vela diaria de referencia
#     body_top, body_bottom,    # max/min de open y close de esa vela diaria
#     wick_top, wick_bottom,    # high/low de esa vela diaria
#     current_price,       # close de la última vela visible en el TF activo
#     zone,                 # 'above_wick' | 'in_upper_wick' | 'in_body' |
#                            # 'in_lower_wick' | 'below_wick'
#     distance_to_body,     # distancia en precio al cuerpo más cercano
#   }
# ─────────────────────────────────────────────────────────────────────────────
sub _calc_daily_proximity {
    my ($self, $market_data, $data) = @_;
    return unless @$data;

    my $daily = eval { $market_data->get_tf_data('D') };
    return unless $daily && @$daily;

    my $current_price = $data->[-1]{close};
    my $current_epoch = $data->[-1]{epoch};

    # Encontrar la vela diaria más reciente cuyo epoch sea <= la vela actual
    my $ref_candle;
    my $ref_index;
    for my $i (0 .. $#$daily) {
        if ($daily->[$i]{epoch} <= $current_epoch) {
            $ref_candle = $daily->[$i];
            $ref_index  = $i;
        } else {
            last;
        }
    }
    return unless defined $ref_candle;

    my $body_top    = $ref_candle->{open} > $ref_candle->{close} ? $ref_candle->{open}  : $ref_candle->{close};
    my $body_bottom = $ref_candle->{open} > $ref_candle->{close} ? $ref_candle->{close} : $ref_candle->{open};
    my $wick_top    = $ref_candle->{high};
    my $wick_bottom = $ref_candle->{low};

    my $zone;
    my $distance_to_body;

    if ($current_price > $wick_top) {
        $zone = 'above_wick';
        $distance_to_body = $current_price - $body_top;
    } elsif ($current_price > $body_top) {
        $zone = 'in_upper_wick';
        $distance_to_body = $current_price - $body_top;
    } elsif ($current_price >= $body_bottom) {
        $zone = 'in_body';
        $distance_to_body = 0;
    } elsif ($current_price >= $wick_bottom) {
        $zone = 'in_lower_wick';
        $distance_to_body = $body_bottom - $current_price;
    } else {
        $zone = 'below_wick';
        $distance_to_body = $body_bottom - $current_price;
    }

    $self->{daily_proximity} = {
        daily_index       => $ref_index,
        body_top          => $body_top,
        body_bottom       => $body_bottom,
        wick_top          => $wick_top,
        wick_bottom       => $wick_bottom,
        current_price     => $current_price,
        zone              => $zone,
        distance_to_body  => $distance_to_body,
    };
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
# ─────────────────────────────────────────────────────────────────────────────
# *_in_range OPTIMIZADOS — búsqueda binaria O(log n + k) en lugar de
# grep O(n). Los arrays {swings}, {events}, {trendlines} están ordenados
# por {index}; usamos _bsearch_lo/_bsearch_hi para acotar el slice.
# ─────────────────────────────────────────────────────────────────────────────

sub _bsearch_lo {
    # primer índice en el array donde $arr->[$i]{index} >= $val
    my ($arr, $val) = @_;
    my ($lo, $hi) = (0, scalar @$arr);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        $arr->[$mid]{index} < $val ? ($lo = $mid + 1) : ($hi = $mid);
    }
    return $lo;
}

sub _bsearch_hi {
    # último índice en el array donde $arr->[$i]{index} <= $val  (retorna -1 si ninguno)
    my ($arr, $val) = @_;
    my ($lo, $hi) = (0, $#{$arr});
    return -1 if !@$arr || $arr->[0]{index} > $val;
    while ($lo < $hi) {
        my $mid = int(($lo + $hi + 1) / 2);
        $arr->[$mid]{index} > $val ? ($hi = $mid - 1) : ($lo = $mid);
    }
    return $lo;
}

sub swings_in_range {
    my ($self, $start, $end) = @_;
    my $arr = $self->{swings};
    return [] unless @$arr;
    my $lo = _bsearch_lo($arr, $start);
    my $hi = _bsearch_hi($arr, $end);
    return [] if $hi < $lo;
    return [ @{$arr}[$lo .. $hi] ];
}

# Equivalente a swings_in_range pero para eventos BOS/CHoCH.
# Usado por el Overlay (3.5) para dibujar solo los eventos visibles.
sub events_in_range {
    my ($self, $start, $end) = @_;
    my $arr = $self->{events};
    return [] unless @$arr;
    my $lo = _bsearch_lo($arr, $start);
    my $hi = _bsearch_hi($arr, $end);
    return [] if $hi < $lo;
    return [ @{$arr}[$lo .. $hi] ];
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
    # Usar índice de buckets si está disponible (O(k) en vez de O(n))
    if (my $idx = $self->{_fvg_bucket_idx}) {
        my $B = $self->{_bucket_size};
        my $b0 = int($start / $B);
        my $b1 = int($end   / $B);
        my %seen;
        my @cand;
        for my $b ($b0 .. $b1) {
            for my $fvg (@{ $idx->{$b} // [] }) {
                next if $seen{$fvg}++;
                push @cand, $fvg
                    if $fvg->{index} <= $end
                    && (!defined $fvg->{mitigated_at} || $fvg->{mitigated_at} >= $start);
            }
        }
        return \@cand;
    }
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

# Order Blocks dentro de un rango — su "vida visual" intersecta [start,end]
# igual criterio que fvgs_in_range: relevante mientras no mitigado, o si
# la mitigación ocurrió dentro/después del rango visible.
sub order_blocks_in_range {
    my ($self, $start, $end) = @_;
    if (my $idx = $self->{_ob_bucket_idx}) {
        my $B = $self->{_bucket_size};
        my $b0 = int($start / $B);
        my $b1 = int($end   / $B);
        my %seen; my @cand;
        for my $b ($b0 .. $b1) {
            for my $ob (@{ $idx->{$b} // [] }) {
                next if $seen{$ob}++;
                push @cand, $ob
                    if $ob->{index} <= $end
                    && (!defined $ob->{mitigated_at} || $ob->{mitigated_at} >= $start);
            }
        }
        return \@cand;
    }
    return [
        grep {
            $_->{index} <= $end
            && (!defined $_->{mitigated_at} || $_->{mitigated_at} >= $start)
        } @{ $self->{order_blocks} }
    ];
}

# Niveles de Support/Resistance cuyo primer toque cae dentro de [start,end]
# o cuyo último toque sigue siendo posterior a start (nivel "vivo" en la
# ventana visible).
sub support_resistance_in_range {
    my ($self, $start, $end) = @_;
    return [
        grep { $_->{first_index} <= $end && $_->{last_index} >= $start }
        @{ $self->{support_resistance} }
    ];
}

# Trendlines cuyo segmento [point1.index, point2.index] intersecta el
# rango visible [start,end].
sub trendlines_in_range {
    my ($self, $start, $end) = @_;
    my $arr = $self->{trendlines};
    return [] unless @$arr;
    # Trendlines ordenados por point1.index. Encontrar el último con p1 <= end.
    my ($lo2, $hi2) = (0, $#{$arr});
    return [] if $arr->[0]{point1}{index} > $end;
    while ($lo2 < $hi2) {
        my $mid = int(($lo2 + $hi2 + 1) / 2);
        $arr->[$mid]{point1}{index} > $end ? ($hi2 = $mid - 1) : ($lo2 = $mid);
    }
    # De esos, filtrar por point2.index >= start (pocos elementos pasan este test)
    return [ grep { $_->{point2}{index} >= $start } @{$arr}[0 .. $lo2] ];
}

1;
