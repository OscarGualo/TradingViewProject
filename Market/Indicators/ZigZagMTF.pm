package Market::Indicators::ZigZagMTF;
use strict;
use warnings;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::ZigZagMTF
#
# "ZigZag Multi Time Frame with Fibonacci Retracement [ZZMTF]" — indicador de
# DIRECCIÓN INTERNA del precio (PDF "Indicadores zigzag", pág. 4 y 5).
#
# Objetivo: limpiar el ruido de las etiquetas HH/HL/LH/LL en baja temporalidad.
# En vez de detectar swings sobre el 1m (ruidoso), detecta el zigzag sobre una
# temporalidad de referencia superior (30m por defecto) y lo PROYECTA sobre el
# gráfico de 1m. El resultado es una dirección interna limpia.
#
# Config interna (PDF pág. 4, panel "ZZMTF"):
#   ZigZag Resolution : 30 min     ZigZag Period : 2      Show Zig Zag : on
#   Show Fibonacci Ratios : off     Colorful Fibonacci : off
#   Text Color : azul   Line Color : verde   Zigzag Line Colors : verde/rojo
#   Label Location : Left   Enable Level 0.236/0.382/0.5/0.618/0.786 : off
#
# NO calcula nada de otros indicadores ni modifica MarketData. Construye la
# temporalidad de 30m bajo demanda con build_tf_candles (idempotente y barato)
# y solo cuando el objeto lo soporta (MarketData real); en Replay recibe un
# WindowProxy y la lee ya construida.
#
# Comportamiento en Replay (PDF pág. 5): el ÚLTIMO segmento es TENTATIVO — el
# zigzag "espera" a que se consoliden velas del TF de referencia antes de
# confirmar la dirección. Al confirmarse un pivote, el segmento anterior queda
# fijo. Esto emerge de forma natural: solo se detectan pivotes con 'period'
# velas cerradas a cada lado, así que el tramo hasta el precio actual queda
# tentativo hasta que el TF superior cierra suficientes velas.
#
# Separación Indicators vs Overlays (Tabla 1): este archivo SOLO calcula; el
# dibujo lo hace Market::Overlays::ZigZag.
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %a) = @_;
    my $self = {
        # ── Config interna (default = PDF pág. 4) ──────────────────────────
        resolution     => $a{resolution}     // 30,   # ZigZag Resolution (min)
        period         => $a{period}         // 2,    # ZigZag Period (depth)
        show_zigzag    => $a{show_zigzag}    // 1,
        show_fib       => $a{show_fib}       // 0,     # Show Fibonacci Ratios
        colorful_fib   => $a{colorful_fib}   // 0,     # Colorful Fibonacci Levels
        text_color     => $a{text_color}     // '#2962ff',  # azul
        line_color     => $a{line_color}     // '#26a69a',  # verde
        up_color       => $a{up_color}       // '#26a69a',  # alcista  (verde)
        down_color     => $a{down_color}     // '#ef5350',  # bajista  (rojo)
        label_location => $a{label_location} // 'left',
        fib_enabled    => $a{fib_enabled}    // {       # Enable Level *: todos off
            '0.236' => 0, '0.382' => 0, '0.500' => 0, '0.618' => 0, '0.786' => 0,
        },

        # ── Resultados ─────────────────────────────────────────────────────
        pivots    => [],    # [{index, price, label, type, confirmed}]
        segments  => [],    # [{from,to,dir,confirmed}]  index/price en from/to
        tentative => undef, # {from,to,dir}  último tramo aún sin confirmar
        fib       => undef, # {from,to,levels=>[{level,price}]}
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my $s = shift;
    $s->{pivots}    = [];
    $s->{segments}  = [];
    $s->{tentative} = undef;
    $s->{fib}       = undef;
}

sub values { return $_[0]->{segments}; }   # contrato mínimo del IndicatorManager

