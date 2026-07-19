package Market::IndicatorManager;
use strict;
use warnings;

sub new {
    my ($class) = @_;
    my $self = { indicators => {} };
    bless $self, $class;
    return $self;
}

sub register {
    my ($self, $name, $indicator) = @_;
    $self->{indicators}{$name} = $indicator;
}

sub update_last {
    my ($self, $market_data) = @_;
    for my $name (keys %{$self->{indicators}}) {
        $self->{indicators}{$name}->calculate_all($market_data);
    }
    $self->apply_concurrency();
}

# Sección 5 del PDF (Relación Estructural y de Concurrencia): una vez que TODOS
# los indicadores calcularon, se conecta la clasificación de la máquina de
# estados de liquidez con la estructura SMC (Sweep->CHoCH, Run->BOS, Grab->
# Reversal, FVG->Alta Reacción). Se hace aquí, fuera de los calculate_all, para
# no romper la independencia de los indicadores. No-op si falta alguno.
sub apply_concurrency {
    my ($self) = @_;
    my $smc = $self->{indicators}{'SMC_Structures'};
    my $liq = $self->{indicators}{'Liquidity'};
    return unless $smc && $liq && $smc->can('apply_liquidity_concurrency');
    $smc->apply_liquidity_concurrency($liq);
}

sub get {
    my ($self, $name) = @_;
    return $self->{indicators}{$name}->values();
}

# Acceso al OBJETO indicador completo (no solo a values()).
# Necesario para indicadores como SMC_Structures que exponen métodos propios
# de consulta (swing_at, swings_in_range, last_swing_high_before, etc.)
# que no encajan en el contrato simple de get()/slice_array() pensado
# originalmente para arrays indexados por vela como ATR.
# No modifica get() ni slice_array(): es estrictamente aditivo.
sub get_indicator {
    my ($self, $name) = @_;
    return $self->{indicators}{$name};
}

sub slice_array {
    my ($self, $name, $start, $end) = @_;
    my $arr = $self->get($name);
    $start = 0 if $start < 0;
    $end = $#$arr if $end > $#$arr;
    return [] if $end < $start;
    return [ @$arr[$start .. $end] ];
}

sub reset_all {
    my ($self) = @_;
    $_->reset() for values %{$self->{indicators}};
}

1;
