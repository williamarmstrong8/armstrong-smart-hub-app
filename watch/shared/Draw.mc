import Toybox.Graphics;
import Toybox.Lang;

// Drawing shared by the faces. Black background, thin lines, color only on
// data, same palette as the app: green = progress, red = heart, indigo = resting.
(:glance)
module Draw {

    const GREEN  = 0x34C759;
    const RED    = 0xFF453A;
    const INDIGO = 0x5E5CE6;
    const TEAL   = 0x64D2FF;
    const ORANGE = 0xFF9F0A;
    const GRAY   = 0x8E8E93;
    const FAINT  = 0x3A3A3C;
    const WHITE  = 0xFFFFFF;

    // Seven circles, oldest first; filled green with a check when that day had a workout.
    // Today's empty circle is drawn brighter so the row reads left to right.
    function weekRow(dc as Dc, cx as Number, y as Number, week as Array<Boolean>, r as Number, gap as Number) as Void {
        var startX = cx - 3 * gap;
        for (var i = 0; i < 7; i++) {
            var x = startX + i * gap;
            if (week[i]) {
                dc.setColor(GREEN, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(x, y, r);
                dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
                dc.setPenWidth(2);
                dc.drawLine(x - r / 2, y, x - r / 10, y + r * 4 / 10);
                dc.drawLine(x - r / 10, y + r * 4 / 10, x + r / 2, y - r * 4 / 10);
            } else {
                dc.setColor(i == 6 ? GRAY : FAINT, Graphics.COLOR_TRANSPARENT);
                dc.setPenWidth(2);
                dc.drawCircle(x, y, r);
            }
        }
        dc.setPenWidth(1);
    }

    // Thin progress bar, track in faint gray.
    function bar(dc as Dc, x as Number, y as Number, width as Number, fraction as Float, color as Number) as Void {
        if (fraction > 1.0) { fraction = 1.0; }
        dc.setColor(FAINT, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x, y, width, 4, 2);
        var filled = (width * fraction).toNumber();
        if (filled > 0) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(x, y, filled, 4, 2);
        }
    }

    // A gauge along the bezel. Angles in degrees, 0 = 3 o'clock, counterclockwise.
    // The track runs from `from` to `from + span`; the fill grows from `from`.
    function bezelArc(dc as Dc, cx as Number, cy as Number, r as Number, from as Number, span as Number, fraction as Float, color as Number) as Void {
        if (fraction > 1.0) { fraction = 1.0; }
        if (fraction < 0.0) { fraction = 0.0; }
        var direction = span >= 0 ? Graphics.ARC_COUNTER_CLOCKWISE : Graphics.ARC_CLOCKWISE;
        dc.setPenWidth(6);
        dc.setColor(FAINT, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, r, direction, wrap(from), wrap(from + span));
        var filled = (span * fraction).toNumber();
        if (filled != 0) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, r, direction, wrap(from), wrap(from + filled));
        }
        dc.setPenWidth(1);
    }

    function wrap(degrees as Number) as Number {
        return ((degrees % 360) + 360) % 360;
    }

    // Outline heart from two circles and a point.
    function heart(dc as Dc, x as Number, y as Number, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(x - 4, y - 2, 4);
        dc.drawCircle(x + 4, y - 2, 4);
        dc.drawLine(x - 7, y + 1, x, y + 9);
        dc.drawLine(x + 7, y + 1, x, y + 9);
        dc.setPenWidth(1);
    }

    // Value with a small gray label underneath, centered on x.
    function stat(dc as Dc, x as Number, y as Number, value as String, label as String, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_TINY, value, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y + dc.getFontHeight(Graphics.FONT_TINY) - 4, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_CENTER);
    }

    function orDash(value as Number?) as String {
        return value == null ? "--" : value.format("%d");
    }

    // Always-on: dim time only, shifted a few pixels each minute so no pixel stays lit (AMOLED burn-in).
    function lowPower(dc as Dc, timeStr as String, minute as Number) as Void {
        var jitterX = ((minute % 5) - 2) * 6;
        var jitterY = ((minute % 3) - 1) * 6;
        dc.setColor(GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2 + jitterX, dc.getHeight() * 0.34 + jitterY, Graphics.FONT_NUMBER_HOT, timeStr, Graphics.TEXT_JUSTIFY_CENTER);
    }
}
