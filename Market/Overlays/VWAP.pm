package Market::Overlays::VWAP;
use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Overlays::VWAP — dibujo del Anchored VWAP multipivot (fiel a TV).
#
# Dibuja cada serie que calculó Market::Indicators::VWAP (cero cálculo aquí):
#   · Línea central VWAP (color de la serie) + mini etiqueta al extremo derecho.
#   · Bandas 1σ/2σ/3σ (sólo si la serie las pidió) con relleno tenue.
#
# Compatible con Replay: $start/$end vienen acotados al cursor y el indicador
# sólo devuelve puntos hasta ahí.
# ═════════════════════════════════════════════════════════════════════════════

my %BAND_COLOR = (1 => '#26a69a', 2 => '#9c8a5c', 3 => '#808080');

sub new {
    my ($class, %args) = @_;
    my $self = {
        scale => Market::Panels::Scales->new(),
        # Visibilidad global de bandas (además del flag por serie).
        visible => { band1 => 1, band2 => 1, band3 => 0 },
    };
    bless $self, $class;
    return $self;
}

sub set_visible { $_[0]->{visible}{$_[1]} = $_[2] ? 1 : 0; }
sub is_visible  { return $_[0]->{visible}{$_[1]} // 0; }

# ─────────────────────────────────────────────────────────────────────────────
sub draw {
    my ($self, $canvas, $vwap, $x_of, $state) = @_;
    return unless defined $vwap && $vwap->has_any;

    my $start = $state->{start_index};
    my $end   = $state->{end_index};
    my $min   = $state->{price_min};
    my $max   = $state->{price_max};
    my $top   = $state->{top};
    my $h     = $state->{price_h};
    my $right = $state->{right};
    return unless defined $min && defined $max;

    for my $ser (@{ $vwap->values() }) {
        $self->_draw_series($canvas, $ser, $x_of, $start, $end, $min, $max, $top, $h, $right);
    }
}

sub _draw_series {
    my ($self, $canvas, $ser, $x_of, $start, $end, $min, $max, $top, $h, $right) = @_;
    my $all = $ser->{points};
    return unless $all && @$all;

    # Puntos visibles (contiguos desde el anchor).
    my $pts = [ grep { $_->{index} >= $start && $_->{index} <= $end } @$all ];
    return unless @$pts >= 2;

    my $scale = $self->{scale};
    my $x = sub { $x_of->($_[0]{index} - $start) };
    my $y = sub { $scale->price_to_y($_[1], $min, $max, $top, $h) };

    my @on = @{ $ser->{bands_on} };

    # Bandas (de fuera hacia dentro), sólo si la serie las pidió Y están visibles.
    for my $k (2, 1) {
        next unless $on[$k - 1] && $self->{visible}{"band$k"};
        my $uk = "u$k"; my $lk = "l$k";
        next unless defined $pts->[0]{$uk};
        my $in_u = ($k == 1) ? 'vwap' : 'u' . ($k - 1);
        my $in_l = ($k == 1) ? 'vwap' : 'l' . ($k - 1);
        my $col  = $BAND_COLOR{$k};
        $self->_fill($canvas, $pts, $x, $y, $in_u, $uk, $col);
        $self->_fill($canvas, $pts, $x, $y, $lk, $in_l, $col);
        $self->_polyline($canvas, $pts, $x, $y, $uk, $col, 1);
        $self->_polyline($canvas, $pts, $x, $y, $lk, $col, 1);
    }
    if ($on[2] && $self->{visible}{band3} && defined $pts->[0]{u3}) {
        $self->_polyline($canvas, $pts, $x, $y, 'u3', $BAND_COLOR{3}, 1);
        $self->_polyline($canvas, $pts, $x, $y, 'l3', $BAND_COLOR{3}, 1);
    }

    # Línea central (encima) + etiqueta.
    $self->_polyline($canvas, $pts, $x, $y, 'vwap', $ser->{color}, 2);
    my $last = $pts->[-1];
    $canvas->createText($x->($last) - 3, $y->($last, $last->{vwap}) - 7,
        -anchor => 'e', -text => $ser->{label}, -fill => $ser->{color},
        -font => ['Arial', 7, 'bold'], -tags => 'vwap');
}

sub _polyline {
    my ($self, $canvas, $pts, $x, $y, $key, $color, $width) = @_;
    my @coords;
    for my $p (@$pts) {
        next unless defined $p->{$key};
        push @coords, $x->($p), $y->($p, $p->{$key});
    }
    return if @coords < 4;
    $canvas->createLine(@coords, -fill => $color, -width => $width, -tags => 'vwap');
}

sub _fill {
    my ($self, $canvas, $pts, $x, $y, $k_in, $k_out, $color) = @_;
    my (@top_edge, @bot_edge);
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
