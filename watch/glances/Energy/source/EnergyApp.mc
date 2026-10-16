import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;

// Energy: body battery now, how much it charged and drained since midnight,
// and the last 24 hours as a curve.
class EnergyApp extends Application.AppBase {
    function initialize() { AppBase.initialize(); }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new EnergyView()];
    }

    (:glance)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new EnergyGlance()];
    }
}

// Charged and drained since midnight: the sum of rises and of falls between consecutive bins.
(:glance)
function energyToday() as [Number, Number] {
    var start = Time.today().value();
    var now = Time.now().value();
    var day = Series.readWindow(:bodyBattery, start, now, now - start + 60, 96);
    var charged = 0;
    var drained = 0;
    var prev = null as Number?;
    for (var i = 0; i < day.values.size(); i++) {
        var v = day.values[i];
        if (v == null) { continue; }
        if (prev != null) {
            if (v > prev) { charged += v - prev; } else { drained += prev - v; }
        }
        prev = v;
    }
    return [charged, drained];
}

(:glance)
class EnergyGlance extends WatchUi.GlanceView {
    function initialize() { GlanceView.initialize(); }

    function onUpdate(dc as Dc) as Void {
        var series = Series.read(:bodyBattery, 12 * 3600, 36);
        var now = HubData.bodyBattery();
        if (now == null) { now = series.last; }
        var today = energyToday();
        Card.glance(dc, "BODY BATTERY", Draw.orDash(now), "", "+" + today[0].format("%d") + "  -" + today[1].format("%d") + " today", Draw.TEAL);
        Chart.line(dc, Card.chartX(dc), Card.chartY(dc), Card.chartW(dc), Card.chartH(dc), series.values, 0, 100, Draw.TEAL);
    }
}

class EnergyView extends WatchUi.View {
    function initialize() { View.initialize(); }

    function onUpdate(dc as Dc) as Void {
        var h = dc.getHeight();
        Card.screen(dc, "BODY BATTERY", Draw.TEAL);

        var series = Series.read(:bodyBattery, 24 * 3600, 72);
        var now = HubData.bodyBattery();
        if (now == null) { now = series.last; }
        Card.hero(dc, h * 12 / 100, Draw.orDash(now), "/ 100", Draw.WHITE);

        var x = Card.chartLeft(dc);
        var w = Card.chartWidth(dc);
        var y = h * 38 / 100;
        var ch = h * 24 / 100;
        // Faint guides at 25, 50 and 75.
        for (var level = 25; level < 100; level += 25) {
            Chart.reference(dc, x, y, w, ch, level, 0, 100, Draw.FAINT);
        }
        Chart.line(dc, x, y, w, ch, series.values, 0, 100, Draw.TEAL);
        Card.timeAxis(dc, x, y + ch + 4, w, "-24H", "NOW");

        var today = energyToday();
        Card.stats3(dc, h * 70 / 100,
            ["+" + today[0].format("%d"), "CHARGED"],
            [Draw.orDash(series.max), "HIGH"],
            ["-" + today[1].format("%d"), "DRAINED"],
            [Draw.GREEN, Draw.WHITE, Draw.ORANGE]);

        dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, h * 86 / 100, Graphics.FONT_XTINY, "LOW " + Draw.orDash(series.min) + " IN 24H", Graphics.TEXT_JUSTIFY_CENTER);
    }
}
