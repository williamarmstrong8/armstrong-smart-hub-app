import Toybox.ActivityMonitor;
import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.UserProfile;
import Toybox.WatchUi;

// Armstrong Minimal - v1, local data only.
// Black background, no cards, no glow, thin lines, color only on data.
class ArmstrongFaceView extends WatchUi.WatchFace {

    // Palette (matches the app: green = progress, red = heart, indigo = resting)
    const GREEN  = 0x34C759;
    const RED    = 0xFF453A;
    const INDIGO = 0x5E5CE6;
    const GRAY   = 0x8E8E93;
    const FAINT  = 0x3A3A3C;
    const WHITE  = 0xFFFFFF;

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

        var clock = System.getClockTime();
        var hour = clock.hour;
        if (!System.getDeviceSettings().is24Hour) {
            hour = hour % 12;
            if (hour == 0) { hour = 12; }
        }
        var timeStr = hour.format("%d") + ":" + clock.min.format("%02d");

        if (_lowPower) {
            drawLowPower(dc, w, h, timeStr, clock.min);
            return;
        }

        // Date, small and gray
        var now = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        var dateStr = (now.day_of_week as String).toUpper() + " " + now.day.format("%d");
        dc.setColor(GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.15, Graphics.FONT_XTINY, dateStr, Graphics.TEXT_JUSTIFY_CENTER);

        // Big time
        dc.setColor(WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.22, Graphics.FONT_NUMBER_HOT, timeStr, Graphics.TEXT_JUSTIFY_CENTER);

        // Week row (v1: a circle fills when that day met the step goal)
        drawWeekRow(dc, cx, (h * 0.60).toNumber());

        // Steps bar with count
        var info = ActivityMonitor.getInfo();
        drawSteps(dc, cx, (h * 0.70).toNumber(), info);

        // Heart + resting
        drawVitals(dc, cx, (h * 0.82).toNumber());
    }

    // Always-on: dim time only, shifted a little each minute so no pixel stays lit.
    private function drawLowPower(dc as Dc, w as Number, h as Number, timeStr as String, minute as Number) as Void {
        var jitterX = ((minute % 5) - 2) * 6;
        var jitterY = ((minute % 3) - 1) * 6;
        dc.setColor(GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2 + jitterX, h * 0.34 + jitterY, Graphics.FONT_NUMBER_HOT, timeStr, Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function drawWeekRow(dc as Dc, cx as Number, y as Number) as Void {
        var r = 11;
        var gap = 38;
        var startX = cx - 3 * gap;
        var met = weekGoalMet();
        for (var i = 0; i < 7; i++) {
            var x = startX + i * gap;
            if (met[i]) {
                dc.setColor(GREEN, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(x, y, r);
                // thin check mark in black
                dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
                dc.setPenWidth(2);
                dc.drawLine(x - 5, y, x - 1, y + 4);
                dc.drawLine(x - 1, y + 4, x + 5, y - 4);
            } else {
                dc.setColor(FAINT, Graphics.COLOR_TRANSPARENT);
                dc.setPenWidth(2);
                dc.drawCircle(x, y, r);
            }
        }
        dc.setPenWidth(1);
    }

    // Index 0 = six days ago ... index 6 = today.
    private function weekGoalMet() as Array<Boolean> {
        var met = [false, false, false, false, false, false, false] as Array<Boolean>;
        var info = ActivityMonitor.getInfo();
        if (info.steps != null && info.stepGoal != null && info.stepGoal > 0) {
            met[6] = info.steps >= info.stepGoal;
        }
        var history = ActivityMonitor.getHistory();
        if (history != null) {
            var todayStart = Time.today();
            for (var i = 0; i < history.size(); i++) {
                var entry = history[i];
                if (entry.startOfDay == null || entry.steps == null || entry.stepGoal == null) { continue; }
                var daysAgo = (todayStart.value() - entry.startOfDay.value()) / Gregorian.SECONDS_PER_DAY;
                if (daysAgo >= 1 && daysAgo <= 6) {
                    met[6 - daysAgo] = entry.steps >= entry.stepGoal;
                }
            }
        }
        return met;
    }

    private function drawSteps(dc as Dc, cx as Number, y as Number, info as ActivityMonitor.Info) as Void {
        var steps = info.steps;
        var goal = info.stepGoal;
        if (steps == null) { steps = 0; }
        if (goal == null || goal <= 0) { goal = 10000; }

        var barW = 220;
        var x0 = cx - barW / 2;
        var frac = steps.toFloat() / goal.toFloat();
        if (frac > 1.0) { frac = 1.0; }

        dc.setColor(FAINT, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x0, y, barW, 4, 2);
        if (frac > 0) {
            dc.setColor(GREEN, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(x0, y, (barW * frac).toNumber(), 4, 2);
        }
        dc.setColor(WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y + 8, Graphics.FONT_XTINY, steps.format("%d"), Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function drawVitals(dc as Dc, cx as Number, y as Number) as Void {
        var hr = null;
        var act = Activity.getActivityInfo();
        if (act != null) { hr = act.currentHeartRate; }

        var resting = null;
        var profile = UserProfile.getProfile();
        if (profile != null) { resting = profile.restingHeartRate; }

        // Heart icon (red) + current HR, left of center
        var hx = cx - 60;
        drawHeart(dc, hx, y + 8, RED);
        dc.setColor(WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(hx + 16, y - 4, Graphics.FONT_XTINY, hr == null ? "--" : hr.format("%d"), Graphics.TEXT_JUSTIFY_LEFT);

        // Resting HR (indigo dot + number), right of center
        var rx = cx + 22;
        dc.setColor(INDIGO, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(rx, y + 8, 6);
        dc.setPenWidth(1);
        dc.setColor(WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rx + 14, y - 4, Graphics.FONT_XTINY, resting == null ? "--" : resting.format("%d"), Graphics.TEXT_JUSTIFY_LEFT);
    }

    // Outline heart from two arcs and a point, thin stroke.
    private function drawHeart(dc as Dc, x as Number, y as Number, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(x - 4, y - 2, 4);
        dc.drawCircle(x + 4, y - 2, 4);
        dc.drawLine(x - 7, y + 1, x, y + 9);
        dc.drawLine(x + 7, y + 1, x, y + 9);
        dc.setPenWidth(1);
    }
}
