package Market::Overlays::SupplyDemand;
use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;

# ═════════════════════════════════════════════════════════════════════════════
# Market::Overlays::SupplyDemand — dibujo de las Supply/Demand Zones del DIY
# Custom Strategy Builder [ZP] (cero cálculo: lee el indicador ya computado).
#
# Fiel a las capturas / script:
#  · Supply: banda gris clara translúcida con texto 'SUPPLY' centrado.
#  · Demand: banda CYAN translúcida con texto 'DEMAND' centrado.
#  · POI: línea punteada blanca en el centro de cada zona + etiqueta 'POI'.
#  · Zonas vivas extendidas a la derecha (extend right).
#  · Display: sólo las history_keep (20) zonas vivas más recientes por lado;
#    líneas BOS (zona rota → segmento en su POI) cap 5 por lado.
#
# Replay-safe: recorta por end_index — zona visible si created_index <= end y
# no rota a esa altura; BOS visible si broken_at <= end (patrón ATR/causal,
# sin recálculo por paso).
# ═════════════════════════════════════════════════════════════════════════════

my %ZONE_COLOR = (supply => '#ededed', demand => '#00ffff');
my $POI_COLOR  = '#ffffff';
my $BOS_MAX    = 5;    # líneas BOS por lado (arrays de 5 en el script)

sub new {
    my ($class, %args) = @_;
    my $self = {
        scale   => Market::Panels::Scales->new(),
        visible => { zones => 0, poi => 0, bos => 0 },
    };
    bless $self, $class;
    return $self;
}

sub set_visible { $_[0]->{visible}{$_[1]} = $_[2] ? 1 : 0; }
sub is_visible  { return $_[0]->{visible}{$_[1]} // 0; }

sub draw {
    my ($self, $canvas, $sd, $x_of, $state) = @_;
    return unless defined $sd;
    return unless $self->{visible}{zones} || $self->{visible}{poi} || $self->{visible}{bos};

    my $start = $state->{start_index};
    my $end   = $state->{end_index};
    my $min   = $state->{price_min};
    my $max   = $state->{price_max};
    my $top   = $state->{top};
    my $h     = $state->{price_h};
    my $left  = $state->{left};
    my $right = $state->{right};
    return unless defined $min && defined $max;

    my $scale = $self->{scale};
    my $y_of  = sub { $scale->price_to_y($_[0], $min, $max, $top, $h) };
    my $x_at  = sub {   # índice global -> x, clamp al área visible
        my ($gi) = @_;
        return $left  if $gi < $start;
        return $right if $gi > $end;
        my $x = $x_of->($gi - $start);
        $x = $left  if $x < $left;
        $x = $right if $x > $right;
        return $x;
    };

    my $zones = $sd->zones();

    # ── Zonas vivas a end_index: las history_keep más recientes por lado ─────
    if ($self->{visible}{zones} || $self->{visible}{poi}) {
        my $keep = $sd->{history_keep} // 20;
        for my $kind (qw(supply demand)) {
            my @live = grep {
                $_->{kind} eq $kind
                && $_->{created_index} <= $end
                && (!defined $_->{broken_at}  || $_->{broken_at}  > $end)
                && (!defined $_->{evicted_at} || $_->{evicted_at} > $end)
            } @$zones;
            @live = sort { $b->{created_index} <=> $a->{created_index} } @live;
            @live = @live[0 .. $keep - 1] if @live > $keep;

            for my $z (@live) {
                my $y_top = $y_of->($z->{top});
                my $y_bot = $y_of->($z->{bottom});
                next if $y_bot < $top || $y_top > $top + $h;   # fuera del panel
                my $zone_start_index =
    			defined $z->{pivot_index}
    			? $z->{pivot_index}
   			 : $z->{created_index};

		my $x1 = $x_at->($zone_start_index);
                my $x2 = $right;                                # extend right
                next if $x2 - $x1 < 2;

                if ($self->{visible}{zones}) {
                    my $col = $ZONE_COLOR{$kind};
                    $canvas->createRectangle($x1, $y_top, $x2, $y_bot,
                        -fill    => $col,
                        -stipple => 'gray25',    # translúcido (Tk sin alpha)
                        -outline => $col,
                        -width   => 1,
                        -tags    => 'sd_zone',
                    );
                    $canvas->createText(($x1 + $x2) / 2, ($y_top + $y_bot) / 2,
                        -text   => uc($kind),
                        -fill   => '#ffffff',
                        -anchor => 'center',
                        -font   => ['Arial', 7, 'bold'],
                        -tags   => 'sd_zone',
                    );
                }
                if ($self->{visible}{poi}) {
                    my $y_poi = $y_of->($z->{poi});
                    $canvas->createLine($x1, $y_poi, $x2, $y_poi,
                        -fill => $POI_COLOR, -width => 1, -dash => [2, 3],
                        -tags => 'sd_poi',
                    );
                    $canvas->createText($x1 + 14, $y_poi - 6,
                        -text   => 'POI',
                        -fill   => $POI_COLOR,
                        -anchor => 'center',
                        -font   => ['Arial', 6, 'bold'],
                        -tags   => 'sd_poi',
                    );
                }
            }
        }
    }

    # ── Líneas BOS (zona rota → segmento en su POI), cap 5 por lado ──────────
    if ($self->{visible}{bos}) {
        my $bos = $sd->bos();
        for my $kind (qw(supply demand)) {
            my @done = grep { $_->{kind} eq $kind && $_->{broken_at} <= $end } @$bos;
            @done = sort { $b->{broken_at} <=> $a->{broken_at} } @done;
            @done = @done[0 .. $BOS_MAX - 1] if @done > $BOS_MAX;
            for my $b (@done) {
                next if $b->{broken_at} < $start;   # totalmente a la izquierda
                my $y = $y_of->($b->{poi});
                next if $y < $top || $y > $top + $h;
                my $x1 = $x_at->($b->{from_index});
                my $x2 = $x_at->($b->{broken_at});
                next if $x2 - $x1 < 2;
                my $col = $ZONE_COLOR{$kind};
                $canvas->createLine($x1, $y, $x2, $y,
                    -fill => $col, -width => 2, -tags => 'sd_bos');
                $canvas->createText($x2 - 12, $y - 8,
                    -text => 'BOS', -fill => $col, -anchor => 'center',
                    -font => ['Arial', 6, 'bold'], -tags => 'sd_bos');
            }
        }
    }
}

1;
