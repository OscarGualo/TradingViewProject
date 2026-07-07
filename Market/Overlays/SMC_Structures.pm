package Market::Overlays::SMC_Structures;
use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Overlays::SMC_Structures
#
# Según la arquitectura del PDF (Tabla 1):
#   "Renderizado gráfico en el Canvas de Perl/Tk de las estructuras de
#    mercado unificadas."
#
# Responsabilidad EXCLUSIVA de este archivo: dibujar en el canvas lo que
# Market::Indicators::SMC_Structures ya calculó. No calcula nada — toda la
# lógica de detección vive en el Indicator (separación estricta Indicators
# vs Overlays que exige la Tabla 1).
#
# PUNTO 3.5 — Dibuja:
#   - Etiquetas HH / HL / LH / LL sobre cada Swing Point
#   - Marcadores BOS / CHoCH con distinción internal (sólido) / external (punteado)
#   - Rectángulos FVG con desvanecimiento progresivo de opacidad
#   - Niveles de Fibonacci Retracement entre el último Swing High y Low relevantes
#
# Convención de uso (idéntica a Market::Panels::PricePanel):
#   $overlay->draw($canvas, $smc_indicator, $x_of, $state)
# donde $state es el mismo hashref de contexto que ya usa PricePanel/ATRPanel,
# con price_min/price_max ya resueltos por el momento en que se llama.
#
# Compatible con Replay: el ChartEngine siempre llama a este overlay con
# $start/$end ya recortados por _replay_limit(), así que basta con pedir
# swings/eventos/fvgs "in_range(start,end)" — nunca se dibuja nada fuera
# de ese rango, sea cual sea el origen del límite (normal o replay).
# ═════════════════════════════════════════════════════════════════════════════

# Colores según convención SMC estándar (igual familia visual que TradingView/LuxAlgo)
my %SWING_COLOR = (
    HH => '#26a69a',  # verde — continuación alcista
    HL => '#26a69a',
    LH => '#ef5350',  # rojo — continuación bajista
    LL => '#ef5350',
);

my %EVENT_COLOR = (
    up   => '#26a69a',
    down => '#ef5350',
);

my %FVG_COLOR = (
    up   => '#26a69a',
    down => '#ef5350',
);

# Número de velas tras las cuales un FVG llega a opacidad mínima (visual).
# El indicador no sabe nada de esto — es puramente decisión del overlay.
my $FVG_FADE_WINDOW = 50;

sub new {
    my ($class, %args) = @_;
    my $self = {
        scale => Market::Panels::Scales->new(),
        # Visibilidad individual — todos desactivados al arrancar.
        # El usuario activa los que necesita desde el menú Overlays.
        # Esto evita dibujar miles de elementos en el primer frame y
        # mejora significativamente el tiempo de arranque y el draw().
        visible => {
            swings => 0,
            bos    => 0,
            choch  => 0,
            fvg    => 0,
            fib    => 0,
            ob     => 0,   # Order Blocks
            sr     => 0,   # Support / Resistance
            trend  => 0,   # Trendlines / Channels
        },
    };
    bless $self, $class;
    return $self;
}

# Toggle de visibilidad individual — usado por los checkbuttons del menú.
sub set_visible {
    my ($self, $key, $value) = @_;
    $self->{visible}{$key} = $value ? 1 : 0;
}

sub is_visible {
    my ($self, $key) = @_;
    return $self->{visible}{$key};
}

