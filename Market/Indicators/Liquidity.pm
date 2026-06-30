package Market::Indicators::Liquidity;
use strict;
use warnings;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::Liquidity
#
# Según la arquitectura del PDF (Tabla 1):
#   "Motor de detección analítica de Swing Points, EQH/EQL, Sweeps, Grabs y
#    Runs, gestionando la máquina de estados de liquidez."
#
# PUNTO 3.4 — Implementado en este archivo:
#   - BSL (Buy Side Liquidity) y SSL (Sell Side Liquidity)
#   - EQH (Equal Highs) y EQL (Equal Lows) con tolerancia dinámica por ATR
#   - Máquina de estados de liquidez: Detected -> Swept -> Acceptance/
#     Reclaimed -> Resolved, con clasificación final Sweep / Grab / Run
#
# Archivo independiente y autocontenido: calcula sus propios Swing Points
# y su propio ATR internamente (mismas fórmulas que SMC_Structures.pm y
# ATR.pm respectivamente) para no depender del orden de registro de otros
# indicadores en el IndicatorManager. Esto respeta la separación de
# packages de la Tabla 1 del PDF: Liquidity.pm es responsable exclusivo
# de su propio dominio.
#
# Sigue el mismo contrato que los demás indicadores:
#   new(%args) -> objeto
#   reset()    -> limpia el estado interno
#   values()   -> devuelve los niveles de liquidez calculados (arrayref)
#   calculate_all($market_data) -> recalcula todo desde cero
#
# Compatible con Market::ReplayProxy: calculate_all() solo usa
# $market_data->get_slice(0, $market_data->last_index()), igual que los
# demás indicadores. Con un ReplayProxy en vez del MarketData real, todo
# el módulo de liquidez respeta automáticamente el cursor de Replay.
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %args) = @_;
    my $self = {
        # Profundidad de vecindad para detectar Swing Points (PDF 4.1: k=3)
        depth => $args{depth} // 3,

        # Periodo del ATR interno usado para la tolerancia de EQH/EQL
        # PDF 4.1: "tolerancia = ATR * 0.10"
        atr_period    => $args{atr_period}    // 14,
        eq_tolerance_factor => $args{eq_tolerance_factor} // 0.10,

        # N de velas de cierre consecutivo requeridas para clasificar un
        # evento como "Run" (PDF 4.2: "valor inicial N = 3")
        run_confirm_n => $args{run_confirm_n} // 3,

        # Máximo de velas para que un retorno cuente como "Grab" en vez
        # de "Sweep" estándar (PDF 4.2: "máximo de 3 velas posteriores")
        grab_max_candles => $args{grab_max_candles} // 3,

        # ── Resultado de calculate_all() ──────────────────────────────────
        # levels: arrayref cronológico de hashrefs de nivel de liquidez:
        #   {
        #     index, price, kind,        # kind: 'BSL' | 'SSL' | 'EQH' | 'EQL'
        #     pair_index,                # solo EQH/EQL: índice del 2º pivote
        #     state,                     # 'Detected'|'Swept'|'Acceptance'|
        #                                # 'Reclaimed'|'Resolved'
        #     classification,            # 'Sweep'|'Grab'|'Run'|undef (hasta Resolved)
        #     swept_at,                  # índice donde el precio cruzó el nivel
        #     resolved_at,               # índice donde el ciclo concluyó
        #   }
        levels => [],
        levels_by_index => {},   # índice de DETECCIÓN -> nivel(es)

        # Swing Points internos (mismo formato que SMC_Structures, recalculado
        # aquí para mantener el archivo autocontenido según la Tabla 1 del PDF)
        _swings => [],
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{levels} = [];
    $self->{levels_by_index} = {};
    $self->{_swings} = [];
}

# values() devuelve el arrayref de niveles de liquidez — contrato estándar
# esperado por IndicatorManager::get('Liquidity').
sub values {
    my ($self) = @_;
    return $self->{levels};
}

# Acceso directo: nivel(es) detectados en una vela específica, o undef.
sub levels_at {
    my ($self, $index) = @_;
    return $self->{levels_by_index}{$index};
}

# Niveles dentro de un rango de índices — usado por el Overlay (3.5).
sub levels_in_range {
    my ($self, $start, $end) = @_;
    return [ grep { $_->{index} >= $start && $_->{index} <= $end } @{ $self->{levels} } ];
}

