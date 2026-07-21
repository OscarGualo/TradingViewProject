package Market::Indicators::SupplyDemand;
use strict;
use warnings;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::SupplyDemand — Supply/Demand Zones del "DIY Custom
# Strategy Builder [ZP]" (Scripts/DIY STRATEGY BUILDER, sección Supply/Demand
# POI, líneas 3027-3260). Cálculo puro, cero dibujo.
#
# Concepto: una zona de Supply/Demand es un RANGO de precios donde hubo un
# desequilibrio masivo entre compradores y vendedores (órdenes institucionales
# residuales). Cuando el precio regresa, esas órdenes tienden a reactivarse.
#
# Algoritmo fiel al script:
#  · ATR(50) RMA (ta.atr(50)).
#  · Pivots: ta.pivothigh(high,10,10) / ta.pivotlow(low,10,10) — la vela i es
#    swing high si su high es el MÁXIMO ESTRICTO del vecindario ±swing_length;
#    se CONFIRMA swing_length velas después (índice i+swing_length).
#  · Zona (atr_buffer = ATR50 × box_width/10, default 2.5/10 = ATR×0.25):
#      Supply (swing high): top = high_pivot ; bottom = top − atr_buffer
#      Demand (swing low) : bottom = low_pivot ; top = bottom + atr_buffer
#      POI = (top+bottom)/2  (Point Of Interest, centro de la zona)
#  · Anti-solape (f_check_overlapping): NO se crea la zona si su POI cae en
#    poi_existente ± 2×ATR50 de una zona VIVA del mismo lado.
#  · Rotura (f_sd_to_bos): supply se rompe con close >= top; demand con
#    close <= bottom. La zona rota sale del set vivo y deja una línea BOS en
#    su POI desde el origen hasta la vela de rotura.
#  · Display: sólo las 20 zonas vivas más recientes por lado (history_keep) y
#    5 líneas BOS por lado — ese cap lo aplica el OVERLAY; aquí se conservan
#    TODAS las zonas creadas para que Replay/scroll recorten por índice.
#
# Replay-safe por CAUSALIDAD (patrón ATR): pivot confirmado con lookback fijo,
# ATR RMA y rotura por close sólo miran hacia atrás → se precomputa UNA vez
# sobre todo el histórico y NO se recalcula por paso de Replay. El overlay
# recorta por end_index: zona visible si created_index <= end y (broken_at
# undef o > end); línea BOS visible si broken_at <= end. El filtro anti-solape
# usa el set de zonas vivas EN EL MOMENTO de creación (pasada secuencial), por
# lo que el resultado es idéntico a un recomputo directo sobre [0..cursor].
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %a) = @_;
    my $self = {
        swing_length     => $a{swing_length}     // 10,    # Swing High/Low Length
        history_keep     => $a{history_keep}     // 20,    # History To Keep (display)
        box_width        => $a{box_width}        // 2.5,   # Supply/Demand Box Width
        atr_period       => $a{atr_period}       // 50,
        overlap_atr_mult => $a{overlap_atr_mult} // 2,
        zones => [],   # { kind, created_index, pivot_index, top, bottom, poi, broken_at }
        bos   => [],   # { kind, poi, from_index, broken_at }
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{zones} = [];
    $self->{bos}   = [];
}

sub values {
    my ($self) = @_;
    return { zones => $self->{zones}, bos => $self->{bos} };
}

sub zones { return $_[0]->{zones}; }
sub bos   { return $_[0]->{bos}; }