# ─────────────────────────────────────────────────────────────────────────────
sub calculate_all {
    my ($self, $md) = @_;
    $self->reset;

    my $res   = $self->{resolution};
    my $depth = $self->{period};
    my $sec   = $res * 60;

    # Construir el TF de referencia (30m) solo si el objeto lo permite
    # (MarketData real). En Replay (WindowProxy) ya está construido.
    $md->build_tf_candles($res) if $md->can('build_tf_candles');
    my $htf = $md->get_tf_data($res) || [];
    return unless @$htf;

    # Slice 1m (para proyección y epoch "actual" = cursor en Replay)
    my $ltf = $md->get_slice(0, $md->last_index());
    return unless @$ltf;
    my $cur_epoch = $ltf->[-1]{epoch};

    # Solo buckets del TF de referencia YA CERRADOS a la altura del cursor.
    # Esto impide "ver" velas futuras del 30m en Replay.
    my @closed = grep { $_->{epoch} + $sec <= $cur_epoch + 60 } @$htf;
    return unless @closed >= (2 * $depth + 2);

    # ── ZigZag sobre el TF de referencia ──────────────────────────────────
    my $piv = $self->_zigzag(\@closed, $depth);
    return unless @$piv;

    # Confirmación: un pivote está confirmado si tiene 'depth' buckets cerrados
    # a su derecha (su lado derecho ya no puede cambiar).
    my $last_closed = $#closed;
    for my $p (@$piv) {
        $p->{confirmed} = ($p->{idx} + $depth <= $last_closed) ? 1 : 0;
    }

    $self->_label($piv);

    # ── Proyección de cada pivote al índice 1m equivalente ────────────────
    my $proj = $self->_project($piv, \@closed, $ltf, $sec);
    $self->{pivots} = $proj;

    # ── Segmentos entre pivotes consecutivos ──────────────────────────────
    my @seg;
    for (my $i = 0; $i < $#$proj; $i++) {
        my ($a, $b) = ($proj->[$i], $proj->[$i + 1]);
        push @seg, {
            from      => { index => $a->{index}, price => $a->{price} },
            to        => { index => $b->{index}, price => $b->{price} },
            dir       => ($b->{price} >= $a->{price}) ? 'up' : 'down',
            confirmed => ($a->{confirmed} && $b->{confirmed}) ? 1 : 0,
        };
    }
    $self->{segments} = \@seg;

    # ── Tramo tentativo: del último pivote CONFIRMADO al precio actual ────
    my ($last_conf) = grep { $_->{confirmed} } reverse @$proj;
    if ($last_conf) {
        my $cur_price = $ltf->[-1]{close};
        my $cur_index = $#$ltf;   # local; se convierte a global en _offset_indices
        $self->{tentative} = {
            from => { index => $last_conf->{index}, price => $last_conf->{price} },
            to   => { index => $cur_index,          price => $cur_price },
            dir  => ($cur_price >= $last_conf->{price}) ? 'up' : 'down',
        };
    }

    # ── Fibonacci del último leg (calculado siempre; se dibuja solo si
    #    show_fib está activo — off por default según PDF) ─────────────────
    if (@$proj >= 2) {
        my ($p1, $p2) = ($proj->[-2], $proj->[-1]);
        my $range = $p2->{price} - $p1->{price};
        if ($range != 0) {
            my @lv;
            for my $l (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1) {
                push @lv, { level => $l, price => $p2->{price} - $range * $l };
            }
            $self->{fib} = { from => $p1, to => $p2, levels => \@lv };
        }
    }

    # ── Windowing (Replay): índices locales -> globales ───────────────────
    my $base = $md->can('base_index') ? $md->base_index : 0;
    $self->_offset_indices($base) if $base;
}

# ─────────────────────────────────────────────────────────────────────────────
# _zigzag — detecta pivotes alternados (high/low) sobre el TF de referencia con
# una ventana 'depth' a cada lado. En rachas del mismo tipo conserva el extremo.
# ─────────────────────────────────────────────────────────────────────────────
sub _zigzag {
    my ($self, $c, $depth) = @_;
    my $n = scalar @$c;
    return [] if $n < 2 * $depth + 1;

    my @cand;
    for my $i ($depth .. $n - 1 - $depth) {
        my ($is_high, $is_low) = (1, 1);
        for my $k (1 .. $depth) {
            $is_high = 0 unless $c->[$i]{high} >  $c->[$i - $k]{high}
                             && $c->[$i]{high} >= $c->[$i + $k]{high};
            $is_low  = 0 unless $c->[$i]{low}  <  $c->[$i - $k]{low}
                             && $c->[$i]{low}  <= $c->[$i + $k]{low};
        }
        push @cand, { idx => $i, price => $c->[$i]{high}, type => 'high' } if $is_high;
        push @cand, { idx => $i, price => $c->[$i]{low},  type => 'low'  } if $is_low;
    }

    @cand = sort { $a->{idx} <=> $b->{idx} } @cand;

    # Forzar alternancia estricta high/low
    my @z;
    for my $p (@cand) {
        if (!@z) { push @z, $p; next; }
        my $last = $z[-1];
        if ($last->{type} eq $p->{type}) {
            if ($p->{type} eq 'high') { $z[-1] = $p if $p->{price} > $last->{price}; }
            else                      { $z[-1] = $p if $p->{price} < $last->{price}; }
        } else {
            push @z, $p;
        }
    }
    return \@z;
}

