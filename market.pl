use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use lib "$FindBin::Bin/Market";
use lib ".";
use Tk;
use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::Indicators::SMC_Structures;
use Market::Indicators::Liquidity;
use Market::Indicators::ZigZagMTF;
use Market::Indicators::ZigZagVolume;
use Market::Indicators::VWAP;
use Market::Indicators::VolumeProfile;
use Market::Indicators::SupplyDemand;
use Market::ChartEngine;

# ─── Resolución de archivos CSV ──────────────────────────────────────────────
# Prioridad:
#   1. Archivos pasados como argumentos: perl market.pl 2026_04.csv 2026_05.csv ...
#   2. Archivos estándar del proyecto encontrados junto al script
# Si se pasa un solo CSV (compatibilidad con Fase 1), funciona igual que antes.

my @csv_files;

if (@ARGV) {
    # Modo explícito: el usuario pasa los archivos que quiere
    @csv_files = map { -f $_ ? $_ : "$FindBin::Bin/$_" } @ARGV;
} else {
    # Modo automático: buscar los CSVs estándar junto al script
    my @candidates = (
        "$FindBin::Bin/2026_04.csv",
        "$FindBin::Bin/2026_05.csv",
        "$FindBin::Bin/2026_06.csv",
        "$FindBin::Bin/2026_07_13.csv",
    );
    for my $f (@candidates) {
        push @csv_files, $f if -f $f;
    }
    if (!@csv_files) {
        die "No se encontraron archivos CSV.\n"
          . "Uso: perl market.pl [archivo1.csv archivo2.csv ...]\n";
    }
}

# ─── Carga de datos ──────────────────────────────────────────────────────────

my $market = Market::MarketData->new();

if (@csv_files == 1) {
    # Compatibilidad: carga simple de un solo archivo
    print "Cargando datos desde '$csv_files[0]'...\n";
    $market->load_csv($csv_files[0]);
} else {
    print "Cargando " . scalar(@csv_files) . " archivos CSV...\n";
    $market->load_csv_files(@csv_files);
}

$market->set_timeframe(1);
$market->print_summary();

# ─── Interfaz gráfica: crear la ventana YA, antes de calcular indicadores ────
# FIX ("la app parece trabada/congelada al arrancar"): antes, update_last()
# corría sobre las ~100k velas de 1m ANTES de crear el MainWindow. Con
# SMC_Structures (~20s) y Liquidity (~11s) recalculando todo el histórico,
# no aparecía NINGUNA ventana durante 40-70s — el proceso está vivo y
# trabajando, pero como no hay nada en pantalla, parece colgado (confirmado
# con /mnt/wslg/weston.log: la ventana real no se registra hasta ese punto).
# Ahora se crea la ventana primero y se muestra un aviso de carga para que
# el usuario vea la app responder de inmediato; el cálculo sigue tardando
# lo mismo, pero ya no da la impresión de estar trabada.
my $mw = MainWindow->new();
$mw->title('Motor de Charting - TradingView simple');
$mw->configure(-background => '#1e222d');
$mw->geometry('640x140');
my $loading = $mw->Label(
    -text       => "Cargando indicadores (SMC Structures, Liquidity, ZigZag)...\n"
                 . "Puede tardar cerca de un minuto con historiales grandes.",
    -font       => ['Arial', 11],
    -background => '#1e222d',
    -foreground => '#b2b5be',
    -justify    => 'center',
)->pack(-expand => 1, -fill => 'both', -padx => 20, -pady => 20);
$mw->update;   # forzar el pintado inmediato antes de bloquear en el cálculo

# ─── Indicadores ─────────────────────────────────────────────────────────────

my $indicators = Market::IndicatorManager->new();
$indicators->register('ATR', Market::Indicators::ATR->new(period => 14));
# PDF 4.1: "valor inicial recomendado k = 3" para la profundidad de Swing Points
$indicators->register('SMC_Structures', Market::Indicators::SMC_Structures->new(depth => 5));
# PDF 4.1/4.2/4.3: k=3, tolerancia EQH/EQL=ATR*0.10, N=3 velas para Run, 3 velas para Grab
$indicators->register('Liquidity', Market::Indicators::Liquidity->new(depth => 3));
$indicators->register('ZigZagMTF',    Market::Indicators::ZigZagMTF->new());
$indicators->register('ZigZagVolume', Market::Indicators::ZigZagVolume->new());
# Anchored VWAP — arranca SIN anchor (no dibuja nada hasta que el usuario
# hace clic con el botón "VWAP Anclado").
$indicators->register('VWAP', Market::Indicators::VWAP->new());
# Anchored Volume Profile — arranca SIN perfiles (no dibuja nada hasta que el
# usuario ancla con el botón "Perfil Volumen").
$indicators->register('VolumeProfile', Market::Indicators::VolumeProfile->new());
# Supply/Demand Zones (DIY Custom Strategy Builder [ZP]) — defaults del script:
# Swing Length=10, History=20, Box Width=2.5, ATR(50).
$indicators->register('SupplyDemand', Market::Indicators::SupplyDemand->new());
$indicators->update_last($market);

$loading->destroy;

my $chart = Market::ChartEngine->new(
    mw         => $mw,
    market     => $market,
    indicators => $indicators,
);
$chart->run();
