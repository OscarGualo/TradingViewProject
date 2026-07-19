package Market::Indicators::VWAP;
use strict;
use warnings;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::VWAP — Anchored VWAP (AVWAP), fiel a TradingView.
#
# El VWAP anclado es un Volume Weighted Average Price cuyo cálculo COMIENZA en
# una vela específica (Anchor) elegida por el usuario y NUNCA reinicia por
# sesión: acumula precio·volumen desde el anchor hasta la vela más reciente.
#
#   src_i  = fuente de precio de la vela i (por defecto hlc3 = (H+L+C)/3)
#   VWAP_t = Σ(src_i·vol_i) / Σ(vol_i)         para i = anchor..t
#
# Bandas por Desviación Estándar (modo del panel de TradingView), ponderadas
# por volumen:
#   var_t = Σ(src_i²·vol_i)/Σ(vol_i) − VWAP_t²
#   std_t = sqrt(max(0, var_t))
#   banda k = VWAP_t ± k·std_t     (k ∈ multiplicadores habilitados: 1, 2, 3)
#
# Contrato estándar del proyecto (igual que ATR/SMC/Liquidity): new/reset/
# values/calculate_all, leyendo SOLO vía $md->get_slice(0, last_index()). Eso
# lo hace replay-safe automáticamente: con un ReplayProxy, last_index() se
# acota al cursor y el AVWAP acumula exactamente [anchor..cursor] sin fuga de
# futuro. (No es compatible con el WindowProxy deslizante, que perdería el
# anchor si cae antes de la ventana — por eso en Replay se recalcula con un
# ReplayProxy, ver ChartEngine::_replay_recalc_indicators.)
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %a) = @_;
    my $self = {
        anchor_index => $a{anchor_index},          # undef = sin anclar
        source       => $a{source}     // 'hlc3',  # hlc3 | hl2 | ohlc4 | close
        band_mults   => $a{band_mults} // [1, 2, 3],
        # bandas habilitadas por defecto (imagen: #1 y #2 on, #3 off)
        bands_on     => $a{bands_on}   // [1, 1, 0],
        band_mode    => $a{band_mode}  // 'stddev',

        # Resultado: arrayref de puntos { index, vwap, u1,l1, u2,l2, u3,l3 }
        points => [],
    };
    bless $self, $class;
    return $self;
}

sub reset { $_[0]->{points} = []; }
sub values { return $_[0]->{points}; }

sub set_anchor   { $_[0]->{anchor_index} = $_[1]; }
sub clear_anchor { $_[0]->{anchor_index} = undef; $_[0]->{points} = []; }
sub anchor_index { return $_[0]->{anchor_index}; }
sub has_anchor   { return defined $_[0]->{anchor_index}; }
sub source       { return $_[0]->{source}; }
sub set_source   { $_[0]->{source} = $_[1]; }
sub bands_on     { return $_[0]->{bands_on}; }
sub band_mults   { return $_[0]->{band_mults}; }

# Precio-fuente de una vela según la configuración (default hlc3, como TV).
sub _src {
    my ($self, $c) = @_;
    my $s = $self->{source};
    return $c->{close}                              if $s eq 'close';
    return ($c->{high} + $c->{low}) / 2             if $s eq 'hl2';
    return ($c->{open} + $c->{high} + $c->{low} + $c->{close}) / 4 if $s eq 'ohlc4';
    return ($c->{high} + $c->{low} + $c->{close}) / 3;   # hlc3 (por defecto)
}

sub calculate_all {
    my ($self, $md) = @_;
    $self->reset;

    my $anchor = $self->{anchor_index};
    return unless defined $anchor;

    my $last = $md->last_index();
    return if $last < 0;

    my $a = $anchor;
    $a = 0     if $a < 0;
    return if $a > $last;   # el anchor todavía no ocurrió (p.ej. en Replay)

    my $data = $md->get_slice(0, $last);
    my $m = $self->{band_mults};
    my @on = @{ $self->{bands_on} };

    my ($cum_v, $cum_pv, $cum_pv2) = (0, 0, 0);
    my @points;
    for my $i ($a .. $last) {
        my $c   = $data->[$i];
        next unless defined $c;
        my $vol = $c->{volume} // 0;
        # Volumen 0 (raro): usa 1 para no perder la vela del promedio.
        my $w   = $vol > 0 ? $vol : 1;
        my $src = $self->_src($c);

        $cum_v   += $w;
        $cum_pv  += $src * $w;
        $cum_pv2 += $src * $src * $w;

        my $vwap = $cum_v > 0 ? $cum_pv / $cum_v : $src;
        my $var  = $cum_v > 0 ? ($cum_pv2 / $cum_v) - $vwap * $vwap : 0;
        $var = 0 if $var < 0;                 # guarda contra error de redondeo
        my $std  = sqrt($var);

        my %p = (index => $i, vwap => $vwap);
        for my $k (0 .. 2) {
            next unless $on[$k];
            my $mult = $m->[$k];
            $p{"u" . ($k + 1)} = $vwap + $mult * $std;
            $p{"l" . ($k + 1)} = $vwap - $mult * $std;
        }
        push @points, \%p;
    }
    $self->{points} = \@points;
}

# Puntos cuyo índice cae en [start, end] (para el overlay). Como points está
# ordenado por índice y es contiguo desde el anchor, basta filtrar por rango.
sub points_in_range {
    my ($self, $start, $end) = @_;
    return [ grep { $_->{index} >= $start && $_->{index} <= $end } @{ $self->{points} } ];
}

1;