# Solo niveles de un kind dado ('BSL'|'SSL'|'EQH'|'EQL') dentro de un rango.
sub levels_in_range_by_kind {
    my ($self, $start, $end, $kind) = @_;
    return [
        grep { $_->{index} >= $start && $_->{index} <= $end && $_->{kind} eq $kind }
        @{ $self->{levels} }
    ];
}

# ─────────────────────────────────────────────────────────────────────────────
# calculate_all — orquesta el cálculo completo del módulo de liquidez:
#   1. Swing Points internos (idéntico a SMC_Structures.pm)
#   2. ATR interno (idéntico a ATR.pm) — usado para la tolerancia EQH/EQL
#   3. Detección de BSL/SSL y EQH/EQL
#   4. Máquina de estados Sweep/Grab/Run sobre cada nivel detectado
# ─────────────────────────────────────────────────────────────────────────────
sub calculate_all {
    my ($self, $market_data) = @_;
    $self->reset();

    my $data = $market_data->get_slice(0, $market_data->last_index());
    my $n = scalar @$data;
    return if $n < (2 * $self->{depth} + 1);

    $self->_calc_swings($data);
    my $atr = $self->_calc_atr($data);
    $self->_detect_levels($data, $atr);
    $self->_run_state_machine($data);
}

# ─────────────────────────────────────────────────────────────────────────────
# _calc_swings — Swing Points internos (misma fórmula que SMC_Structures 3.1)
# PDF 4.1: High[i] > High[i-k..i-1] y High[i] > High[i+1..i+k] (Swing High)
#          Low[i]  < Low[i-k..i-1]  y Low[i]  < Low[i+1..i+k]  (Swing Low)
# ─────────────────────────────────────────────────────────────────────────────
sub _calc_swings {
    my ($self, $data) = @_;
    my $k = $self->{depth};
    my $n = scalar @$data;
    my @swings;

    for (my $i = $k; $i <= $n - 1 - $k; $i++) {
        my $c = $data->[$i];

        my $is_high = 1;
        for my $j (($i - $k) .. ($i - 1), ($i + 1) .. ($i + $k)) {
            if ($data->[$j]{high} >= $c->{high}) { $is_high = 0; last; }
        }
        if ($is_high) {
            push @swings, { index => $i, price => $c->{high}, type => 'high' };
            next;
        }

        my $is_low = 1;
        for my $j (($i - $k) .. ($i - 1), ($i + 1) .. ($i + $k)) {
            if ($data->[$j]{low} <= $c->{low}) { $is_low = 0; last; }
        }
        if ($is_low) {
            push @swings, { index => $i, price => $c->{low}, type => 'low' };
        }
    }

    $self->{_swings} = \@swings;
}

# ─────────────────────────────────────────────────────────────────────────────
# _calc_atr — ATR interno (misma fórmula RMA de Wilder que ATR.pm)
# Devuelve un arrayref alineado 1:1 con $data (undef durante el warmup).
# ─────────────────────────────────────────────────────────────────────────────
sub _calc_atr {
    my ($self, $data) = @_;
    my $p = $self->{atr_period};
    my (@tr, @atr);

    for my $i (0 .. $#$data) {
        my $c = $data->[$i];
        my $tr;
        if ($i == 0) {
            $tr = $c->{high} - $c->{low};
        } else {
            my $pc = $data->[$i - 1]{close};
            my $a = $c->{high} - $c->{low};
            my $b = abs($c->{high} - $pc);
            my $d = abs($c->{low}  - $pc);
            $tr = $a > $b ? ($a > $d ? $a : $d) : ($b > $d ? $b : $d);
        }
        push @tr, $tr;

        if ($i < $p - 1) {
            push @atr, undef;
        } elsif ($i == $p - 1) {
            my $sum = 0; $sum += $_ for @tr[0 .. $p - 1];
            push @atr, $sum / $p;
        } else {
            push @atr, (($atr[-1] * ($p - 1)) + $tr) / $p;
        }
    }
    return \@atr;
}

