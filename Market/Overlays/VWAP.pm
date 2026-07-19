package Market::Overlays::VWAP;
use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Overlays::VWAP — dibujo del Anchored VWAP (fiel a TradingView).
#
# Dibuja lo que calculó Market::Indicators::VWAP (cero lógica de cálculo aquí):
#   · Línea central VWAP  : azul, grosor 2.
#   · Bandas 1σ/2σ/3σ     : líneas upper/lower con relleno tenue entre ellas.
# Colores como el panel de TradingView: central azul, 1σ verde, 2σ oliva.
#
# Compatible con Replay: ChartEngine llama con $start/$end ya acotados al
# cursor y el indicador sólo devuelve puntos hasta ahí.
# ═════════════════════════════════════════════════════════════════════════════

my $COLOR_VWAP  = '#2962ff';   # azul   — línea central
my %BAND_COLOR  = (1 => '#26a69a', 2 => '#9c8a5c', 3 => '#808080');  # verde, oliva, gris

sub new {
    my ($class, %args) = @_;
    my $self = {
        scale   => Market::Panels::Scales->new(),
        visible => {
            vwap  => 1,   # línea central
            band1 => 1,   # 1σ  (on por defecto, como la imagen)
            band2 => 1,   # 2σ  (on)
            band3 => 0,   # 3σ  (off)
        },
    };
    bless $self, $class;
    return $self;
}

sub set_visible { $_[0]->{visible}{$_[1]} = $_[2] ? 1 : 0; }
sub is_visible  { return $_[0]->{visible}{$_[1]} // 0; }

# ─────────────────────────────────────────────────────────────────────────────
sub draw {
    my ($self, $canvas, $vwap, $x_of, $state) = @_;
    return unless defined $vwap && $vwap->has_anchor;

    my $start = $state->{start_index};
    my $end   = $state->{end_index};
    my $min   = $state->{price_min};
    my $max   = $state->{price_max};
    my $top   = $state->{top};
    my $h     = $state->{price_h};
    return unless defined $min && defined $max;

    my $pts = $vwap->points_in_range($start, $end);
    return unless @$pts >= 2;

    my $scale = $self->{scale};
    my $x = sub { $x_of->($_[0]{index} - $start) };
    my $y = sub { $scale->price_to_y($_[1], $min, $max, $top, $h) };

    # ── Bandas (de fuera hacia dentro para que el relleno interior quede encima)
    for my $k (2, 1) {   # 2σ primero (fondo), luego 1σ
        next unless $self->{visible}{"band$k"};
        my $uk = "u$k"; my $lk = "l$k";
        next unless defined $pts->[0]{$uk};
        my $inner = ($k == 1) ? 'vwap' : 'u' . ($k - 1);   # límite interior del relleno
        my $inner_l = ($k == 1) ? 'vwap' : 'l' . ($k - 1);
        my $col = $BAND_COLOR{$k};

        # Relleno tenue: superior (inner..u_k) e inferior (l_k..inner)
        $self->_fill($canvas, $pts, $x, $y, $inner,   $uk, $col);
        $self->_fill($canvas, $pts, $x, $y, $lk, $inner_l, $col);

        # Líneas de banda upper/lower
        $self->_polyline($canvas, $pts, $x, $y, $uk, $col, 1);
        $self->_polyline($canvas, $pts, $x, $y, $lk, $col, 1);
    }

    # ── 3σ (opcional, sólo líneas para no saturar)
    if ($self->{visible}{band3} && defined $pts->[0]{u3}) {
        $self->_polyline($canvas, $pts, $x, $y, 'u3', $BAND_COLOR{3}, 1);
        $self->_polyline($canvas, $pts, $x, $y, 'l3', $BAND_COLOR{3}, 1);
    }

    # ── Línea central VWAP (encima de todo)
    $self->_polyline($canvas, $pts, $x, $y, 'vwap', $COLOR_VWAP, 2)
        if $self->{visible}{vwap};
}

# Polilínea a través de la clave de precio $key de cada punto.
sub _polyline {
    my ($self, $canvas, $pts, $x, $y, $key, $color, $width) = @_;
    my @coords;
    for my $p (@$pts) {
        next unless defined $p->{$key};
        push @coords, $x->($p), $y->($p, $p->{$key});
    }
    return if @coords < 4;
    $canvas->createLine(@coords, -fill => $color, -width => $width,
        -tags => 'vwap', -smooth => 0);
}

# Relleno tenue (stipple) entre dos límites de precio ($k_in .. $k_out).
sub _fill {
    my ($self, $canvas, $pts, $x, $y, $k_in, $k_out, $color) = @_;
    my @top_edge; my @bot_edge;
    for my $p (@$pts) {
        next unless defined $p->{$k_in} && defined $p->{$k_out};
        push @top_edge, $x->($p), $y->($p, $p->{$k_out});
        unshift @bot_edge, $x->($p), $y->($p, $p->{$k_in});
    }
    return if @top_edge < 4;
    $canvas->createPolygon(@top_edge, @bot_edge,
        -fill => $color, -stipple => 'gray12', -outline => '', -tags => 'vwap');
}

1;
