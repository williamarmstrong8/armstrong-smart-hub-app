import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

// Heart: current heart rate over the last 4 hours in the glance,
// the last 24 hours with resting heart rate in the full screen.
class HeartApp extends Application.AppBase {
    function initialize() { AppBase.initialize(); }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new HeartView()];
    }

    (:glance)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new HeartGlance()];
    }
}

(:glance)
class HeartGlance extends WatchUi.GlanceView {
    function initialize() { GlanceView.initialize(); }

    function onUpdate(dc as Dc) as Void {
        var series = Series.read(:heartRate, 4 * 3600, 40);
        var now = HubData.heartRate();
        if (now == null) { now = series.last; }
        var rest = HubData.restingHeartRate();
        Card.glance(dc, "HEART", Draw.orDash(now), "bpm", rest == null ? "" : "rest " + rest.format("%d"), Draw.RED);
        if (series.min != null && series.max != null) {
            Chart.line(dc, Card.chartX(dc), Card.chartY(dc), Card.chartW(dc), Card.chartH(dc),
                series.values, (series.min as Number) - 5, (series.max as Number) + 5, Draw.RED);
        }
    }
}

class HeartView extends WatchUi.View {
    private var _timer as Timer.Timer?;

    function initialize() { View.initialize(); }

    // Live heart rate: redraw every 5 seconds while open.
    function onShow() as Void {
        _timer = new Timer.Timer();
        (_timer as Timer.Timer).start(method(:tick), 5000, true);
    }

    function onHide() as Void {
        if (_timer != null) { (_timer as Timer.Timer).stop(); }
        _timer = null;
    }

    function tick() as Void { WatchUi.requestUpdate(); }

    function onUpdate(dc as Dc) as Void {
        var h = dc.getHeight();
        Card.screen(dc, "HEART RATE", Draw.RED);

        var series = Series.read(:heartRate, 24 * 3600, 72);
        var now = HubData.heartRate();
        if (now == null) { now = series.last; }
        Card.hero(dc, h * 12 / 100, Draw.orDash(now), "bpm", Draw.WHITE);

        var x = Card.chartLeft(dc);
        var w = Card.chartWidth(dc);
        var y = h * 38 / 100;
        var ch = h * 24 / 100;
        var rest = HubData.restingHeartRate();
        if (series.min != null && series.max != null) {
            var lo = (series.min as Number) - 5;
            var hi = (series.max as Number) + 5;
            if (rest != null) { Chart.reference(dc, x, y, w, ch, rest, lo, hi, Draw.INDIGO); }
            Chart.line(dc, x, y, w, ch, series.values, lo, hi, Draw.RED);
        } else {
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(dc.getWidth() / 2, y + ch / 2 - 10, Graphics.FONT_XTINY, "No readings yet", Graphics.TEXT_JUSTIFY_CENTER);
        }
        Card.timeAxis(dc, x, y + ch + 4, w, "-24H", "NOW");

        Card.stats3(dc, h * 70 / 100,
            [Draw.orDash(series.min), "LOW"],
            [Draw.orDash(rest), "RESTING"],
            [Draw.orDash(series.max), "HIGH"],
            [Draw.WHITE, Draw.INDIGO, Draw.RED]);

        var avgRest = HubData.averageRestingHeartRate();
        if (avgRest != null) {
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(dc.getWidth() / 2, h * 86 / 100, Graphics.FONT_XTINY, "7-DAY RESTING " + avgRest.format("%d"), Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
}
