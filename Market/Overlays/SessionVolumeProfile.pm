package Market::Overlays::SessionVolumeProfile;
use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Overlays::SessionVolumeProfile — dibuja un histograma de volumen por
# SESIÓN (día), cada uno localizado en el rango horizontal de su sesión, con
# caja de Área de Valor + POC/VAH/VAL. Cero cálculo (lee el indicador). Recorta
# por end_index (replay-safe: la sesión en desarrollo ya viene acotada al cursor
# desde el indicador).
# ═════════════════════════════════════════════════════════════════════════════

my %COL = (
    up_va  => '#22d3ee', up_out  => '#0e7490',
    dn_va  => '#ec4899', dn_out  => '#9d174b',
    tot_va => '#5b9cff', tot_out => '#2a4a7a',
    poc    => '#e53935',
    va_box => '#26a69a',
    va     => '#b58a3c',
);

my $WIDTH_FRAC = 0.85;   # ancho máx del histograma = 85% del ancho de la sesión
my $WIDTH_CAP  = 140;    # tope en px (sesiones muy anchas al hacer zoom)

sub new {
    my ($class, %args) = @_;
    my $self = {
        scale   => Market::Panels::Scales->new(),
        mode    => 'updown',
        visible => { profiles => 0, poc => 0, va => 0, vah => 0, val => 0 },
        extend  => { poc => 0, vah => 0, val => 0 },
    };
    bless $self, $class;
    return $self;
}

sub set_visible { $_[0]->{visible}{$_[1]} = $_[2] ? 1 : 0; }
sub is_visible  { return $_[0]->{visible}{$_[1]} // 0; }
sub set_mode    { $_[0]->{mode} = $_[1]; }
sub mode        { return $_[0]->{mode}; }
sub set_extend  { $_[0]->{extend}{$_[1]} = $_[2] ? 1 : 0; }

sub draw {
    my ($self, $canvas, $svp, $x_of, $state) = @_;
    return unless defined $svp && $svp->has_any;
    return unless $self->{visible}{profiles};
    return unless defined $state->{price_min} && defined $state->{price_max};

    for my $sess (@{ $svp->values() }) {
        next unless $sess->{result};
        # Sólo sesiones que solapan la ventana visible.
        next if $sess->{end_index} < $state->{start_index}
             || $sess->{start_index} > $state->{end_index};
        $self->_draw_session($canvas, $sess, $x_of, $state);
    }
}

sub _draw_session {
    my ($self, $c, $sess, $x_of, $state) = @_;
    my $res  = $sess->{result};
    my $rows = $res->{rows};
    return unless $rows && @$rows;

    my $min   = $state->{price_min};
    my $max   = $state->{price_max};
    my $top   = $state->{top};
    my $h     = $state->{price_h};
    my $left  = $state->{left};
    my $right = $state->{right};
    my $w     = $state->{w};
    my $start = $state->{start_index};
    my $scale = $self->{scale};
    my $y_of  = sub { $scale->price_to_y($_[0], $min, $max, $top, $h) };

    my $x_left  = $x_of->($sess->{start_index} - $start);
    my $x_right = $x_of->($sess->{end_index}   - $start);
    $x_left  = $left  if $x_left  < $left;
    $x_right = $right if $x_right > $right;
    my $sess_w = $x_right - $x_left;
    return if $sess_w < 2;
    my $max_width = $WIDTH_FRAC * $sess_w;
    $max_width = $WIDTH_CAP if $max_width > $WIDTH_CAP;

    my $mode    = $self->{mode};
    my $max_vol = $res->{max_row_vol} || 1;
    my $max_delta = 1;
    if ($mode eq 'delta') {
        for my $r (@$rows) {
            my $d = abs($r->{up} - $r->{down});
            $max_delta = $d if $d > $max_delta;
        }
    }

    # ── Caja de Área de Valor (detrás del histograma) ───────────────────────
    if ($self->{visible}{va}) {
        my $yv_hi = $y_of->($res->{vah});
        my $yv_lo = $y_of->($res->{val});
        unless ($yv_lo < $top || $yv_hi > $top + $h) {
            $c->createRectangle($x_left, $yv_hi, $x_right, $yv_lo,
                -fill => $COL{va_box}, -stipple => 'gray12', -outline => '',
                -tags => 'svp');
        }
    }

    # ── Barras del histograma (ancladas a la izquierda, crecen a la derecha) ─
    for my $r (@$rows) {
        next if $r->{total} <= 0;
        my $y_hi = $y_of->($r->{price_hi});
        my $y_lo = $y_of->($r->{price_lo});
        next if $y_lo < $top - 1 || $y_hi > $top + $h + 1;
        my $bh = $y_lo - $y_hi;
        $bh = 1 if $bh < 1;
        my $in_va = $r->{in_va};

        if ($mode eq 'total') {
            my $bw = ($r->{total} / $max_vol) * $max_width;
            next if $bw < 0.5;
            _rect($c, $x_left, $y_hi, $x_left + $bw, $y_hi + $bh,
                  $in_va ? $COL{tot_va} : $COL{tot_out});
        }
        elsif ($mode eq 'delta') {
            my $d  = $r->{up} - $r->{down};
            my $bw = (abs($d) / $max_delta) * $max_width;
            next if $bw < 0.5;
            my $col = $d >= 0
                ? ($in_va ? $COL{up_va} : $COL{up_out})
                : ($in_va ? $COL{dn_va} : $COL{dn_out});
            _rect($c, $x_left, $y_hi, $x_left + $bw, $y_hi + $bh, $col);
        }
        else {   # updown: up + down apilados desde la izquierda
            my $w_up = ($r->{up}   / $max_vol) * $max_width;
            my $w_dn = ($r->{down} / $max_vol) * $max_width;
            if ($w_up >= 0.5) {
                _rect($c, $x_left, $y_hi, $x_left + $w_up, $y_hi + $bh,
                      $in_va ? $COL{up_va} : $COL{up_out});
            }
            if ($w_dn >= 0.5) {
                _rect($c, $x_left + $w_up, $y_hi, $x_left + $w_up + $w_dn, $y_hi + $bh,
                      $in_va ? $COL{dn_va} : $COL{dn_out});
            }
        }
    }

    # ── Líneas POC / VAH / VAL ───────────────────────────────────────────────
    $self->_line($c, $x_left, $x_right, $w, $y_of->($res->{poc_price}),
                 $res->{poc_price}, $COL{poc}, 2, 0, $self->{extend}{poc})
        if $self->{visible}{poc};
    $self->_line($c, $x_left, $x_right, $w, $y_of->($res->{vah}),
                 $res->{vah}, $COL{va}, 1, 1, $self->{extend}{vah})
        if $self->{visible}{vah};
    $self->_line($c, $x_left, $x_right, $w, $y_of->($res->{val}),
                 $res->{val}, $COL{va}, 1, 1, $self->{extend}{val})
        if $self->{visible}{val};
}

sub _line {
    my ($self, $c, $x0, $x1, $w, $y, $price, $color, $width, $dash, $extend) = @_;
    my $xe = $extend ? $w : $x1;   # extender a la derecha hasta el borde del área
    my @opt = (-fill => $color, -width => $width, -tags => 'svp');
    push @opt, (-dash => [4, 3]) if $dash;
    $c->createLine($x0, $y, $xe, $y, @opt);
}

sub _rect {
    my ($c, $x0, $y0, $x1, $y1, $color) = @_;
    $c->createRectangle($x0, $y0, $x1, $y1,
        -fill => $color, -outline => '', -tags => 'svp');
}

1;
