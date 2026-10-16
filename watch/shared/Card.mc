import Toybox.Graphics;
import Toybox.Lang;

// Layout shared by the glances: the row in the glance loop, and the
// full screen that opens when you tap it. Same palette as the faces.
(:glance)
module Card {

    // Glance row: small gray label, big colored value with a unit, and a sub line.
    // The chart, if any, goes in the right part: see chartX / chartW.
    function glance(dc as Dc, label as String, value as String, unit as String, sub as String, color as Number) as Void {
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var labelH = dc.getFontHeight(Graphics.FONT_GLANCE);
        dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(0, 0, Graphics.FONT_GLANCE, label, Graphics.TEXT_JUSTIFY_LEFT);

        var valueY = labelH - 2;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(0, valueY, Graphics.FONT_GLANCE_NUMBER, value, Graphics.TEXT_JUSTIFY_LEFT);
        var valueW = dc.getTextWidthInPixels(value, Graphics.FONT_GLANCE_NUMBER);
        var numberH = dc.getFontHeight(Graphics.FONT_GLANCE_NUMBER);
        if (unit.length() > 0) {
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(valueW + 4, valueY + numberH - dc.getFontHeight(Graphics.FONT_XTINY) - 2, Graphics.FONT_XTINY, unit, Graphics.TEXT_JUSTIFY_LEFT);
        }
        if (sub.length() > 0 && valueY + numberH + 4 < h) {
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(0, valueY + numberH - 4, Graphics.FONT_XTINY, sub, Graphics.TEXT_JUSTIFY_LEFT);
        }
    }

    // The chart area in a glance row: the right 45%.
    function chartX(dc as Dc) as Number { return dc.getWidth() * 55 / 100; }
    function chartW(dc as Dc) as Number { return dc.getWidth() * 42 / 100; }
    function chartY(dc as Dc) as Number { return dc.getHeight() * 20 / 100; }
    function chartH(dc as Dc) as Number { return dc.getHeight() * 62 / 100; }

    // Detail screen: black, title at the top in the section color.
    function screen(dc as Dc, title as String, color as Number) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() * 8 / 100, Graphics.FONT_XTINY, title, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Big centered number with a small unit after it.
    function hero(dc as Dc, y as Number, value as String, unit as String, color as Number) as Void {
        var cx = dc.getWidth() / 2;
        var font = Graphics.FONT_NUMBER_MEDIUM;
        var valueW = dc.getTextWidthInPixels(value, font);
        var unitW = unit.length() > 0 ? dc.getTextWidthInPixels(unit, Graphics.FONT_XTINY) + 6 : 0;
        var x = cx - (valueW + unitW) / 2;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, value, Graphics.TEXT_JUSTIFY_LEFT);
        if (unitW > 0) {
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x + valueW + 6, y + dc.getFontHeight(font) - dc.getFontHeight(Graphics.FONT_XTINY) - 8, Graphics.FONT_XTINY, unit, Graphics.TEXT_JUSTIFY_LEFT);
        }
    }

    // Box for a detail chart: inset enough to stay clear of the round edge at that height.
    function chartLeft(dc as Dc) as Number { return dc.getWidth() * 14 / 100; }
    function chartWidth(dc as Dc) as Number { return dc.getWidth() * 72 / 100; }

    // Small time labels under a detail chart: "-24H" on the left, "NOW" on the right.
    function timeAxis(dc as Dc, x as Number, y as Number, w as Number, left as String, right as String) as Void {
        dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_XTINY, left, Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(x + w, y, Graphics.FONT_XTINY, right, Graphics.TEXT_JUSTIFY_RIGHT);
    }

    // Two or three stats across, evenly spaced.
    function stats3(dc as Dc, y as Number, a as Array<String>, b as Array<String>, c as Array<String>?, colors as Array<Number>) as Void {
        var cx = dc.getWidth() / 2;
        if (c == null) {
            Draw.stat(dc, cx - 70, y, a[0], a[1], colors[0]);
            Draw.stat(dc, cx + 70, y, b[0], b[1], colors[1]);
            return;
        }
        Draw.stat(dc, cx - 110, y, a[0], a[1], colors[0]);
        Draw.stat(dc, cx, y, b[0], b[1], colors[1]);
        Draw.stat(dc, cx + 110, y, c[0], c[1], colors[2]);
    }

    function hours(seconds as Number) as String {
        if (seconds < 3600) { return (seconds / 60).format("%d") + "m"; }
        return (seconds / 3600).format("%d") + "h" + ((seconds % 3600) / 60).format("%02d");
    }
}
