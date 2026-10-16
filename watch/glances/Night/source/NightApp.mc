import Toybox.ActivityMonitor;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.UserProfile;
import Toybox.WatchUi;

// Night: what last night did for you. After a sync the phone writes the hub's
// sleep score, stages and overnight HRV into this app's settings (Pushed);
// then the window is the detected sleep. Without them (no sync since waking)
// it falls back to the sleep window set on the watch (bed and wake time) and
// shows body battery gained, lowest heart rate, average SpO2 and stress.
class NightApp extends Application.AppBase {
    function initialize() { AppBase.initialize(); }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new NightView()];
    }

    (:glance)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new NightGlance()];
    }
}

// A pushed night counts as last night until 20 hours after waking.
const HUB_NIGHT_AGE = 20 * 3600;

// True when the phone pushed a night that is still last night.
(:glance)
function hubNight() as Boolean {
    return Pushed.fresh("sEnd", HUB_NIGHT_AGE) && Pushed.number("sStart") != null;
}

// [bed, wake] in epoch seconds for the most recent completed night: the hub's
// detected sleep when pushed, else the watch's sleep window, else 23:00-07:00.
(:glance)
function nightWindow() as [Number, Number] {
    if (hubNight()) { return [Pushed.number("sStart") as Number, Pushed.number("sEnd") as Number]; }
    var bed = 23 * 3600;
    var wake = 7 * 3600;
    var profile = UserProfile.getProfile();
    if (profile != null) {
        if (profile.sleepTime != null) { bed = (profile.sleepTime as Time.Duration).value(); }
        if (profile.wakeTime != null) { wake = (profile.wakeTime as Time.Duration).value(); }
    }
    var midnight = Time.today().value();
    var wakeAt = midnight + wake;
    if (Time.now().value() < wakeAt) { wakeAt -= Gregorian.SECONDS_PER_DAY; }
    var wakeMidnight = wakeAt - wake;
    var bedAt = bed > wake ? wakeMidnight - Gregorian.SECONDS_PER_DAY + bed : wakeMidnight + bed;
    return [bedAt, wakeAt];
}

// Body battery at wake minus at bed.
(:glance)
function nightCharge(window as [Number, Number]) as Number? {
    var lookback = Time.now().value() - window[0] + 600;
    var battery = Series.readWindow(:bodyBattery, window[0], window[1], lookback, 16);
    var first = null as Number?;
    for (var i = 0; i < battery.values.size(); i++) {
        if (battery.values[i] != null) { first = battery.values[i]; break; }
    }
    var last = battery.last;
    return (first == null || last == null) ? null : last - first;
}

// Time asleep: the hub's stages without awake, else the whole window.
(:glance)
function asleep(window as [Number, Number]) as Number {
    var total = 0;
    var any = false;
    var keys = ["deep", "light", "rem"];
    for (var i = 0; i < keys.size(); i++) {
        var minutes = Pushed.number(keys[i]);
        if (minutes != null) { total += minutes * 60; any = true; }
    }
    return any ? total : window[1] - window[0];
}

(:glance)
function signed(value as Number?) as String {
    if (value == null) { return "--"; }
    return (value > 0 ? "+" : "") + value.format("%d");
}

(:glance)
class NightGlance extends WatchUi.GlanceView {
    function initialize() { GlanceView.initialize(); }

    function onUpdate(dc as Dc) as Void {
        var window = nightWindow();
        var lookback = Time.now().value() - window[0] + 600;
        var heart = Series.readWindow(:heartRate, window[0], window[1], lookback, 32);
        var score = hubNight() ? Pushed.number("score") : null;
        if (score != null) {
            var hrv = Pushed.number("hrv");
            var sub = Card.hours(asleep(window)) + (hrv == null ? "" : "  HRV " + hrv.format("%d"));
            Card.glance(dc, "LAST NIGHT", score.format("%d"), "sleep", sub, Draw.INDIGO);
        } else {
            var sub = (heart.min == null ? "" : "low HR " + (heart.min as Number).format("%d") + "  ") + Card.hours(window[1] - window[0]);
            Card.glance(dc, "LAST NIGHT", signed(nightCharge(window)), "body battery", sub, Draw.INDIGO);
        }
        if (heart.min != null && heart.max != null) {
            Chart.line(dc, Card.chartX(dc), Card.chartY(dc), Card.chartW(dc), Card.chartH(dc),
                heart.values, (heart.min as Number) - 3, (heart.max as Number) + 3, Draw.INDIGO);
        }
    }
}

