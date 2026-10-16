import Toybox.ActivityMonitor;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

// Today: steps, floors and intensity minutes as rings, calories and
// distance, and the last seven days of steps.
class TodayApp extends Application.AppBase {
    function initialize() { AppBase.initialize(); }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new TodayView()];
    }

    (:glance)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new TodayGlance()];
    }
}

// Steps for the last seven days, oldest first, today last.
(:glance)
function weekSteps() as Array<Number?> {
    var days = [null, null, null, null, null, null, HubData.steps()] as Array<Number?>;
    var history = ActivityMonitor.getHistory();
    if (history != null) {
        for (var i = 0; i < history.size(); i++) {
            var entry = history[i];
            if (entry.startOfDay == null || entry.steps == null) { continue; }
            var ago = HubData.daysAgo(entry.startOfDay as Time.Moment);
            if (ago >= 1 && ago <= 6) { days[6 - ago] = entry.steps; }
        }
    }
    return days;
}

(:glance)
function floors() as Number {
    var climbed = ActivityMonitor.getInfo().floorsClimbed;
    return climbed == null ? 0 : climbed;
}

(:glance)
class TodayGlance extends WatchUi.GlanceView {
    function initialize() { GlanceView.initialize(); }

    function onUpdate(dc as Dc) as Void {
        var steps = HubData.steps();
        var sub = floors().format("%d") + " floors  " + HubData.activeMinutes().format("%d") + " int min";
        Card.glance(dc, "TODAY", steps.format("%d"), "steps", sub, Draw.GREEN);
        var goal = HubData.stepGoal();
        Chart.bars(dc, Card.chartX(dc), Card.chartY(dc), Card.chartW(dc), Card.chartH(dc), weekSteps(), goal * 3 / 2, goal, Draw.GREEN);
    }
}

class TodayView extends WatchUi.View {
    function initialize() { View.initialize(); }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        Card.screen(dc, "TODAY", Draw.GREEN);

        // Three rings: steps (outer), floors, intensity minutes this week (inner).
        var info = ActivityMonitor.getInfo();
        var steps = HubData.steps();
        var floorGoal = info.floorsClimbedGoal == null || info.floorsClimbedGoal <= 0 ? 10 : info.floorsClimbedGoal;
        var ry = h * 33 / 100;
        ring(dc, cx, ry, 74, steps.toFloat() / HubData.stepGoal().toFloat(), Draw.GREEN);
        ring(dc, cx, ry, 60, floors().toFloat() / floorGoal.toFloat(), Draw.TEAL);
        ring(dc, cx, ry, 46, HubData.activeMinutes().toFloat() / HubData.activeMinutesGoal().toFloat(), Draw.INDIGO);
        dc.setColor(Draw.WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, ry - dc.getFontHeight(Graphics.FONT_SMALL) / 2, Graphics.FONT_SMALL, compact(steps), Graphics.TEXT_JUSTIFY_CENTER);

        var calories = info.calories == null ? 0 : info.calories;
        Card.stats3(dc, h * 51 / 100,
            [floors().format("%d"), "FLOORS"],
            [calories.format("%d"), "KCAL"],
            [distance(info.distance), System.getDeviceSettings().distanceUnits == System.UNIT_METRIC ? "KM" : "MI"],
            [Draw.TEAL, Draw.ORANGE, Draw.WHITE]);

        // Seven days of steps; bars at or over the goal are bright.
        var goal = HubData.stepGoal();
        var bx = w * 20 / 100;
        var bw = w * 60 / 100;
        var by = h * 69 / 100;
        var bh = h * 13 / 100;
        Chart.bars(dc, bx, by, bw, bh, weekSteps(), goal * 3 / 2, goal, Draw.GREEN);
        Card.timeAxis(dc, bx, by + bh + 4, bw, "-6D", "TODAY");
    }

    // Track plus progress, starting at 12 o'clock and going clockwise.
    private function ring(dc as Dc, x as Number, y as Number, r as Number, fraction as Float, color as Number) as Void {
        dc.setPenWidth(10);
        dc.setColor(Chart.dim(color, 25), Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(x, y, r);
        if (fraction >= 1.0) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(x, y, r);
        } else if (fraction > 0.01) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(x, y, r, Graphics.ARC_CLOCKWISE, 90, Draw.wrap(90 - (360 * fraction).toNumber()));
        }
        dc.setPenWidth(1);
    }

    private function compact(steps as Number) as String {
        return steps < 10000 ? steps.format("%d") : (steps / 1000).format("%d") + "." + ((steps % 1000) / 100).format("%d") + "k";
    }

    // ActivityMonitor distance is in centimeters.
    private function distance(cm as Number?) as String {
        if (cm == null) { return "0.0"; }
        var km = cm / 100000.0;
        var value = System.getDeviceSettings().distanceUnits == System.UNIT_METRIC ? km : km * 0.621371;
        return value.format("%.1f");
    }
}
