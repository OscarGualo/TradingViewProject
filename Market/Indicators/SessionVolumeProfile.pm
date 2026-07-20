package Market::Indicators::SessionVolumeProfile;
use strict;
use warnings;
use lib '.';
use Market::Indicators::VolumeProfile;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Indicators::SessionVolumeProfile (SVP) — Perfil de Volumen de Sesión.
#
# A diferencia del AVP (un perfil desde un ancla manual), el SVP construye UN
# histograma independiente por cada SESIÓN. Para nuestra data de futuros
# continuos 24h una sesión = un DÍA de calendario ("Todas" de TradingView; los
# modos pre/main/post no son construibles sin metadata de horario extendido).
#
# Reutiliza toda la matemática por-perfil de VolumeProfile::compute_profile
# (filas, POC, VAH/VAL, up/down, área de valor). Cada sesión se calcula desde
# sus velas de 1m (los días tienen <5000 velas 1m → máxima precisión; equivale
# a la regla "TF más fina con <5000 barras" del AVP — la tabla de resolución de
# TV existe por límites de historial que aquí no aplican).
#
# Replay-safe: con un ReplayProxy, get_slice()/get_tf_slice() quedan acotados al
# cursor, así la sesión EN DESARROLLO (la que contiene el cursor) sólo incluye
# velas ≤ cursor y las sesiones futuras no se construyen. Caché por día: una
# sesión ya COMPLETA (su fin ya pasó el cursor) no cambia → se reusa; sólo la
# sesión del cursor se recalcula por paso de Replay (barato).
# ═════════════════════════════════════════════════════════════════════════════

sub new {
    my ($class, %a) = @_;
    my $self = {
        row_size       => $a{row_size}       // 24,
        value_area_pct => $a{value_area_pct} // 70,
        tick_size      => $a{tick_size}      // 0.25,
        sessions       => [],
        _cache         => {},   # day_start_epoch => { end_epoch, result }
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{sessions} = [];
    # _cache NO se limpia: sesiones completas son inmutables entre pasos de
    # Replay. Se invalida explícitamente al cambiar de TF (invalidate_cache).
}

sub invalidate_cache { $_[0]->{_cache} = {}; }

sub values   { return $_[0]->{sessions}; }
sub has_any  { return scalar @{ $_[0]->{sessions} } ? 1 : 0; }

sub _day_of {
    my ($time) = @_;
    return ($time // '') =~ /^(\d{4}-\d{2}-\d{2})/ ? $1 : '';
}

sub calculate_all {
    my ($self, $md) = @_;
    $self->{sessions} = [];
    my $last = $md->last_index();
    return if $last < 0;

    my $data = $md->get_slice(0, $last);       # velas del TF activo (para el dibujo)
    return unless $data && @$data;

    # Epoch de la última vela visible (cursor en Replay): define qué día está
    # "en desarrollo" (el último) y hasta dónde llega el 1m (ya acotado si $md
    # es ReplayProxy).
    my $cursor_epoch = $data->[-1]{epoch};

    my %cfg = (
        rows_layout    => 'rows',
        row_size       => $self->{row_size},
        value_area_pct => $self->{value_area_pct},
        tick_size      => $self->{tick_size},
    );

    # ── Agrupar velas del TF activo por día (para los índices de dibujo) ─────
    my @days;   # { day, start_index, end_index, start_epoch, end_epoch }
    my $cur;
    for my $i (0 .. $#$data) {
        my $c   = $data->[$i];
        my $day = _day_of($c->{time});
        if (!$cur || $cur->{day} ne $day) {
            $cur = { day => $day, start_index => $i, end_index => $i,
                     start_epoch => $c->{epoch}, end_epoch => $c->{epoch} };
            push @days, $cur;
        } else {
            $cur->{end_index} = $i;
            $cur->{end_epoch} = $c->{epoch};
        }
    }
    return unless @days;
    my $dev_day = $days[-1]{day};   # sesión en desarrollo = último día visible

    # ── Bucket de 1m por día (una sola pasada, ya acotado al cursor) ─────────
    # get_tf_slice → get_tf_slice_upto con ReplayProxy, así que sólo llegan
    # velas 1m ≤ cursor: la sesión en desarrollo queda recortada sin fuga.
    my $m1 = $md->get_tf_slice(1, 0, 1_000_000_000);
    my %day1m;
    for my $c (@$m1) {
        push @{ $day1m{ _day_of($c->{time}) } }, $c;
    }

    # ── Un perfil por día (con caché de días completos) ─────────────────────
    my @out;
    for my $d (@days) {
        my $day = $d->{day};
        # "Completo" = no es la sesión en desarrollo (su día ya cerró ≤ cursor).
        my $complete = ($day ne $dev_day);
        my $result;
        if ($complete && (my $ck = $self->{_cache}{$day})) {
            $result = $ck->{result};
        } else {
            my $c1 = $day1m{$day};
            $result = ($c1 && @$c1)
                ? Market::Indicators::VolumeProfile::compute_profile($c1, %cfg)
                : undef;
            $self->{_cache}{$day} = { result => $result } if $complete && $result;
        }
        next unless $result;
        push @out, {
            day         => $day,
            start_index => $d->{start_index},
            end_index   => $d->{end_index},
            start_epoch => $d->{start_epoch},
            end_epoch   => $d->{end_epoch},
            result      => $result,
        };
    }
    $self->{sessions} = \@out;
}

1;
