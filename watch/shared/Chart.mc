import Toybox.Graphics;
import Toybox.Lang;

// Charts for glances and detail screens: a line over a dimmed fill, and bars.
(:glance)
module Chart {

    // The same hue at a fraction of its brightness, for fills and tracks.
    function dim(color as Number, percent as Number) as Number {
        var r = ((color >> 16) & 0xFF) * percent / 100;
        var g = ((color >> 8) & 0xFF) * percent / 100;
        var b = (color & 0xFF) * percent / 100;
        return (r << 16) | (g << 8) | b;
    }

    // Line of binned values scaled between lo and hi, with a dim fill underneath.
    // Missing bins (null) break the line rather than drawing across the gap.
    function line(dc as Dc, x as Number, y as Number, w as Number, h as Number,
                  values as Array<Number?>, lo as Number, hi as Number, color as Number) as Void {
        var n = values.size();
        if (n == 0) { return; }
        if (hi <= lo) { hi = lo + 1; }
        var step = n > 1 ? w.toFloat() / (n - 1) : 0.0;
        var barW = (step + 1).toNumber();
        if (barW < 1) { barW = 1; }
        var fill = dim(color, 30);

        var px = null as Number?;
        var py = null as Number?;
        for (var i = 0; i < n; i++) {
            var v = values[i];
            if (v == null) {
                px = null;
                continue;
            }
            var cx = x + (step * i).toNumber();
            var cy = yFor(v, y, h, lo, hi);
            dc.setColor(fill, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(cx - barW / 2, cy, barW, y + h - cy);
            if (px != null && py != null) {
                dc.setColor(color, Graphics.COLOR_TRANSPARENT);
                dc.setPenWidth(2);
                dc.drawLine(px, py, cx, cy);
            }
            px = cx;
            py = cy;
        }
        // A dot on the newest value.
        if (px != null && py != null) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(px, py, 3);
        }
        dc.setPenWidth(1);
    }

    // Horizontal dashed reference line at `value` (e.g. resting heart rate).
    function reference(dc as Dc, x as Number, y as Number, w as Number, h as Number, value as Number, lo as Number, hi as Number, color as Number) as Void {
        if (hi <= lo) { hi = lo + 1; }
        var ry = yFor(value, y, h, lo, hi);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        for (var dx = 0; dx < w; dx += 8) {
            dc.drawLine(x + dx, ry, x + dx + 4, ry);
        }
    }

    // Vertical bars, one per value, scaled to `hi`. The last bar (today) is drawn in full color, the rest dimmed.
    // A value at or above `goal` (when given) is drawn in full color too.
    function bars(dc as Dc, x as Number, y as Number, w as Number, h as Number,
                  values as Array<Number?>, hi as Number, goal as Number?, color as Number) as Void {
        var n = values.size();
        if (n == 0) { return; }
        if (hi <= 0) { hi = 1; }
        var slot = w / n;
        var barW = slot * 6 / 10;
        if (barW < 2) { barW = 2; }
        for (var i = 0; i < n; i++) {
            var v = values[i];
            var bx = x + i * slot + (slot - barW) / 2;
            dc.setColor(Draw.FAINT, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(bx, y, barW, h, barW / 2);
            if (v == null || v <= 0) { continue; }
            var bh = (h.toLong() * (v > hi ? hi : v) / hi).toNumber();
            if (bh < barW) { bh = barW; }
            var strong = i == n - 1 || (goal != null && v >= goal);
            dc.setColor(strong ? color : dim(color, 55), Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(bx, y + h - bh, barW, bh, barW / 2);
        }
    }

    function yFor(v as Number, y as Number, h as Number, lo as Number, hi as Number) as Number {
        var cy = y + h - ((v - lo).toLong() * h / (hi - lo)).toNumber();
        if (cy < y) { cy = y; }
        if (cy > y + h) { cy = y + h; }
        return cy;
    }
}
