package Market::Indicators::VWAP;
use strict;
use warnings;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::VWAP — Anchored VWAP multipivot, fiel a TradingView.
#
# El VWAP anclado comienza en una vela Anchor y NUNCA reinicia por sesión:
# acumula precio·volumen desde el anchor hasta la vela más reciente.
#   src_i  = fuente de precio (por defecto hlc3 = (H+L+C)/3)
#   VWAP_t = Σ(src_i·vol_i)/Σ(vol_i)   para i = anchor..t
# Bandas por desviación estándar ponderada por volumen:
#   var_t = Σ(src_i²·vol_i)/Σ(vol_i) − VWAP_t² ; std_t = sqrt(max(0,var_t))
#   banda k = VWAP_t ± k·std_t
#
# MULTIPIVOT (PDF sección 8): mantiene una LISTA de series, cada una con su
# propio anchor, etiqueta y color, para mostrar varios AVWAP simultáneos
# (manual por clic + anclajes automáticos: sesión, apertura, BOS, CHoCH, POC).
# La RESOLUCIÓN de los anchors automáticos vive en el orquestador (ChartEngine),
# que respeta la separación de capas; este indicador sólo calcula el VWAP dado
# el índice de anchor de cada serie.
#
# Replay-safe: lee sólo vía $md->get_slice(0,last_index()); con un ReplayProxy
# last_index() se acota al cursor y cada serie acumula [anchor..cursor] sin
# fuga de futuro. (No usa el WindowProxy deslizante, que perdería el anchor.)
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %a) = @_;
    my $self = {
        # series: [ { key, anchor_index, label, color, source, bands_on, points } ]
        series       => $a{series}     // [],
        band_mults   => $a{band_mults} // [1, 2, 3],
        default_src  => $a{source}     // 'hlc3',
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $_->{points} = [] for @{ $self->{series} };
}

# values() devuelve la lista de series (con sus points calculados) — la usa el
# overlay para dibujar cada AVWAP.
sub values  { return $_[0]->{series}; }
sub has_any { return scalar @{ $_[0]->{series} } ? 1 : 0; }

# Reemplaza la lista de series. Cada spec: { key, anchor_index, label, color,
# source?, bands_on? }. Los points se rellenan en calculate_all().
sub set_series {
    my ($self, $specs) = @_;
    my @series;
    for my $s (@$specs) {
        push @series, {
            key          => $s->{key},
            anchor_index => $s->{anchor_index},
            label        => $s->{label}  // 'VWAP',
            color        => $s->{color}  // '#2962ff',
            source       => $s->{source} // $self->{default_src},
            bands_on     => $s->{bands_on} // [0, 0, 0],
            points       => [],
        };
    }
    $self->{series} = \@series;
}

# Precio-fuente de una vela (default hlc3, como TradingView).
sub _src {
    my ($src, $c) = @_;
    return $c->{close}                              if $src eq 'close';
    return ($c->{high} + $c->{low}) / 2             if $src eq 'hl2';
    return ($c->{open} + $c->{high} + $c->{low} + $c->{close}) / 4 if $src eq 'ohlc4';
    return ($c->{high} + $c->{low} + $c->{close}) / 3;   # hlc3
}

sub calculate_all {
    my ($self, $md) = @_;
    my $last = $md->last_index();
    my $data = $last >= 0 ? $md->get_slice(0, $last) : [];

    for my $ser (@{ $self->{series} }) {
        $ser->{points} = [];
        my $anchor = $ser->{anchor_index};
        next unless defined $anchor;
        my $a = $anchor < 0 ? 0 : $anchor;
        next if $a > $last;   # el anchor aún no ocurrió (Replay)

        my $m   = $self->{band_mults};
        my @on  = @{ $ser->{bands_on} };
        my $src = $ser->{source};

        my ($cum_v, $cum_pv, $cum_pv2) = (0, 0, 0);
        my @points;
        for my $i ($a .. $last) {
            my $c = $data->[$i];
            next unless defined $c;
            my $vol = $c->{volume} // 0;
            my $w   = $vol > 0 ? $vol : 1;
            my $s   = _src($src, $c);

            $cum_v   += $w;
            $cum_pv  += $s * $w;
            $cum_pv2 += $s * $s * $w;

            my $vwap = $cum_v > 0 ? $cum_pv / $cum_v : $s;
            my $var  = $cum_v > 0 ? ($cum_pv2 / $cum_v) - $vwap * $vwap : 0;
            $var = 0 if $var < 0;
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
        $ser->{points} = \@points;
    }
}

1;