# ─────────────────────────────────────────────────────────────────────────────
# _detect_levels — Punto 3.4, primera mitad
#
# BSL (Buy Side Liquidity): un nivel por cada Swing High — liquidez de
# Buy Stops acumulada por encima de máximos relevantes (PDF 4.1).
#
# SSL (Sell Side Liquidity): un nivel por cada Swing Low — liquidez de
# Sell Stops acumulada por debajo de mínimos relevantes (PDF 4.1).
#
# EQH (Equal Highs) / EQL (Equal Lows): cuando dos Swing Highs (o Lows)
# tienen precios casi idénticos según la tolerancia dinámica del PDF:
#   tolerancia = ATR * 0.10
# se registra un nivel EQH/EQL adicional conectando ambos pivotes. El
# segundo pivote del par se guarda en pair_index para que el Overlay (3.5)
# pueda dibujar la línea que conecta ambos extremos.
#
# Cada Swing High/Low SIEMPRE genera su BSL/SSL correspondiente; además,
# si forma un par con tolerancia, genera TAMBIÉN un nivel EQH/EQL. Esto
# es intencional: BSL/SSL representan "todo nivel relevante", mientras
# que EQH/EQL son el subconjunto especial de niveles duplicados — ambos
# coexisten como exige la Tabla 2 del PDF (estilos de overlay distintos).
# ─────────────────────────────────────────────────────────────────────────────
sub _detect_levels {
    my ($self, $data, $atr) = @_;
    my $factor = $self->{eq_tolerance_factor};

    my @highs = grep { $_->{type} eq 'high' } @{ $self->{_swings} };
    my @lows  = grep { $_->{type} eq 'low'  } @{ $self->{_swings} };

    # ── BSL: un nivel por cada Swing High ─────────────────────────────────
    for my $sw (@highs) {
        $self->_push_level($sw->{index}, $sw->{price}, 'BSL', undef);
    }

    # ── SSL: un nivel por cada Swing Low ──────────────────────────────────
    for my $sw (@lows) {
        $self->_push_level($sw->{index}, $sw->{price}, 'SSL', undef);
    }

    # ── EQH: pares de Swing Highs dentro de tolerancia ATR*0.10 ───────────
    # Se compara cada swing contra los anteriores (no solo el inmediato)
    # para detectar pares distantes en el tiempo, tal como especifica el
    # PDF ("Dos pivotes distantes en el tiempo se consideran iguales").
    for (my $a = 0; $a <= $#highs; $a++) {
        for (my $b = $a + 1; $b <= $#highs; $b++) {
            my $tolerance = _tolerance_at($atr, $highs[$b]{index}, $factor);
            next if !defined $tolerance;
            if (abs($highs[$a]{price} - $highs[$b]{price}) <= $tolerance) {
                $self->_push_level(
                    $highs[$b]{index}, $highs[$b]{price}, 'EQH', $highs[$a]{index}
                );
            }
        }
    }

    # ── EQL: pares de Swing Lows dentro de tolerancia ATR*0.10 ─────────────
    for (my $a = 0; $a <= $#lows; $a++) {
        for (my $b = $a + 1; $b <= $#lows; $b++) {
            my $tolerance = _tolerance_at($atr, $lows[$b]{index}, $factor);
            next if !defined $tolerance;
            if (abs($lows[$a]{price} - $lows[$b]{price}) <= $tolerance) {
                $self->_push_level(
                    $lows[$b]{index}, $lows[$b]{price}, 'EQL', $lows[$a]{index}
                );
            }
        }
    }

    # Reordenar cronológicamente: los pasos anteriores insertan BSL/SSL
    # primero y EQH/EQL después, mezclando el orden temporal.
    @{ $self->{levels} } = sort { $a->{index} <=> $b->{index} } @{ $self->{levels} };
}

# Tolerancia dinámica en el índice dado: ATR * factor. undef si el ATR
# todavía está en warmup en ese índice (PDF: "tolerancia dinámico basado
# en la volatilidad del activo").
sub _tolerance_at {
    my ($atr, $index, $factor) = @_;
    my $v = $atr->[$index];
    return defined $v ? $v * $factor : undef;
}

