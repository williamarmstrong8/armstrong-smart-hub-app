import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Armstrong Minimal: date, big time, the workout week, steps, heart rate.
class ArmstrongFaceView extends WatchUi.WatchFace {

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

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var timeStr = HubData.timeString();
        if (_lowPower) {
            Draw.lowPower(dc, timeStr, System.getClockTime().min);
            return;
        }

        dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.15, Graphics.FONT_XTINY, HubData.dateString(), Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Draw.WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.22, Graphics.FONT_NUMBER_HOT, timeStr, Graphics.TEXT_JUSTIFY_CENTER);

        // Workout week, and what's next under it.
        var workouts = HubData.workouts();
        Draw.weekRow(dc, cx, (h * 0.58).toNumber(), workouts.week, 11, 38);
        var line = workouts.next;
        if (workouts.streak > 1) { line += "  ·  " + workouts.streak.format("%d") + " DAYS"; }
        dc.setColor(Draw.GREEN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.62, Graphics.FONT_XTINY, line, Graphics.TEXT_JUSTIFY_CENTER);

        // Steps bar with count.
        var steps = HubData.steps();
        var y = (h * 0.73).toNumber();
        Draw.bar(dc, cx - 110, y, 220, steps.toFloat() / HubData.stepGoal().toFloat(), Draw.GREEN);
        dc.setColor(Draw.WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y + 8, Graphics.FONT_XTINY, steps.format("%d"), Graphics.TEXT_JUSTIFY_CENTER);

        // Heart rate left of center, resting heart rate right.
        y = (h * 0.84).toNumber();
        var hx = cx - 60;
        Draw.heart(dc, hx, y + 8, Draw.RED);
        dc.setColor(Draw.WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(hx + 16, y - 4, Graphics.FONT_XTINY, Draw.orDash(HubData.heartRate()), Graphics.TEXT_JUSTIFY_LEFT);

        var rx = cx + 22;
        dc.setColor(Draw.INDIGO, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(rx, y + 8, 6);
        dc.setPenWidth(1);
        dc.setColor(Draw.WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rx + 14, y - 4, Graphics.FONT_XTINY, Draw.orDash(HubData.restingHeartRate()), Graphics.TEXT_JUSTIFY_LEFT);
    }
}
