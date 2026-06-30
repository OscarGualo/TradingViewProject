package Market::ReplayProxy;
use strict;
use warnings;

# ─────────────────────────────────────────────────────────────────────────────
# Market::ReplayProxy — Proxy de solo lectura sobre MarketData
#
# Propósito: durante el Replay, los indicadores (ATR, SMC, Liquidity) deben
# calcular SOLO con los datos hasta replay_cursor, nunca con velas futuras.
# El problema es que calculate_all() en ATR.pm llama:
#   $market_data->get_slice(0, $market_data->last_index())
# y last_index() siempre devuelve el total real.
#
# Este proxy envuelve el MarketData real y sobreescribe last_index() y size()
# para que devuelvan el límite del cursor, sin copiar ni modificar los datos.
# Todos los demás métodos delegan al market real.
#
# Uso en _replay_recalc_indicators():
#   my $proxy = Market::ReplayProxy->new($self->{market}, $self->{replay_cursor});
#   $self->{indicators}->update_last($proxy);
# ─────────────────────────────────────────────────────────────────────────────

sub new {
    my ($class, $market, $cursor) = @_;
    return bless {
        _market => $market,
        _cursor => $cursor,
    }, $class;
}

# ── Métodos sobreescritos — devuelven el límite del cursor ───────────────────

sub last_index {
    my ($self) = @_;
    my $real_last = $self->{_market}->last_index();
    return $self->{_cursor} < $real_last ? $self->{_cursor} : $real_last;
}

sub size {
    my ($self) = @_;
    return $self->last_index() + 1;
}

sub last_candle {
    my ($self) = @_;
    return $self->{_market}->get_candle($self->last_index());
}

# get_slice respeta el límite del cursor
sub get_slice {
    my ($self, $start, $end) = @_;
    my $limit = $self->last_index();
    $end = $limit if $end > $limit;
    return $self->{_market}->get_slice($start, $end);
}

# ── Delegación completa al market real ──────────────────────────────────────
# Todos los métodos no sobreescritos se delegan automáticamente.

sub get_candle      { $_[0]->{_market}->get_candle($_[1]); }
sub get_tf_data     { $_[0]->{_market}->get_tf_data($_[1]); }
sub get_tf_slice    { $_[0]->{_market}->get_tf_slice($_[1], $_[2], $_[3]); }
sub get_timeframe   { $_[0]->{_market}->get_timeframe(); }
sub get_timestamp   { $_[0]->{_market}->get_timestamp($_[1]); }
sub get_data        { $_[0]->{_market}->get_data(); }
sub available_timeframes { $_[0]->{_market}->available_timeframes(); }

1;