# Helper interno: registra un nivel de liquidez recién DETECTADO.
# Estado inicial siempre 'Detected' — la máquina de estados lo hace
# evolucionar más adelante en _run_state_machine().
sub _push_level {
    my ($self, $index, $price, $kind, $pair_index) = @_;

    my $level = {
        index          => $index,
        price          => $price,
        kind           => $kind,
        pair_index     => $pair_index,
        state          => 'Detected',
        classification => undef,
        swept_at       => undef,
        resolved_at    => undef,
    };

    push @{ $self->{levels} }, $level;

    if (exists $self->{levels_by_index}{$index}) {
        my $existing = $self->{levels_by_index}{$index};
        if (ref($existing) eq 'ARRAY') {
            push @$existing, $level;
        } else {
            $self->{levels_by_index}{$index} = [ $existing, $level ];
        }
    } else {
        $self->{levels_by_index}{$index} = $level;
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _run_state_machine — Punto 3.4, segunda mitad
#
# Implementa la máquina de estados de liquidez del PDF 4.3:
#
#   Estado 1 DETECTED   -> nivel BSL/SSL/EQH/EQL recién identificado.
#   Estado 2 SWEPT      -> el precio cruza el extremo del nivel:
#                          High > BSL  (para BSL/EQH)
#                          Low  < SSL  (para SSL/EQL)
#   Desde SWEPT, según el PDF 4.2, el primer evento que ocurra decide:
#     a) N=3 cierres consecutivos fuera del nivel -> ACCEPTANCE -> "Run"
#     b) Retorno (cierre) dentro del rango en <=3 velas tras el cruce
#        -> RECLAIMED -> "Grab" (rechazo rápido, PDF: "máximo 3 velas")
#     c) Retorno estándar (más de 3 velas, sin las 3 consecutivas de N)
#        -> RECLAIMED -> "Sweep" (caso por defecto/estándar)
#   Estado 5 RESOLVED   -> el ciclo concluye, clasificación inmutable.
#
# Solo BSL y EQH se evalúan contra rupturas alcistas (High > nivel);
# solo SSL y EQL contra rupturas bajistas (Low < nivel) — coherente con
# el PDF: BSL/EQH son techos, SSL/EQL son pisos.
# ─────────────────────────────────────────────────────────────────────────────
sub _run_state_machine {
    my ($self, $data) = @_;
    my $n = scalar @$data;
    my $grab_max = $self->{grab_max_candles};
    my $run_n    = $self->{run_confirm_n};

    for my $level (@{ $self->{levels} }) {
        my $is_ceiling = ($level->{kind} eq 'BSL' || $level->{kind} eq 'EQH');
        my $price = $level->{price};

        # Buscar el primer cruce (Swept) después del índice de detección.
        my $swept_at;
        for (my $j = $level->{index} + 1; $j < $n; $j++) {
            my $c = $data->[$j];
            if ($is_ceiling ? ($c->{high} > $price) : ($c->{low} < $price)) {
                $swept_at = $j;
                last;
            }
        }

        next unless defined $swept_at;   # nunca fue barrido: queda 'Detected'

        $level->{state}    = 'Swept';
        $level->{swept_at} = $swept_at;

        # ── Evaluar qué pasa después del cruce ────────────────────────────
        # Primero: ¿cuántas velas consecutivas, empezando en swept_at,
        # cierran de forma ESTRICTA fuera del nivel? (para detectar Run)
        my $consecutive_outside = 0;
        for (my $j = $swept_at; $j < $n; $j++) {
            my $close = $data->[$j]{close};
            my $outside = $is_ceiling ? ($close > $price) : ($close < $price);
            last unless $outside;
            $consecutive_outside++;
            last if $consecutive_outside >= $run_n;
        }

        if ($consecutive_outside >= $run_n) {
            # ── Run: aceptación institucional confirmada ──────────────────
            my $resolved_at = $swept_at + $run_n - 1;
            $level->{state}          = 'Acceptance';
            $level->{classification} = 'Run';
            $level->{resolved_at}    = $resolved_at;
            $level->{state}          = 'Resolved';
            next;
        }

        # No hubo Run: buscar el primer retorno (Reclaimed) — la primera
        # vela posterior a swept_at cuyo CIERRE regresa dentro del rango.
        my $reclaim_at;
        for (my $j = $swept_at; $j < $n; $j++) {
            my $close = $data->[$j]{close};
            my $still_outside = $is_ceiling ? ($close > $price) : ($close < $price);
            if (!$still_outside) {
                $reclaim_at = $j;
                last;
            }
        }

        if (defined $reclaim_at) {
            my $candles_to_reclaim = $reclaim_at - $swept_at;
            $level->{state} = 'Reclaimed';
            $level->{classification} =
                ($candles_to_reclaim <= $grab_max) ? 'Grab' : 'Sweep';
            $level->{resolved_at} = $reclaim_at;
            $level->{state} = 'Resolved';
        }
        # Si no hubo ni Run ni Reclaimed dentro de los datos disponibles,
        # el nivel queda en estado 'Swept' — su ciclo aún no concluyó
        # (relevante en Replay: el futuro que resolvería el evento
        # todavía no ha sido revelado por el cursor).
    }
}

1;
