package Market::Overlays::StrategyBuilder;
use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Overlays::StrategyBuilder — dibujo de SuperTrend / HalfTrend / Range
# Filter (DIY Strategy Builder). Cero cálculo aquí; sólo lee el indicador ya
# computado y recorta por end_index (replay-safe, patrón causal como ATR/SD).
#
#   · SuperTrend : línea escalonada verde(up)/roja(down), rota en cada flip
#                  (estilo linebr) + círculos de señal Buy/Sell.
#   · HalfTrend  : línea azul(up)/roja(down) + canales tenues (hband/lband).
#   · Range Filter: línea verde/roja según dirección + bandas con relleno tenue.
# ═════════════════════════════════════════════════════════════════════════════

my %ST_COL = ( 1 => '#26a69a', -1 => '#ef5350', 0 => '#26a69a' );
my %HT_COL = ( 1 => '#2962ff', -1 => '#ef5350', 0 => '#2962ff' );
my %RF_COL = ( 1 => '#26a69a', -1 => '#ef5350', 0 => '#787b86' );

sub new {
    my ($class, %args) = @_;
    my $self = {
        scale   => Market::Panels::Scales->new(),
        visible => { supertrend => 0, halftrend => 0, rangefilter => 0 },
    };
    bless $self, $class;
    return $self;
}

sub set_visible { $_[0]->{visible}{$_[1]} = $_[2] ? 1 : 0; }
sub is_visible  { return $_[0]->{visible}{$_[1]} // 0; }

sub draw {
    my ($self, $canvas, $sb, $x_of, $state) = @_;
    return unless defined $sb;
    my $min = $state->{price_min};
    my $max = $state->{price_max};
    return unless defined $min && defined $max;
    my $start = $state->{start_index};
    my $end   = $state->{end_index};
    my $top   = $state->{top};
    my $h     = $state->{price_h};
    my $scale = $self->{scale};

    my $x = sub { $x_of->($_[0]{index} - $start) };
    my $y = sub { $scale->price_to_y($_[1], $min, $max, $top, $h) };
    my $vis = sub {
        return [ grep { $_->{index} >= $start && $_->{index} <= $end } @{ $_[0] } ];
    };

    # ── Range Filter (bandas + línea) ────────────────────────────────────────
    if ($self->{visible}{rangefilter}) {
        my $pts = $vis->($sb->rangefilter);
        if (@$pts >= 2) {
            $self->_band($canvas, $pts, $x, $y, 'hband', 'lband', '#787b86');
            $self->_poly($canvas, $pts, $x, $y, 'hband', '#3a3e49', 1);
            $self->_poly($canvas, $pts, $x, $y, 'lband', '#3a3e49', 1);
            $self->_segments($canvas, $pts, $x, $y, 'filt', 0, \%RF_COL, 2);
        }
    }

    # ── HalfTrend (canales + línea) ──────────────────────────────────────────
    if ($self->{visible}{halftrend}) {
        my $pts = $vis->($sb->halftrend);
        if (@$pts >= 2) {
            $self->_poly($canvas, $pts, $x, $y, 'hband', '#4a5a8a', 1);
            $self->_poly($canvas, $pts, $x, $y, 'lband', '#4a5a8a', 1);
            $self->_segments($canvas, $pts, $x, $y, 'line', 0, \%HT_COL, 2);
        }
    }

    # ── SuperTrend (línea rota por flip + señales) ───────────────────────────
    if ($self->{visible}{supertrend}) {
        my $pts = $vis->($sb->supertrend);
        if (@$pts >= 2) {
            $self->_segments($canvas, $pts, $x, $y, 'line', 1, \%ST_COL, 2);
            for my $p (@$pts) {
                next unless $p->{signal};
                my $col = $p->{signal} == 1 ? $ST_COL{1} : $ST_COL{-1};
                my ($px, $py) = ($x->($p), $y->($p, $p->{line}));
                $canvas->createOval($px - 3, $py - 3, $px + 3, $py + 3,
                    -fill => $col, -outline => $col, -tags => 'strat');
            }
        }
    }
}

# Segmentos coloreados por dirección/tendencia. $break_flip=1 rompe la línea
# cuando trend cambia (estilo linebr de SuperTrend); si 0, línea continua
# coloreada por el `dir` de cada punto.
sub _segments {
    my ($self, $c, $pts, $x, $y, $key, $break_flip, $col, $w) = @_;
    my $dirk = $break_flip ? 'trend' : 'dir';
    for my $i (1 .. $#$pts) {
        my $a = $pts->[$i - 1];
        my $b = $pts->[$i];
        next unless defined $a->{$key} && defined $b->{$key};
        next if $break_flip && $a->{$dirk} != $b->{$dirk};   # rotura en el flip
        my $d = $b->{$dirk} // 0;
        my $color = $col->{$d} // $col->{0};
        $c->createLine($x->($a), $y->($a, $a->{$key}),
                       $x->($b), $y->($b, $b->{$key}),
            -fill => $color, -width => $w, -tags => 'strat');
    }
}

sub _poly {
    my ($self, $c, $pts, $x, $y, $key, $color, $w) = @_;
    my @coords;
    for my $p (@$pts) {
        next unless defined $p->{$key};
        push @coords, $x->($p), $y->($p, $p->{$key});
    }
    return if @coords < 4;
    $c->createLine(@coords, -fill => $color, -width => $w, -tags => 'strat');
}

sub _band {
    my ($self, $c, $pts, $x, $y, $k_up, $k_lo, $color) = @_;
    my (@top_edge, @bot_edge);
    for my $p (@$pts) {
        next unless defined $p->{$k_up} && defined $p->{$k_lo};
        push    @top_edge, $x->($p), $y->($p, $p->{$k_up});
        unshift @bot_edge, $x->($p), $y->($p, $p->{$k_lo});
    }
    return if @top_edge < 4;
    $c->createPolygon(@top_edge, @bot_edge,
        -fill => $color, -stipple => 'gray12', -outline => '', -tags => 'strat');
}

1;
