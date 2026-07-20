package Market::Overlays::Liquidity;
use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Overlays::Liquidity
#
# Según la arquitectura del PDF (Tabla 1):
#   "Gestión del dibujado de líneas de liquidez, velas de liquidez, etiquetas
#    dinámicas y control de visibilidad interactivo que se desarrollan con
#    el replay."
#
# Responsabilidad EXCLUSIVA de este archivo: renderizar lo que
# Market::Indicators::Liquidity ya calculó. Cero lógica de detección aquí.
#
# PUNTO 3.5 — Implementa la Tabla 2 del PDF al pie de la letra:
#
#   Elemento  Estilo                          Color   Etiqueta
#   BSL       Horizontal discontinua/punteada Rojo    "BSL"
#   SSL       Horizontal discontinua/punteada Verde   "SSL"
#   EQH       Línea que conecta ambos máximos Config. "EQH"
#   EQL       Línea que conecta ambos mínimos Config. "EQL"
#   Sweep Up  Marcador/línea de quiebre        Rojo    "SWEEP ↑" (ASCII: "SWEEP UP")
#   Sweep Dn  Marcador/línea de quiebre        Verde   "SWEEP ↓" (ASCII: "SWEEP DOWN")
#   Liq.Grab  Destacado de rechazo rápido      Naranja "LQ GRAB"
#   Liq.Run   Extensión de ruptura de nivel    Azul    "LQ RUN"
#
# Control de visibilidad individual desde el menú "Overlays" del
# ChartEngine (3.5-B), igual patrón que Overlays::SMC_Structures.
#
# Compatible con Replay: igual que el resto del sistema — el ChartEngine
# siempre llama con $start/$end ya acotados por _replay_limit().
# ═════════════════════════════════════════════════════════════════════════════

# Colores EXACTOS de la Tabla 2 del PDF
my $COLOR_BSL   = '#f23645';   # Rojo
my $COLOR_SSL   = '#089981';   # Verde
my $COLOR_EQH   = '#f23645';   # Rojo  (LuxAlgo swingBearishColor) — techos iguales
my $COLOR_EQL   = '#089981';   # Verde (LuxAlgo swingBullishColor) — pisos iguales
my $COLOR_SWEEP_UP   = '#f23645';   # Rojo (Tabla 2: Sweep Up)
my $COLOR_SWEEP_DOWN = '#089981';   # Verde (Tabla 2: Sweep Down)
my $COLOR_GRAB  = '#f59e0b';   # Naranja
my $COLOR_RUN   = '#2962ff';   # Azul

# Cantidad máxima de niveles VIVOS por tipo (BSL/SSL/EQH/EQL) que se dibujan,
# de más reciente a más antiguo. Mantiene el gráfico limpio como LuxAlgo.
our $LIQ_MAX_RECENT = 8;