class NightView extends WatchUi.View {
    function initialize() { View.initialize(); }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        Card.screen(dc, "LAST NIGHT", Draw.INDIGO);

        var window = nightWindow();
        var lookback = Time.now().value() - window[0] + 600;
        var hub = hubNight();
        var score = hub ? Pushed.number("score") : null;
        if (score != null) {
            Card.hero(dc, h * 12 / 100, score.format("%d"), "sleep score", Draw.TEAL);
        } else {
            Card.hero(dc, h * 12 / 100, signed(nightCharge(window)), "body battery", Draw.TEAL);
        }

        dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 31 / 100, Graphics.FONT_XTINY, clock(window[0]) + " - " + clock(window[1]) + "  ·  " + Card.hours(hub ? asleep(window) : window[1] - window[0]), Graphics.TEXT_JUSTIFY_CENTER);
        if (hub) { stagesBar(dc, Card.chartLeft(dc), h * 37 / 100, Card.chartWidth(dc)); }

        // Overnight heart rate: the dip shows how well you recovered.
        var heart = Series.readWindow(:heartRate, window[0], window[1], lookback, 60);
        var x = Card.chartLeft(dc);
        var cw = Card.chartWidth(dc);
        var y = h * 40 / 100;
        var ch = h * 20 / 100;
        if (heart.min != null && heart.max != null) {
            Chart.line(dc, x, y, cw, ch, heart.values, (heart.min as Number) - 3, (heart.max as Number) + 3, Draw.INDIGO);
        } else {
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, y + ch / 2 - 10, Graphics.FONT_XTINY, "No overnight readings", Graphics.TEXT_JUSTIFY_CENTER);
        }
        Card.timeAxis(dc, x, y + ch + 4, cw, "BED", "WAKE");

        var oxygen = Series.readWindow(:oxygen, window[0], window[1], lookback, 8);
        var stress = Series.readWindow(:stress, window[0], window[1], lookback, 8);
        var hrv = hub ? Pushed.number("hrv") : null;
        if (hrv != null) {
            // The hub's overnight HRV and its status take the stress slot; body battery moves here.
            var status = Pushed.text("hrvSt");
            Card.stats3(dc, h * 69 / 100,
                [hrv.format("%d") + "ms", status == null ? "HRV" : "HRV " + status.toUpper()],
                [Draw.orDash(heart.min), "LOW HR"],
                [signed(nightCharge(window)), "BATTERY"],
                [status != null && status.equals("balanced") ? Draw.GREEN : Draw.ORANGE, Draw.RED, Draw.TEAL]);
        } else {
            Card.stats3(dc, h * 69 / 100,
                [Draw.orDash(heart.min), "LOW HR"],
                [oxygen.average() == null ? "--" : (oxygen.average() as Number).format("%d") + "%", "SPO2"],
                [Draw.orDash(stress.average()), "STRESS"],
                [Draw.RED, Draw.TEAL, Draw.ORANGE]);
        }

        var resp = ActivityMonitor.getInfo().respirationRate;
        var deep = hub ? Pushed.number("deep") : null;
        var rem = hub ? Pushed.number("rem") : null;
        if (deep != null && rem != null) {
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 86 / 100, Graphics.FONT_XTINY, "DEEP " + Card.hours(deep * 60) + "  REM " + Card.hours(rem * 60), Graphics.TEXT_JUSTIFY_CENTER);
        } else if (resp != null) {
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 86 / 100, Graphics.FONT_XTINY, "BREATHING " + resp.format("%d") + " BRPM", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // Deep, light, REM and awake as one bar, in the hub's minutes per stage.
    private function stagesBar(dc as Dc, x as Number, y as Number, width as Number) as Void {
        var stages = [Pushed.number("deep"), Pushed.number("light"), Pushed.number("rem"), Pushed.number("awake")];
        var colors = [Draw.INDIGO, Draw.TEAL, 0xBF5AF2, Draw.ORANGE];
        var total = 0;
        for (var i = 0; i < stages.size(); i++) { if (stages[i] != null) { total += stages[i] as Number; } }
        if (total <= 0) { return; }
        var at = x;
        for (var i = 0; i < stages.size(); i++) {
            if (stages[i] == null) { continue; }
            var part = (stages[i] as Number) * width / total;
            dc.setColor(colors[i], Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(at, y, part, 6);
            at += part;
        }
    }

    private function clock(epoch as Number) as String {
        var info = Gregorian.info(new Time.Moment(epoch), Time.FORMAT_SHORT);
        return info.hour.format("%d") + ":" + info.min.format("%02d");
    }
}