# ─────────────────────────────────────────────────────────────────────────────
# draw — punto de entrada principal, llamado desde ChartEngine::draw()
#
# $smc    : objeto Market::Indicators::SMC_Structures ya calculado
# $x_of   : closure índice local -> coordenada X (misma que usa PricePanel)
# $state  : hashref de contexto (price_min, price_max, top, price_h, etc.)
# ─────────────────────────────────────────────────────────────────────────────
sub draw {
    my ($self, $canvas, $smc, $x_of, $state) = @_;
    return unless defined $smc;

    my $start = $state->{start_index};
    my $end   = $state->{end_index};
    my $min   = $state->{price_min};
    my $max   = $state->{price_max};
    my $top   = $state->{top};
    my $h     = $state->{price_h};   # FIX: igual que PricePanel — incluye zona de volumen

    return unless defined $min && defined $max;

    $self->_draw_fvgs($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{fvg};

    $self->_draw_swings($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{swings};

    $self->_draw_events($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{bos} || $self->{visible}{choch};

    $self->_draw_fibonacci($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{fib};

    $self->_draw_order_blocks($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{ob};

    $self->_draw_support_resistance($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{sr};

    $self->_draw_trendlines($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{trend};
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_swings — etiquetas HH/HL/LH/LL sobre cada Swing Point visible.
# Se dibujan primero los FVG (capa de fondo) para que las etiquetas queden
# siempre legibles encima.
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_swings {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    # Estilo LuxAlgo SMC (imágenes 3, 4, 5 de referencia):
    #   - Pequeña línea vertical desde la punta de la mecha (5px)
    #   - Etiqueta del label (HH/HL/LH/LL) justo encima/debajo de esa línea
    #   - Colores: verde para HH/HL (alcista), rojo/cyan para LH/LL (bajista)
    #   - Solo sobre la mecha: high para swing highs, low para swing lows
    my $swings = $smc->swings_in_range($start, $end);
    for my $sw (@$swings) {
        my $x = $x_of->($sw->{index} - $start);
        my $y = $self->{scale}->price_to_y($sw->{price}, $min, $max, $top, $h);
        next if $y < $top || $y > $top + $h;

        my $color = $SWING_COLOR{ $sw->{label} } // '#787b86';
        my $is_high = ($sw->{type} eq 'high');

        # Pequeña línea vertical: desde la punta de la mecha hacia afuera (5px)
        my $line_y1 = $is_high ? ($y - 5) : ($y + 5);
        my $line_y2 = $is_high ? ($y - 1) : ($y + 1);
        $canvas->createLine($x, $line_y1, $x, $line_y2,
            -fill  => $color,
            -width => 1,
            -tags  => 'smc_swing',
        );

        # Etiqueta: 8px más allá de la línea (encima para highs, debajo para lows)
        my $label_y = $is_high ? ($y - 14) : ($y + 14);
        $canvas->createText($x, $label_y,
            -text   => $sw->{label},
            -anchor => 'center',
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -tags   => 'smc_swing',
        );
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_events — marcadores BOS y CHoCH.
# internal: línea sólida corta + etiqueta. external: línea punteada + etiqueta
# con sufijo, distinción visual exigida por la jerarquía multi-temporal del PDF.
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_events {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    # Colores: alcista=verde, bajista=rojo. CHoCH más saturado.
    my %BOS_COLOR   = (up => '#26a69a', down => '#ef5350');
    my %CHOCH_COLOR = (up => '#26a69a', down => '#ef5350');
    my $right = $state->{right} // $x_of->($end - $start);

    # ── Agrupar eventos por vela para detectar CHoCH+BOS simultáneos ────────
    # Cuando CHoCH y BOS ocurren en la misma vela con el mismo nivel y
    # dirección, se muestran con la etiqueta "CHoCH BOS" en la misma línea
    # (comportamiento de TradingView / LuxAlgo, imagen 6 de referencia).
    my %by_candle;
    my $events = $smc->events_in_range($start, $end);
    for my $ev (@$events) {
        push @{ $by_candle{ $ev->{index} } }, $ev;
    }

    for my $idx (sort { $a <=> $b } keys %by_candle) {
        my @evs = @{ $by_candle{$idx} };

        # Filtrar por visibilidad
        @evs = grep {
            ($_->{type} eq 'BOS'   && $self->{visible}{bos})   ||
            ($_->{type} eq 'CHoCH' && $self->{visible}{choch})
        } @evs;
        next unless @evs;

        # Agrupar por nivel+dirección para fusionar CHoCH+BOS del mismo nivel
        my %groups;
        for my $ev (@evs) {
            my $key = sprintf("%.2f_%s", $ev->{level_price}, $ev->{direction});
            push @{ $groups{$key} }, $ev;
        }

        for my $key (keys %groups) {
            my @grp = @{ $groups{$key} };
            my $ev  = $grp[0];   # tomar el primero como referencia

            # Determinar si hay CHoCH en este grupo
            my $has_choch = grep { $_->{type} eq 'CHoCH' } @grp;
            my $has_bos   = grep { $_->{type} eq 'BOS'   } @grp;

            my $color = ($ev->{direction} eq 'up')
                      ? $BOS_COLOR{up} : $BOS_COLOR{down};

            # Etiqueta: "CHoCH", "BOS", o "CHoCH BOS" si coexisten
            my $label = $has_choch && $has_bos ? 'CHoCH  BOS'
                      : $has_choch             ? 'CHoCH'
                      :                          'BOS';

            # ── Línea horizontal ─────────────────────────────────────────────
            # Estilo: sólido para externo (estructura mayor), dashed para interno
            my $is_ext = ($ev->{scope} eq 'external');
            my $y = $self->{scale}->price_to_y($ev->{level_price}, $min, $max, $top, $h);
            next if $y < $top || $y > $top + $h;

            # X inicio: el swing roto (level_index)
            my $x1 = ($ev->{level_index} >= $start)
                   ? $x_of->($ev->{level_index} - $start)
                   : $x_of->(0);

            # X fin: la vela que confirma la ruptura
            my $x2 = ($ev->{index} <= $end)
                   ? $x_of->($ev->{index} - $start)
                   : $right;

            my @line_args = (
                -fill  => $color,
                -width => $is_ext ? 2 : 1,
                -tags  => 'smc_event',
            );
            push @line_args, (-dash => [4, 3]) unless $is_ext;

            $canvas->createLine($x1, $y, $x2, $y, @line_args);

            # ── Etiqueta al centro del segmento ──────────────────────────────
            my $label_x = ($x1 + $x2) / 2;
            my $label_y = ($ev->{direction} eq 'up') ? ($y - 9) : ($y + 9);
            $canvas->createText($label_x, $label_y,
                -text   => $label,
                -fill   => $color,
                -anchor => 'center',
                -font   => ['Arial', 7, ($has_choch ? 'bold italic' : 'bold')],
                -tags   => 'smc_event',
            );
        }
    }
}


sub _draw_order_blocks {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    for my $ob (@{ $smc->order_blocks_in_range($start, $end) }) {
        my $i1 = $ob->{index};
        my $i2 = defined $ob->{mitigated_at} ? $ob->{mitigated_at} : $end;
        $i1 = $start if $i1 < $start;
        $i2 = $end   if $i2 > $end;

        my $x1 = $x_of->($i1 - $start);
        my $x2 = $x_of->($i2 - $start);
        my $y_top = $self->{scale}->price_to_y($ob->{top},    $min, $max, $top, $h);
        my $y_bot = $self->{scale}->price_to_y($ob->{bottom}, $min, $max, $top, $h);

        # Recorte vertical: si el bloque queda totalmente fuera del panel, saltar.
        next if $y_bot < $top || $y_top > $top + $h;

        my $color = ($ob->{direction} eq 'bullish') ? '#26a69a' : '#ef5350';

        $canvas->createRectangle($x1, $y_top, $x2, $y_bot,
            -fill    => $color,
            -stipple => 'gray12',        # semitransparencia (Tk no tiene alpha real)
            -outline => $color,
            -width   => 1,
            -tags    => 'smc_ob',
        );
        $canvas->createText($x1 + 3, $y_top + 7,
            -anchor => 'w',
            -text   => 'OB',
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -tags   => 'smc_ob',
        );
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_support_resistance — "Support/Resistence: below support or above
# resistance levels" (cronograma 29/06)
#
# Cada nivel se dibuja como una línea horizontal punteada extendida desde su
# primer toque hasta el borde derecho visible. Resistencia = rojo con etiqueta
# "R"; Soporte = verde con etiqueta "S".
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_support_resistance {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    my $right = $state->{right} // $x_of->($end - $start);

    for my $lvl (@{ $smc->support_resistance_in_range($start, $end) }) {
        my $y = $self->{scale}->price_to_y($lvl->{price}, $min, $max, $top, $h);
        next if $y < $top || $y > $top + $h;

        my $is_res = ($lvl->{kind} eq 'resistance');
        my $color  = $is_res ? '#ef5350' : '#26a69a';

        my $fi = $lvl->{first_index} < $start ? $start : $lvl->{first_index};
        my $x1 = $x_of->($fi - $start);

        $canvas->createLine($x1, $y, $right, $y,
            -fill  => $color,
            -dash  => [2, 2],
            -width => 1,
            -tags  => 'smc_sr',
        );
        $canvas->createText($x1 + 4, $y - 6,
            -anchor => 'w',
            -text   => $is_res ? 'R' : 'S',
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -tags   => 'smc_sr',
        );
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_trendlines — "Trendlines/Channels: below or above" (cronograma 29/06)
#
# Cada trendline conecta dos swings consecutivos del mismo tipo. Se dibuja el
# segmento y se EXTIENDE hacia adelante usando slope/intercept hasta el borde
# visible. Resistencia (highs) = rojo; Soporte (lows) = verde.
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_trendlines {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    for my $tl (@{ $smc->trendlines_in_range($start, $end) }) {
        my $i1 = $tl->{point1}{index};
        my $i2 = $end;                       # extender el canal hacia adelante
        $i1 = $start if $i1 < $start;

        my $p1 = $tl->{slope} * $i1 + $tl->{intercept};
        my $p2 = $tl->{slope} * $i2 + $tl->{intercept};

        my $x1 = $x_of->($i1 - $start);
        my $x2 = $x_of->($i2 - $start);
        my $y1 = $self->{scale}->price_to_y($p1, $min, $max, $top, $h);
        my $y2 = $self->{scale}->price_to_y($p2, $min, $max, $top, $h);

        next if ($y1 < $top && $y2 < $top) || ($y1 > $top + $h && $y2 > $top + $h);

        my $color = ($tl->{kind} eq 'resistance') ? '#ef5350' : '#26a69a';

        $canvas->createLine($x1, $y1, $x2, $y2,
            -fill  => $color,
            -width => 1,
            -tags  => 'smc_trend',
        );
    }
}

1;