sub calculate_all {
    my ($self, $md) = @_;
    $self->reset();
    my $last = $md->last_index();
    return if $last < 0;
    my $data = $md->get_slice(0, $last);
    my $n    = scalar @$data;
    my $k    = $self->{swing_length};
    return if $n < 2 * $k + 1;

    # ── ATR(atr_period) RMA — mismo cálculo que ta.atr() de Pine ────────────
    my $P = $self->{atr_period};
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

    my $buf_f = $self->{box_width} / 10;      # atr_buffer = ATR × box_width/10
    my $ov_m  = $self->{overlap_atr_mult};    # anti-solape: POI ± 2×ATR

    my (@zones, @bos);
    my (@live_supply, @live_demand);          # refs a zonas vivas por lado

    # Pasada secuencial: en la vela i se confirma el pivot de i-k (si lo hay)
    # y luego se chequean roturas con el close de i — mismo orden que el
    # script (swing primero, f_sd_to_bos después, cada barra).
    for my $i (0 .. $n - 1) {
        # ── Confirmación de pivot en p = i-k ─────────────────────────────────
        if ($i >= 2 * $k) {
            my $p  = $i - $k;
            my $ph = 1; my $pl = 1;
            my $hp = $data->[$p]{high};
            my $lp = $data->[$p]{low};
            for my $j ($p - $k .. $p + $k) {
                next if $j == $p;
                $ph = 0 if $data->[$j]{high} >= $hp;   # máximo ESTRICTO
                $pl = 0 if $data->[$j]{low}  <= $lp;   # mínimo ESTRICTO
                last if !$ph && !$pl;
            }
            # El script evalúa swing_high y, si no, swing_low (if/else if).
            if ($ph) {
                $self->_try_create_zone(\@zones, \@live_supply, 'supply',
                    $p, $i, $hp, $atr[$i], $buf_f, $ov_m);
            } elsif ($pl) {
                $self->_try_create_zone(\@zones, \@live_demand, 'demand',
                    $p, $i, $lp, $atr[$i], $buf_f, $ov_m);
            }
        }

        # ── Roturas: supply con close >= top; demand con close <= bottom ────
        my $close = $data->[$i]{close};
        for my $pair ([\@live_supply, sub { $close >= $_[0]{top} }],
                      [\@live_demand, sub { $close <= $_[0]{bottom} }]) {
            my ($live, $hit) = @$pair;
            next unless @$live;
            my @keep;
            for my $z (@$live) {
                if ($hit->($z)) {
                    $z->{broken_at} = $i;
                    push @bos, {
    kind       => $z->{kind},
    poi        => $z->{poi},
    from_index =>
        defined $z->{pivot_index}
        ? $z->{pivot_index}
        : $z->{created_index},

    broken_at  => $i
};
                } else {
                    push @keep, $z;
                }
            }
            @$live = @keep;
        }
    }

    $self->{zones} = \@zones;
    $self->{bos}   = \@bos;
}

# Crea la zona del pivot confirmado si el anti-solape lo permite.
# $val = high del pivot (supply) o low del pivot (demand); $atr = ATR en la
# vela de CONFIRMACIÓN (cuando corre f_supply_demand en el script).
sub _try_create_zone {
    my ($self, $zones, $live, $kind, $pivot_i, $created_i, $val, $atr, $buf_f, $ov_m) = @_;
    my ($top, $bottom);
    if ($kind eq 'supply') {
        $top    = $val;
        $bottom = $top - $atr * $buf_f;
    } else {
        $bottom = $val;
        $top    = $bottom + $atr * $buf_f;
    }
    my $poi = ($top + $bottom) / 2;

    # Anti-solape contra las zonas VIVAS del mismo lado.
    my $thr = $atr * $ov_m;
    for my $z (@$live) {
        return if $poi >= $z->{poi} - $thr && $poi <= $z->{poi} + $thr;
    }

    my $zone = {
        kind          => $kind,
        created_index => $created_i,
        pivot_index   => $pivot_i,
        top           => $top,
        bottom        => $bottom,
        poi           => $poi,
        broken_at     => undef,
        evicted_at    => undef,
    };
    push @$zones, $zone;
    push @$live,  $zone;
    # Cap de vivas por lado (history_keep): el script mantiene un array fijo de
    # 20 boxes — al entrar una nueva, la más vieja se ELIMINA del gráfico para
    # siempre (box.delete). Registramos evicted_at para que el overlay la deje
    # de dibujar desde esa vela (y deja de participar del anti-solape/roturas).
    if (@$live > $self->{history_keep}) {
        my $evicted = shift @$live;
        $evicted->{evicted_at} = $created_i;
    }
}

1;
