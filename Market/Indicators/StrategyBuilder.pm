package Market::Indicators::StrategyBuilder;
use strict;
use warnings;
use POSIX qw(floor);

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::StrategyBuilder — los 3 componentes técnicos del DIY
# Custom Strategy Builder [ZP] que faltaban (PDF 2ª entrega, Tabla 3):
# SuperTrend, HalfTrend y Range Filter. Cálculo puro (cero dibujo).
#
# Portados fielmente del script `Scripts/DIY STRATEGY BUILDER`:
#   · SuperTrend  (líneas 1191-1230): ATR(10), src=hl2, mult=3.0.
#   · HalfTrend   (líneas 1239-1326): amplitude=2, channelDeviation=2, ATR(100).
#   · Range Filter(líneas 964-1016) : src=close, per=100, mult=3.0.
#
# Los TRES son CAUSALES (cada barra depende sólo de barras pasadas + estado
# recursivo). Igual que ATR y SupplyDemand: se precomputan una vez sobre todo
# el histórico y el resultado es válido para cualquier cursor de Replay; el
# overlay recorta por end_index. Por eso NO se recalculan por paso de Replay
# (no usan WindowProxy). Todos los índices almacenados son globales/absolutos.
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %a) = @_;
    my $self = {
        st_period    => $a{st_period}    // 10,   # SuperTrend ATR period
        st_mult      => $a{st_mult}      // 3.0,  # SuperTrend ATR multiplier
        ht_amplitude => $a{ht_amplitude} // 2,    # HalfTrend amplitude
        ht_dev       => $a{ht_dev}       // 2,    # HalfTrend channel deviation
        ht_atr       => $a{ht_atr}       // 100,  # HalfTrend ATR period
        rf_period    => $a{rf_period}    // 100,  # Range Filter sampling period
        rf_mult      => $a{rf_mult}      // 3.0,  # Range Filter multiplier
        supertrend   => [],
        halftrend    => [],
        rangefilter  => [],
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{supertrend}  = [];
    $self->{halftrend}   = [];
    $self->{rangefilter} = [];
}

sub values {
    my ($self) = @_;
    return {
        supertrend  => $self->{supertrend},
        halftrend   => $self->{halftrend},
        rangefilter => $self->{rangefilter},
    };
}
sub supertrend  { return $_[0]->{supertrend}; }
sub halftrend   { return $_[0]->{halftrend}; }
sub rangefilter { return $_[0]->{rangefilter}; }

# ─── ATR (RMA de True Range), == ta.atr(P) de Pine ──────────────────────────
sub _atr_array {
    my ($data, $P) = @_;
    my $n = scalar @$data;
    my (@atr, $rma, $prev_close);
    for my $i (0 .. $n - 1) {
        my $c = $data->[$i];
        my $tr = $i == 0
            ? ($c->{high} - $c->{low})
            : do { my $a = $c->{high} - $c->{low};
                   my $b = abs($c->{high} - $prev_close);
                   my $d = abs($c->{low}  - $prev_close);
                   my $m = $a; $m = $b if $b > $m; $m = $d if $d > $m; $m };
        $rma = $i == 0 ? $tr : ($rma * ($P - 1) + $tr) / $P;
        $atr[$i]    = $rma;
        $prev_close = $c->{close};
    }
    return \@atr;
}

sub calculate_all {
    my ($self, $md) = @_;
    $self->reset();
    my $last = $md->last_index();
    return if $last < 0;
    my $data = $md->get_slice(0, $last);
    my $n = scalar @$data;
    return if $n < 2;

    $self->_calc_supertrend($data, $n);
    $self->_calc_halftrend($data, $n);
    $self->_calc_rangefilter($data, $n);
}

# ─── SuperTrend ─────────────────────────────────────────────────────────────
sub _calc_supertrend {
    my ($self, $data, $n) = @_;
    my $atr  = _atr_array($data, $self->{st_period});
    my $mult = $self->{st_mult};

    my @out;
    my ($up_prev, $dn_prev, $trend_prev);
    for my $i (0 .. $n - 1) {
        my $c   = $data->[$i];
        my $src = ($c->{high} + $c->{low}) / 2;              # hl2
        my $up  = $src - $mult * $atr->[$i];
        my $dn  = $src + $mult * $atr->[$i];

        if ($i == 0) {
            $trend_prev = 1;
        } else {
            my $cl1 = $data->[$i - 1]{close};
            $up = $cl1 > $up_prev ? ($up > $up_prev ? $up : $up_prev) : $up;   # max(up,up1) si close[1]>up1
            $dn = $cl1 < $dn_prev ? ($dn < $dn_prev ? $dn : $dn_prev) : $dn;   # min(dn,dn1) si close[1]<dn1
        }

        my $trend = $trend_prev;
        if ($i > 0) {
            my $cl = $c->{close};
            $trend = ($trend_prev == -1 && $cl > $dn_prev) ? 1
                   : ($trend_prev ==  1 && $cl < $up_prev) ? -1
                   : $trend_prev;
        }

        my $signal = 0;
        $signal =  1 if $i > 0 && $trend == 1  && $trend_prev == -1;   # buy
        $signal = -1 if $i > 0 && $trend == -1 && $trend_prev ==  1;   # sell

        push @out, {
            index  => $i,
            line   => ($trend == 1 ? $up : $dn),
            trend  => $trend,
            up     => $up,
            dn     => $dn,
            signal => $signal,
        };

        ($up_prev, $dn_prev, $trend_prev) = ($up, $dn, $trend);
    }
    $self->{supertrend} = \@out;
}

