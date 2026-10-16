import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;

// Stress: the current level, the last hours as a curve, and how today
// splits between rest, low, medium and high (Garmin's 0-25-50-75-100 bands).
class StressApp extends Application.AppBase {
    function initialize() { AppBase.initialize(); }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new StressView()];
    }

    (:glance)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new StressGlance()];
    }
}

(:glance)
function stressLevel(value as Number?) as String {
    if (value == null) { return ""; }
    if (value <= 25) { return "resting"; }
    if (value <= 50) { return "low"; }
    if (value <= 75) { return "medium"; }
    return "high";
}

(:glance)
class StressGlance extends WatchUi.GlanceView {
    function initialize() { GlanceView.initialize(); }

    function onUpdate(dc as Dc) as Void {
        var series = Series.read(:stress, 4 * 3600, 40);
        var now = HubData.stress();
        if (now == null) { now = series.last; }
        Card.glance(dc, "STRESS", Draw.orDash(now), "", stressLevel(now), Draw.ORANGE);
        Chart.line(dc, Card.chartX(dc), Card.chartY(dc), Card.chartW(dc), Card.chartH(dc), series.values, 0, 100, Draw.ORANGE);
    }
}

class StressView extends WatchUi.View {
    const BAND_COLORS = [0x0A84FF, 0xFFD60A, Draw.ORANGE, Draw.RED] as Array<Number>;
    const BAND_NAMES = ["REST", "LOW", "MED", "HIGH"] as Array<String>;

    function initialize() { View.initialize(); }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        Card.screen(dc, "STRESS", Draw.ORANGE);

        var series = Series.read(:stress, 24 * 3600, 72);
        var now = HubData.stress();
        if (now == null) { now = series.last; }
        Card.hero(dc, h * 12 / 100, Draw.orDash(now), stressLevel(now), Draw.WHITE);

        var x = Card.chartLeft(dc);
        var cw = Card.chartWidth(dc);
        var y = h * 38 / 100;
        var ch = h * 22 / 100;
        Chart.line(dc, x, y, cw, ch, series.values, 0, 100, Draw.ORANGE);
        Card.timeAxis(dc, x, y + ch + 4, cw, "-24H", "NOW");

        // Today's split by band, as one stacked bar with the share of each under it.
        var bands = todayBands();
        var total = bands[0] + bands[1] + bands[2] + bands[3];
        var by = h * 70 / 100;
        var bx = w * 18 / 100;
        var bw = w * 64 / 100;
        if (total == 0) {
            dc.setColor(Draw.FAINT, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(bx, by, bw, 8, 4);
        } else {
            var cursor = bx;
            for (var i = 0; i < 4; i++) {
                var part = (bw.toLong() * bands[i] / total).toNumber();
                if (i == 3) { part = bx + bw - cursor; }
                if (part > 0) {
                    dc.setColor(BAND_COLORS[i], Graphics.COLOR_TRANSPARENT);
                    dc.fillRectangle(cursor, by, part, 8);
                }
                cursor += part;
            }
        }
        var slot = bw / 4;
        for (var i = 0; i < 4; i++) {
            var lx = bx + slot * i + slot / 2;
            var share = total == 0 ? "--" : (bands[i] * 100 / total).format("%d") + "%";
            dc.setColor(BAND_COLORS[i], Graphics.COLOR_TRANSPARENT);
            dc.drawText(lx, by + 14, Graphics.FONT_XTINY, share, Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(lx, by + 14 + dc.getFontHeight(Graphics.FONT_XTINY) - 4, Graphics.FONT_XTINY, BAND_NAMES[i], Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Samples since midnight in each band: rest 0-25, low 26-50, medium 51-75, high 76-100.
    private function todayBands() as Array<Number> {
        var bands = [0, 0, 0, 0] as Array<Number>;
        var start = Time.today().value();
        var iterator = Series.history(:stress, Time.now().value() - start + 60);
        if (iterator == null) { return bands; }
        var sample = iterator.next();
        while (sample != null) {
            var data = sample.data;
            var when = sample.when;
            if (data != null && when != null && when.value() >= start) {
                var v = (data as Numeric).toNumber();
                if (v >= 0 && v <= 100) {
                    var band = v <= 25 ? 0 : (v <= 50 ? 1 : (v <= 75 ? 2 : 3));
                    bands[band] += 1;
                }
            }
            sample = iterator.next();
        }
        return bands;
    }
}