# ─────────────────────────────────────────────────────────────────────────────
# _label — asigna HH/HL/LH/LL comparando cada pivote con el previo del mismo tipo.
# ─────────────────────────────────────────────────────────────────────────────
sub _label {
    my ($self, $piv) = @_;
    my ($last_high, $last_low);
    for my $p (@$piv) {
        if ($p->{type} eq 'high') {
            $p->{label} = defined $last_high ? ($p->{price} > $last_high ? 'HH' : 'LH') : 'HH';
            $last_high = $p->{price};
        } else {
            $p->{label} = defined $last_low ? ($p->{price} < $last_low ? 'LL' : 'HL') : 'LL';
            $last_low = $p->{price};
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _project — mapea cada pivote del TF de referencia al índice 1m equivalente.
# Dentro del bucket busca la vela 1m con el extremo real (high/low) para que el
# zigzag toque el precio correcto; si el bucket cae fuera de la ventana 1m,
# usa búsqueda binaria por epoch.
# ─────────────────────────────────────────────────────────────────────────────
sub _project {
    my ($self, $piv, $closed, $ltf, $sec) = @_;
    my $n = scalar @$ltf;
    my $first_e = $ltf->[0]{epoch};
    my $last_e  = $ltf->[-1]{epoch};

    my @out;
    my $prev_idx = -1;   # para garantizar avance monótono (un zigzag no retrocede)
    for my $p (@$piv) {
        my $E = $closed->[$p->{idx}]{epoch};
        my $idx1m;
        if ($E + $sec <= $first_e || $E > $last_e) {
            $idx1m = _bsearch_epoch($ltf, $E);
        } else {
            # Primera vela 1m del bucket: primer índice con epoch >= E
            # (bsearch da epoch <= E; avanzamos si cayó en el bucket anterior,
            #  cosa que ocurre cuando faltan los primeros minutos del bucket).
            my $lo = _bsearch_epoch($ltf, $E);
            $lo++ while $lo < $n - 1 && $ltf->[$lo]{epoch} < $E;

            my $best = $lo;
            my $found = 0;
            for (my $j = $lo; $j < $n && $ltf->[$j]{epoch} < $E + $sec; $j++) {
                next if $ltf->[$j]{epoch} < $E;   # seguridad ante gaps
                if (!$found) { $best = $j; $found = 1; next; }
                if ($p->{type} eq 'high') {
                    $best = $j if $ltf->[$j]{high} > $ltf->[$best]{high};
                } else {
                    $best = $j if $ltf->[$j]{low} < $ltf->[$best]{low};
                }
            }
            $idx1m = $best;
        }

        # Monotonicidad: el zigzag debe avanzar en el tiempo. Si por gaps un
        # pivote proyecta a un índice <= al anterior, lo empujamos hacia adelante.
        $idx1m = $prev_idx + 1 if $idx1m <= $prev_idx;
        $idx1m = $n - 1 if $idx1m > $n - 1;
        $prev_idx = $idx1m;

        push @out, {
            index     => $idx1m,
            price     => $p->{price},
            label     => $p->{label},
            type      => $p->{type},
            confirmed => $p->{confirmed},
        };
    }
    return \@out;
}

# Índice local de la vela 1m con epoch <= $E más grande (clamp a [0, n-1]).
sub _bsearch_epoch {
    my ($ltf, $E) = @_;
    my ($lo, $hi) = (0, $#$ltf);
    return 0 if $E <= $ltf->[0]{epoch};
    return $hi if $E >= $ltf->[$hi]{epoch};
    while ($lo < $hi) {
        my $mid = int(($lo + $hi + 1) / 2);
        if ($ltf->[$mid]{epoch} <= $E) { $lo = $mid; } else { $hi = $mid - 1; }
    }
    return $lo;
}

# ─────────────────────────────────────────────────────────────────────────────
# _offset_indices — convierte índices 1m locales -> globales tras cálculo por
# ventana (WindowProxy en Replay). Mismo patrón que SMC_Structures/Liquidity.
# fib->{from,to} son referencias a objetos de {pivots}, ya offseteados en el
# bucle de pivots; NO se vuelven a offsetear.
# ─────────────────────────────────────────────────────────────────────────────
sub _offset_indices {
    my ($self, $base) = @_;
    return if !$base;

    $_->{index} += $base for @{ $self->{pivots} };

    for my $s (@{ $self->{segments} }) {
        $s->{from}{index} += $base;
        $s->{to}{index}   += $base;
    }
    if (my $t = $self->{tentative}) {
        $t->{from}{index} += $base;
        $t->{to}{index}   += $base;
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Consultas usadas por el Overlay (índices globales). Baratas: filtran arrays
# ya calculados por el rango visible.
# ─────────────────────────────────────────────────────────────────────────────
sub segments_in_range {
    my ($self, $start, $end) = @_;
    return [ grep { $_->{from}{index} <= $end && $_->{to}{index} >= $start }
             @{ $self->{segments} } ];
}

sub pivots_in_range {
    my ($self, $start, $end) = @_;
    return [ grep { $_->{index} >= $start && $_->{index} <= $end }
             @{ $self->{pivots} } ];
}

sub tentative_segment { return $_[0]->{tentative}; }
sub fib_levels        { return $_[0]->{fib}; }

1;