# ─── HalfTrend ──────────────────────────────────────────────────────────────
sub _calc_halftrend {
    my ($self, $data, $n) = @_;
    my $amp  = $self->{ht_amplitude};
    my $atr2 = _atr_array($data, $self->{ht_atr});   # se divide /2 abajo

    my @out;
    # Estado persistente (var en Pine).
    my $ht_trend    = 0;    # 0 = up, 1 = down
    my $next_trend  = 0;
    my $max_low     = $data->[0]{low};
    my $min_high    = $data->[0]{high};
    my ($ht_up, $ht_down);
    my $ht_trend_prev;

    for my $i (0 .. $n - 1) {
        my $c   = $data->[$i];
        my $dev = $self->{ht_dev} * ($atr2->[$i] / 2);

        # highPrice/lowPrice = extremos de la ventana `amplitude`; highma/lowma = SMA.
        my $lo0 = $i - $amp + 1; $lo0 = 0 if $lo0 < 0;
        my ($hp, $lp, $sum_h, $sum_l, $cnt) = (undef, undef, 0, 0, 0);
        for my $j ($lo0 .. $i) {
            my $cc = $data->[$j];
            $hp = $cc->{high} if !defined $hp || $cc->{high} > $hp;
            $lp = $cc->{low}  if !defined $lp || $cc->{low}  < $lp;
            $sum_h += $cc->{high}; $sum_l += $cc->{low}; $cnt++;
        }
        my $highma = $sum_h / $cnt;
        my $lowma  = $sum_l / $cnt;
        my $low1   = $i > 0 ? $data->[$i - 1]{low}  : $c->{low};
        my $high1  = $i > 0 ? $data->[$i - 1]{high} : $c->{high};

        if ($next_trend == 1) {
            $max_low = $lp > $max_low ? $lp : $max_low;
            if ($highma < $max_low && $c->{close} < $low1) {
                $ht_trend   = 1;
                $next_trend = 0;
                $min_high   = $hp;
            }
        } else {
            $min_high = $hp < $min_high ? $hp : $min_high;
            if ($lowma > $min_high && $c->{close} > $high1) {
                $ht_trend   = 0;
                $next_trend = 1;
                $max_low    = $lp;
            }
        }

        if ($ht_trend == 0) {
            if (defined $ht_trend_prev && $ht_trend_prev != 0) {
                $ht_up = defined $ht_down ? $ht_down : ($ht_up // $max_low);
            } else {
                $ht_up = defined $ht_up ? ($max_low > $ht_up ? $max_low : $ht_up) : $max_low;
            }
        } else {
            if (defined $ht_trend_prev && $ht_trend_prev != 1) {
                $ht_down = defined $ht_up ? $ht_up : ($ht_down // $min_high);
            } else {
                $ht_down = defined $ht_down ? ($min_high < $ht_down ? $min_high : $ht_down) : $min_high;
            }
        }

        my $ht = $ht_trend == 0 ? $ht_up : $ht_down;
        push @out, {
            index => $i,
            line  => $ht,
            dir   => ($ht_trend == 0 ? 1 : -1),   # 1 = up (azul), -1 = down (rojo)
            hband => $ht + $dev,
            lband => $ht - $dev,
        };

        $ht_trend_prev = $ht_trend;
    }
    $self->{halftrend} = \@out;
}

# ─── Range Filter ───────────────────────────────────────────────────────────
sub _calc_rangefilter {
    my ($self, $data, $n) = @_;
    my $per  = $self->{rf_period};
    my $mult = $self->{rf_mult};

    # smrng = EMA( EMA(|Δclose|, per), per*2-1 ) * mult
    my $wper = $per * 2 - 1;
    my $a1   = 2 / ($per + 1);
    my $a2   = 2 / ($wper + 1);
    my @smrng;
    my ($avrng, $smooth);
    for my $i (0 .. $n - 1) {
        my $src  = $data->[$i]{close};
        my $absd = $i > 0 ? abs($src - $data->[$i - 1]{close}) : 0;
        $avrng  = $i == 0 ? $absd  : $avrng  + $a1 * ($absd  - $avrng);
        $smooth = $i == 0 ? $avrng : $smooth + $a2 * ($avrng - $smooth);
        $smrng[$i] = $smooth * $mult;
    }

    my @out;
    my ($filt_prev, $up_cnt, $dn_cnt) = (undef, 0, 0);
    for my $i (0 .. $n - 1) {
        my $x = $data->[$i]{close};
        my $r = $smrng[$i];
        my $filt;
        if (!defined $filt_prev) {
            $filt = $x;
        } elsif ($x > $filt_prev) {
            $filt = ($x - $r < $filt_prev) ? $filt_prev : $x - $r;
        } else {
            $filt = ($x + $r > $filt_prev) ? $filt_prev : $x + $r;
        }

        my $dir = 0;
        if (defined $filt_prev) {
            if    ($filt > $filt_prev) { $up_cnt++; $dn_cnt = 0; $dir =  1; }
            elsif ($filt < $filt_prev) { $dn_cnt++; $up_cnt = 0; $dir = -1; }
            else  { $dir = $up_cnt > 0 ? 1 : ($dn_cnt > 0 ? -1 : 0); }
        }

        push @out, {
            index => $i,
            filt  => $filt,
            dir   => $dir,
            hband => $filt + $r,
            lband => $filt - $r,
        };
        $filt_prev = $filt;
    }
    $self->{rangefilter} = \@out;
}

1;