sub new {
    my ($class, %args) = @_;
    my $self = {
        scale => Market::Panels::Scales->new(),
        # Todos desactivados al arrancar — el usuario activa desde el menú.
        visible => {
            bsl   => 0,
            ssl   => 0,
            eqh   => 0,
            eql   => 0,
            sweep => 0,
            grab  => 0,
            run   => 0,
            # PDF 4.4: cuando está ON, oculta los niveles NO institucionales
            # (bajo volumen = ruido). El peso visual (grosor) se aplica siempre.
            institutional_only => 0,
        },
    };
    bless $self, $class;
    return $self;
}

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
# $liq    : objeto Market::Indicators::Liquidity ya calculado
# $x_of   : closure índice local -> coordenada X
# $state  : hashref de contexto (price_min, price_max, top, price_h, etc.)
# ─────────────────────────────────────────────────────────────────────────────
sub draw {
    my ($self, $canvas, $liq, $x_of, $state) = @_;
    return unless defined $liq;

    my $start = $state->{start_index};
    my $end   = $state->{end_index};
    my $min   = $state->{price_min};
    my $max   = $state->{price_max};
    my $top   = $state->{top};
    my $h     = $state->{price_h} - ($state->{vol_h} // 0);
    my $right = $state->{right};

    return unless defined $min && defined $max;

    my $levels = $liq->levels_in_range($start, $end);
    my @drawn_labels;   # [ [x,y], ... ] etiquetas ya dibujadas (anti-solape)

    # ── BSL/SSL: concepto propio (no LuxAlgo), muy ruidoso (~9000 de cada uno).
    #    Se ocultan los BARRIDOS y se capan a los N más recientes VIVOS por tipo.
    my %live;
    for my $lv (@$levels) {
        my $k = $lv->{kind};
        next unless $k eq 'BSL' || $k eq 'SSL';
        next if defined $lv->{swept_at} && $lv->{swept_at} <= $end;   # consumido
        push @{ $live{$k} }, $lv;
    }
    for my $k (qw(BSL SSL)) {
        next unless $self->{visible}{ lc $k };
        my @lst = sort { $b->{index} <=> $a->{index} } @{ $live{$k} // [] };
        # PDF 4.4: filtro institucional (oculta niveles de bajo volumen = ruido).
        @lst = grep { $_->{institutional} } @lst if $self->{visible}{institutional_only};
        @lst = @lst[0 .. $LIQ_MAX_RECENT - 1] if @lst > $LIQ_MAX_RECENT;
        $self->_draw_bsl_ssl($canvas, $_, $x_of, $start, $end, $min, $max, $top, $h, $right, \@drawn_labels)
            for @lst;
    }

    # ── EQH/EQL: como LuxAlgo — objetos PERSISTENTES. Se dibujan todos los que
    #    intersectan el viewport por SEGMENTO (pair_index..index), sin filtro de
    #    barrido y sin cap, de modo que se mantienen con cualquier zoom (el
    #    filtro por 'index' de levels_in_range los hacía desaparecer al alejar
    #    el 2º pivote de pantalla). El anti-solape evita amontonar etiquetas.
    if ($self->{visible}{eqh} || $self->{visible}{eql}) {
        for my $lv (@{ $liq->eq_levels() }) {
            next unless ($lv->{kind} eq 'EQH' && $self->{visible}{eqh})
                     || ($lv->{kind} eq 'EQL' && $self->{visible}{eql});
            next if $self->{visible}{institutional_only} && !$lv->{institutional};   # PDF 4.4
            my $lo = defined $lv->{pair_index} ? $lv->{pair_index} : $lv->{index};
            next unless $lo <= $end && $lv->{index} >= $start;   # segmento visible
            $self->_draw_eq($canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h, \@drawn_labels, $state->{candles});
        }
    }

    # Marcadores de resolución (Sweep/Grab/Run) — independientes del kind del
    # nivel; ya son escasos (sólo niveles Resolved) así que se dibujan todos.
    for my $lv (@$levels) {
        next unless $lv->{state} eq 'Resolved' && defined $lv->{classification};
        next if $self->{visible}{institutional_only} && !$lv->{institutional};   # PDF 4.4

        if ($lv->{classification} eq 'Sweep' && $self->{visible}{sweep}) {
            $self->_draw_sweep_marker($canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h);
        } elsif ($lv->{classification} eq 'Grab' && $self->{visible}{grab}) {
            $self->_draw_grab_marker($canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h);
        } elsif ($lv->{classification} eq 'Run' && $self->{visible}{run}) {
            $self->_draw_run_marker($canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h);
        }
    }
}

# Anti-solape: true (y registra la posición) si la etiqueta en ($x,$y) no está
# demasiado cerca de otra ya dibujada. Evita el amontonamiento "EQHEQL/BSLBSL".
sub _label_ok {
    my ($drawn, $x, $y) = @_;
    for my $p (@$drawn) {
        return 0 if abs($p->[0] - $x) < 26 && abs($p->[1] - $y) < 9;
    }
    push @$drawn, [ $x, $y ];
    return 1;
}

# Extremo RENDERIZADO del píxel que contiene al pivote global $gi: max high
# (is_high) / min low, sobre las velas del slice que caen en el mismo bucket de
# píxel que el pivote — igual criterio que PricePanel::_build_pixel_groups
# (bucket = int(x+0.5)). Así EQH/EQL se anclan a la mecha que realmente se
# dibuja a cualquier zoom. Devuelve undef si el pivote está fuera del slice.
sub _rendered_extreme {
    my ($candles, $cstart, $x_of, $gi, $is_high) = @_;
    return undef unless $candles;
    my $li = $gi - $cstart;
    return undef if $li < 0 || $li > $#$candles;
    my $bucket = int($x_of->($li) + 0.5);
    my $ext = $is_high ? $candles->[$li]{high} : $candles->[$li]{low};
    for my $dir (-1, 1) {
        my $j = $li;
        while (1) {
            $j += $dir;
            last if $j < 0 || $j > $#$candles;
            last if int($x_of->($j) + 0.5) != $bucket;
            my $v = $is_high ? $candles->[$j]{high} : $candles->[$j]{low};
            $ext = $v if ($is_high ? $v > $ext : $v < $ext);
        }
    }
    return $ext;
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_bsl_ssl — línea horizontal discontinua/punteada (Tabla 2).
# BSL en rojo, SSL en verde. Se extiende desde el índice de detección
# hasta donde el nivel sigue "vivo" (swept_at si fue barrido, o el borde
# visible si nunca se barrió).
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_bsl_ssl {
    my ($self, $canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h, $right, $drawn) = @_;

    my $is_bsl = ($lv->{kind} eq 'BSL');
    my $color  = $is_bsl ? $COLOR_BSL : $COLOR_SSL;
    my $label  = $is_bsl ? 'BSL' : 'SSL';

    my $x1_local = $lv->{index} - $start;
    my $x1 = $x_of->($x1_local);

    my $end_index = defined $lv->{swept_at} ? $lv->{swept_at} : $end;
    $end_index = $end if $end_index > $end;
    my $x2_local = $end_index - $start;
    my $x2 = $x_of->($x2_local);

    return if $x2 < $x1;

    my $y = $self->{scale}->price_to_y($lv->{price}, $min, $max, $top, $h);
    return if $y < $top || $y > $top + $h;

    # PDF 4.4: peso visual — nivel institucional (alto volumen) más grueso.
    my $lw = (defined $lv->{institutional} && !$lv->{institutional}) ? 1 : 2;
    $canvas->createLine($x1, $y, $x2, $y,
        -fill  => $color,
        -width => $lw,
        -dash  => [4, 3],
        -tags  => 'liq_level',
    );
    # La etiqueta se omite si se solaparía con otra ya dibujada (la línea queda).
    if (!$drawn || _label_ok($drawn, $x2 + 4, $y)) {
        $canvas->createText($x2 + 4, $y,
            -anchor => 'w',
            -text   => $label,
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -tags   => 'liq_level',
        );
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_eq — EQH/EQL: línea que conecta ambos pivotes "iguales" (Tabla 2).
# pair_index es el primer pivote del par; lv->{index} es el segundo.
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_eq {
    my ($self, $canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h, $drawn, $candles) = @_;
    return unless defined $lv->{pair_index};
    return if $lv->{pair_index} < $start && $lv->{index} < $start;   # ambos fuera

    # FIX (contraste con LuxAlgo): la línea conecta la PUNTA DE MECHA de cada
    # pivote (pair_price -> price), NO una horizontal al precio del 2º pivote.
    #
    # FIX 2 (grouping-aware): al alejar el zoom, PricePanel agrupa varias velas
    # por píxel y dibuja el EXTREMO del grupo. Si anclamos al high/low del
    # pivote individual, la recta flota "a media vela" cuando en ese píxel cae
    # una vela más extrema. Se ancla al mismo extremo RENDERIZADO del píxel
    # (max high EQH / min low EQL de las velas del bucket) para que la recta
    # toque siempre la mecha visible, a cualquier zoom. Sin agrupación el bucket
    # sólo contiene el pivote -> devuelve su propio high/low (idéntico a antes).
    my $is_high    = ($lv->{kind} eq 'EQH');
    my $pair_price = $lv->{pair_price} // $lv->{price};
    my $p1 = _rendered_extreme($candles, $start, $x_of, $lv->{pair_index}, $is_high) // $pair_price;
    my $p2 = _rendered_extreme($candles, $start, $x_of, $lv->{index},      $is_high) // $lv->{price};

    my $x1 = $x_of->($lv->{pair_index} - $start);
    my $x2 = $x_of->($lv->{index}      - $start);
    my $y1 = $self->{scale}->price_to_y($p1, $min, $max, $top, $h);
    my $y2 = $self->{scale}->price_to_y($p2, $min, $max, $top, $h);
    return if ($y1 < $top && $y2 < $top) || ($y1 > $top + $h && $y2 > $top + $h);

    my $color = ($lv->{kind} eq 'EQH') ? $COLOR_EQH : $COLOR_EQL;

    my $lw = (defined $lv->{institutional} && !$lv->{institutional}) ? 1 : 2;   # PDF 4.4
    $canvas->createLine($x1, $y1, $x2, $y2,
        -fill  => $color,
        -width => $lw,
        -dash  => [2, 2],           # punteado, como LuxAlgo (line.style_dotted)
        -tags  => 'liq_eq',
    );
    if (!$drawn || _label_ok($drawn, $x2 + 4, $y2)) {
        $canvas->createText($x2 + 4, $y2,
            -anchor => 'w',
            -text   => $lv->{kind},
            -fill   => $color,
            -font   => ['Arial', 7, 'bold'],
            -tags   => 'liq_eq',
        );
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_sweep_marker — Tabla 2: "Marcador / Línea de quiebre".
# Sweep Up (BSL/EQH barridos) = rojo "SWEEP UP".
# Sweep Down (SSL/EQL barridos) = verde "SWEEP DOWN".
# (Tabla 2 usa flechas Unicode ↑/↓; se usan equivalentes ASCII por la
# limitación de fuentes en Tk/Perl ya resuelta en el toolbar del ChartEngine).
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_sweep_marker {
    my ($self, $canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h) = @_;
    my $is_ceiling = ($lv->{kind} eq 'BSL' || $lv->{kind} eq 'EQH');

    my $sx_local = $lv->{swept_at} - $start;
    return if $lv->{swept_at} < $start || $lv->{swept_at} > $end;
    my $x = $x_of->($sx_local);
    my $y = $self->{scale}->price_to_y($lv->{price}, $min, $max, $top, $h);
    return if $y < $top || $y > $top + $h;

    my $color = $is_ceiling ? $COLOR_SWEEP_UP : $COLOR_SWEEP_DOWN;
    my $label = $is_ceiling ? 'SWEEP UP' : 'SWEEP DOWN';
    my $arrow_dy = $is_ceiling ? -8 : 8;

    # Marcador de quiebre: pequeña "X" sobre el punto de cruce
    $canvas->createLine($x - 5, $y - 5, $x + 5, $y + 5, -fill => $color, -width => 2, -tags => 'liq_sweep');
    $canvas->createLine($x - 5, $y + 5, $x + 5, $y - 5, -fill => $color, -width => 2, -tags => 'liq_sweep');

    $canvas->createText($x, $y + $arrow_dy * 2,
        -text => $label,
        -fill => $color,
        -font => ['Arial', 7, 'bold'],
        -tags => 'liq_sweep',
    );
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_grab_marker — Tabla 2: "Destacado de rechazo rápido", Naranja, "LQ GRAB".
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_grab_marker {
    my ($self, $canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h) = @_;
    return if $lv->{resolved_at} < $start || $lv->{resolved_at} > $end;

    my $x_local = $lv->{resolved_at} - $start;
    my $x = $x_of->($x_local);
    my $y = $self->{scale}->price_to_y($lv->{price}, $min, $max, $top, $h);
    return if $y < $top || $y > $top + $h;

    # Destacado: círculo relleno naranja sobre la vela de rechazo
    $canvas->createOval($x - 5, $y - 5, $x + 5, $y + 5,
        -fill    => $COLOR_GRAB,
        -outline => $COLOR_GRAB,
        -tags    => 'liq_grab',
    );
    $canvas->createText($x, $y - 14,
        -text => 'LQ GRAB',
        -fill => $COLOR_GRAB,
        -font => ['Arial', 7, 'bold'],
        -tags => 'liq_grab',
    );
}

# ─────────────────────────────────────────────────────────────────────────────
# _draw_run_marker — Tabla 2: "Extensión de ruptura de nivel", Azul, "LQ RUN".
# Se dibuja como una línea extendida desde el nivel barrido hasta el punto
# de aceptación confirmada (resolved_at), representando la "extensión" de
# la ruptura tal como describe la Tabla 2.
# ─────────────────────────────────────────────────────────────────────────────
sub _draw_run_marker {
    my ($self, $canvas, $lv, $x_of, $start, $end, $min, $max, $top, $h) = @_;

    my $sx = defined $lv->{swept_at} ? $lv->{swept_at} : $lv->{index};
    $sx = $start if $sx < $start;
    my $ex = $lv->{resolved_at};
    return if $ex < $start || $sx > $end;
    $ex = $end if $ex > $end;

    my $x1 = $x_of->($sx - $start);
    my $x2 = $x_of->($ex - $start);
    my $y  = $self->{scale}->price_to_y($lv->{price}, $min, $max, $top, $h);
    return if $y < $top || $y > $top + $h;

    $canvas->createLine($x1, $y, $x2, $y,
        -fill  => $COLOR_RUN,
        -width => 2,
        -tags  => 'liq_run',
    );
    $canvas->createText($x2 + 4, $y,
        -anchor => 'w',
        -text   => 'LQ RUN',
        -fill   => $COLOR_RUN,
        -font   => ['Arial', 7, 'bold'],
        -tags   => 'liq_run',
    );
}

1;
