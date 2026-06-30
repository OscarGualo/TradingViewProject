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
    my $h     = $state->{price_h} - ($state->{vol_h} // 0);

    return unless defined $min && defined $max;

    $self->_draw_fvgs($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{fvg};

    $self->_draw_swings($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{swings};

    $self->_draw_events($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{bos} || $self->{visible}{choch};

    $self->_draw_fibonacci($canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h)
        if $self->{visible}{fib};
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_swings — etiquetas HH/HL/LH/LL sobre cada Swing Point visible.
# Se dibujan primero los FVG (capa de fondo) para que las etiquetas queden
# siempre legibles encima.
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_swings {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    my $swings = $smc->swings_in_range($start, $end);
    for my $sw (@$swings) {
        my $local_i = $sw->{index} - $start;
        my $x = $x_of->($local_i);
        my $y = $self->{scale}->price_to_y($sw->{price}, $min, $max, $top, $h);

        my $color = $SWING_COLOR{ $sw->{label} } // '#787b86';
        # Los swing highs se etiquetan ARRIBA del precio, los lows ABAJO,
        # para no tapar la mecha de la vela.
        my $label_y = ($sw->{type} eq 'high') ? ($y - 12) : ($y + 12);

        $canvas->createText($x, $label_y,
            -text => $sw->{label},
            -fill => $color,
            -font => ['Arial', 8, 'bold'],
            -tags => 'smc_swing',
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

    my $events = $smc->events_in_range($start, $end);
    for my $ev (@$events) {
        next if $ev->{type} eq 'BOS'   && !$self->{visible}{bos};
        next if $ev->{type} eq 'CHoCH' && !$self->{visible}{choch};

        # Línea horizontal corta entre el nivel roto y la vela de confirmación
        my $level_local = $ev->{level_index} - $start;
        my $event_local = $ev->{index} - $start;
        my $x1 = $x_of->($level_local);
        my $x2 = $x_of->($event_local);
        my $y  = $self->{scale}->price_to_y($ev->{level_price}, $min, $max, $top, $h);

        my $color = $EVENT_COLOR{ $ev->{direction} } // '#787b86';
        my $dash  = ($ev->{scope} eq 'external') ? [4, 2] : undef;

        my @line_args = (
            -fill => $color,
            -width => 1,
            -tags  => 'smc_event',
        );
        push @line_args, (-dash => $dash) if defined $dash;

        $canvas->createLine($x1, $y, $x2, $y, @line_args);

        # Etiqueta de texto: "BOS" / "CHoCH", con sufijo si es external
        my $label = $ev->{type};
        $label .= ' (ext)' if $ev->{scope} eq 'external';

        my $label_y = ($ev->{direction} eq 'up') ? ($y - 10) : ($y + 10);
        $canvas->createText($x2, $label_y,
            -text => $label,
            -fill => $color,
            -font => ['Arial', 8, ($ev->{type} eq 'CHoCH' ? 'bold italic' : 'bold')],
            -tags => 'smc_event',
        );
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_fvgs — rectángulos de Fair Value Gap con desvanecimiento progresivo.
#
# La opacidad NO existe como concepto nativo en Tk::Canvas (no hay alpha
# real), así que el desvanecimiento se simula con la técnica estándar de
# Tk: el parámetro -stipple con distintas densidades de patrón. A mayor
# antigüedad del FVG, mayor "vacío" en el patrón (stipple más disperso),
# dando la sensación visual de transparencia creciente.
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_fvgs {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    my $fvgs = $smc->fvgs_in_range($start, $end);
    my $current_index = $end;   # vela más reciente visible = referencia de "ahora"

    for my $f (@$fvgs) {
        my $x1_local = $f->{index} - $start;
        my $x1 = $x_of->($x1_local);

        # El rectángulo se extiende desde la formación hasta la mitigación
        # (o hasta el borde visible si sigue activo).
        my $end_index = defined $f->{mitigated_at} ? $f->{mitigated_at} : $end;
        $end_index = $end if $end_index > $end;
        my $x2_local = $end_index - $start;
        my $x2 = $x_of->($x2_local);

        next if $x2 < $x1;   # fuera de rango visible

        my $y1 = $self->{scale}->price_to_y($f->{top},    $min, $max, $top, $h);
        my $y2 = $self->{scale}->price_to_y($f->{bottom}, $min, $max, $top, $h);

        my $color = $FVG_COLOR{ $f->{direction} } // '#787b86';

        # Desvanecimiento: cuántas velas han pasado desde la formación,
        # relativo a la vela "actual" del gráfico (current_index).
        my $age = $current_index - $f->{index};
        $age = 0 if $age < 0;
        my $stipple = _stipple_for_age($age, $FVG_FADE_WINDOW, $f->{mitigated_at});

        my %rect_args = (
            -fill    => $color,
            -outline => '',
            -tags    => 'smc_fvg',
        );
        $rect_args{-stipple} = $stipple if defined $stipple;

        $canvas->createRectangle($x1, $y1, $x2, $y2, %rect_args);
    }
}

# Selecciona el patrón -stipple según la edad del FVG, simulando
# desvanecimiento progresivo. FVG mitigados siempre usan el patrón más
# disperso (casi invisible) independientemente de la edad, porque ya
# dejaron de ser una "zona de alta reacción" relevante.
sub _stipple_for_age {
    my ($age, $fade_window, $mitigated_at) = @_;

    return 'gray12' if defined $mitigated_at;   # mitigado: casi invisible

    my $ratio = $age / $fade_window;
    return 'gray75' if $ratio < 0.15;   # recién formado: más sólido
    return 'gray50' if $ratio < 0.40;
    return 'gray25' if $ratio < 0.75;
    return 'gray12';                    # viejo: casi invisible
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_fibonacci — niveles de Fibonacci Retracement entre el último
# Swing High y el último Swing Low relevantes dentro del rango visible.
#
# PDF 4: el documento exige "niveles de Fibonacci" como parte del cálculo
# de SMC_Structures.pm. Se trazan los 7 niveles estándar entre el pivote
# más reciente (Swing High o Low, el que sea más reciente cronológicamente)
# y su contraparte inmediatamente anterior.
# ─────────────────────────────────────────────────────────────────────────────
my @FIB_LEVELS = (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1);

sub _draw_fibonacci {
    my ($self, $canvas, $smc, $x_of, $state, $start, $end, $min, $max, $top, $h) = @_;

    # Encontrar el swing más reciente <= end (el "ancla" del retroceso)
    my $last_high = $smc->last_swing_high_before($end);
    my $last_low  = $smc->last_swing_low_before($end);
    return unless defined $last_high && defined $last_low;

    # El pivote más reciente cronológicamente es el punto de inicio del
    # retroceso; el otro es el punto final.
    my ($from, $to) = ($last_high->{index} > $last_low->{index})
        ? ($last_low, $last_high)   # low antes, high es el más reciente -> retroceso bajista
        : ($last_high, $last_low);  # high antes, low es el más reciente -> retroceso alcista

    my $price_from = $from->{price};
    my $price_to   = $to->{price};
    my $range      = $price_to - $price_from;
    return if $range == 0;

    my $x_left  = $x_of->(0);
    my $x_right = $state->{right} // $x_of->($end - $start);

    for my $level (@FIB_LEVELS) {
        my $price = $price_to - ($range * $level);
        my $y = $self->{scale}->price_to_y($price, $min, $max, $top, $h);
        next if $y < $top || $y > $top + $h;

        $canvas->createLine($x_left, $y, $x_right, $y,
            -fill  => '#9c8a5c',
            -width => 1,
            -dash  => [2, 4],
            -tags  => 'smc_fib',
        );
        $canvas->createText($x_right - 4, $y - 8,
            -anchor => 'e',
            -text   => sprintf('%.1f%% (%.2f)', $level * 100, $price),
            -fill   => '#9c8a5c',
            -font   => ['Arial', 7],
            -tags   => 'smc_fib',
        );
    }
}

1;
