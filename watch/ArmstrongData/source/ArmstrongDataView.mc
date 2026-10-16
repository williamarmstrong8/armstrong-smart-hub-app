import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Armstrong Data: the minimal face plus everything worth a glance.
// Left bezel gauge = steps toward the goal, right bezel gauge = body battery.
class ArmstrongDataView extends WatchUi.WatchFace {

    private var _lowPower as Boolean = false;

    function initialize() {
        WatchFace.initialize();
    }

    function onEnterSleep() as Void {
        _lowPower = true;
        WatchUi.requestUpdate();
    }

    function onExitSleep() as Void {
        _lowPower = false;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var timeStr = HubData.timeString();
        if (_lowPower) {
            Draw.lowPower(dc, timeStr, System.getClockTime().min);
            return;
        }

        // Bezel gauges: steps grow up the left side, body battery up the right.
        var r = cx - 8;
        var steps = HubData.steps();
        Draw.bezelArc(dc, cx, cy, r, 225, -90, steps.toFloat() / HubData.stepGoal().toFloat(), Draw.GREEN);
        var battery = HubData.bodyBattery();
        Draw.bezelArc(dc, cx, cy, r, 315, 90, battery == null ? 0.0 : battery.toFloat() / 100.0, Draw.TEAL);

        dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.12, Graphics.FONT_XTINY, HubData.dateString(), Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Draw.WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.17, Graphics.FONT_NUMBER_HOT, timeStr, Graphics.TEXT_JUSTIFY_CENTER);

        // What's next and the streak, then the workout week.
        var workouts = HubData.workouts();
        var line = workouts.next;
        if (workouts.streak > 1) { line += "  ·  " + workouts.streak.format("%d") + " DAYS"; }
        dc.setColor(Draw.GREEN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.465, Graphics.FONT_XTINY, line, Graphics.TEXT_JUSTIFY_CENTER);
        Draw.weekRow(dc, cx, (h * 0.575).toNumber(), workouts.week, 9, 32);

        // Stats row: steps, heart rate, body battery.
        var y = (h * 0.63).toNumber();
        Draw.stat(dc, cx - 100, y, steps.format("%d"), "STEPS", Draw.WHITE);
        Draw.stat(dc, cx, y, Draw.orDash(HubData.heartRate()), "BPM", Draw.RED);
        Draw.stat(dc, cx + 100, y, Draw.orDash(battery), "BODY", Draw.TEAL);

        // Second row: stress and this week's intensity minutes against the goal.
        y = (h * 0.76).toNumber();
        Draw.stat(dc, cx - 55, y, Draw.orDash(HubData.stress()), "STRESS", Draw.ORANGE);
        Draw.stat(dc, cx + 55, y, HubData.activeMinutes().format("%d") + "/" + HubData.activeMinutesGoal().format("%d"), "INT MIN", Draw.INDIGO);

        // Watch battery, small at the bottom.
        var charge = HubData.battery();
        dc.setColor(charge <= 15 ? Draw.RED : Draw.GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.89, Graphics.FONT_XTINY, charge.format("%d") + "%", Graphics.TEXT_JUSTIFY_CENTER);
    }
}
