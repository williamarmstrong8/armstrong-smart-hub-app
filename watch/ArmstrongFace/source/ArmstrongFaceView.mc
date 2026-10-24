import Toybox.ActivityMonitor;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.Weather;
import Toybox.WatchUi;

// Armstrong Minimal: an analog dial in the style of Apple's Meridian. Hour bars
// out to the bezel, hollow capsule hands with a red seconds hand that sweeps while
// the screen is awake, and four stat circles: current weather on top, heart rate left,
// calories right, watch battery at the bottom.
class ArmstrongFaceView extends WatchUi.WatchFace {

    private const DISC   = 0x1C1C1E;
    private const SECOND = 0xFF3B30;

    private var _lowPower as Boolean = false;

    // Sweep: redraw every FRAME ms while awake. The clock only gives whole seconds,
    // so the fraction comes from the system timer since the second last changed.
    private const FRAME = 50;
    private var _timer as Timer.Timer? = null;
    private var _lastSec as Number = -1;
    private var _secStart as Number = 0;

    // Current weather from the watch (synced from the phone), read at most once a minute.
    private const SUN   = 0xFFD60A;
    private const CLOUD = 0xAEAEB2;
    private var _weatherAt as Number = -1;
    private var _temp as String = "--";
    private var _sky as Symbol = :cloud;

    function initialize() {
        WatchFace.initialize();
    }

    function onShow() as Void {
        if (!_lowPower) { startSweep(); }
    }

    function onHide() as Void {
        stopSweep();
    }

    function onEnterSleep() as Void {
        _lowPower = true;
        stopSweep();
        WatchUi.requestUpdate();
    }

    function onExitSleep() as Void {
        _lowPower = false;
        startSweep();
        WatchUi.requestUpdate();
    }

    private function startSweep() as Void {
        if (_timer == null) { _timer = new Timer.Timer(); }
        (_timer as Timer.Timer).start(method(:frame), FRAME, true);
    }

    private function stopSweep() as Void {
        if (_timer != null) { (_timer as Timer.Timer).stop(); }
    }

    function frame() as Void {
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var cx = w / 2;
        var cy = dc.getHeight() / 2;
        var r = cx;
        var clock = System.getClockTime();

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setAntiAlias(true);

        var minuteAngle = clock.min * 6.0 + clock.sec * 0.1;
        var hourAngle = (clock.hour % 12) * 30.0 + clock.min * 0.5;

        // Always-on: thin outlined hands only, shifted a few pixels each minute (AMOLED burn-in).
        if (_lowPower) {
            var jx = cx + ((clock.min % 5) - 2) * 6;
            var jy = cy + ((clock.min % 3) - 1) * 6;
            hand(dc, jx, jy, hourAngle, r * 0.50, 12, 8, Draw.GRAY);
            hand(dc, jx, jy, minuteAngle, r * 0.80, 12, 8, Draw.GRAY);
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawCircle(jx, jy, 6);
            dc.setPenWidth(1);
            return;
        }

        dial(dc, cx, cy, r);

        // Stat circles, Meridian's four positions.
        var off = (r * 0.42).toNumber();
        var disc = (r * 0.21).toNumber();
        readWeather();
        stat(dc, cx, cy - off, disc, _sky, _temp, skyColor(_sky));
        stat(dc, cx - off, cy, disc, :heart, Draw.orDash(HubData.heartRate()), Draw.RED);
        stat(dc, cx + off, cy, disc, :calories, Draw.orDash(caloriesToday()), Draw.ORANGE);
        var charge = HubData.battery();
        stat(dc, cx, cy + off, disc, :battery, charge.format("%d") + "%", charge <= 15 ? Draw.RED : Draw.GREEN);

        // Hands, then the seconds hand over them and the pivot.
        hand(dc, cx, cy, hourAngle, r * 0.50, 14, 8, Draw.WHITE);
        hand(dc, cx, cy, minuteAngle, r * 0.80, 14, 8, Draw.WHITE);
        dc.setColor(Draw.WHITE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, cy, 8);

        var now = System.getTimer();
        if (clock.sec != _lastSec) {
            _lastSec = clock.sec;
            _secStart = now;
        }
        var fraction = (now - _secStart) / 1000.0;
        if (fraction > 0.999) { fraction = 0.999; }
        var secondAngle = (clock.sec + fraction) * 6.0;
        dc.setColor(SECOND, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(3);
        dc.drawLine(px(cx, secondAngle, -r * 0.12), py(cy, secondAngle, -r * 0.12),
                    px(cx, secondAngle, r * 0.92), py(cy, secondAngle, r * 0.92));
        dc.setPenWidth(1);
        dc.fillCircle(cx, cy, 5);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, cy, 2);
    }

    // White hour bars reaching out toward the bezel.
    private function dial(dc as Dc, cx as Number, cy as Number, r as Number) as Void {
        dc.setColor(Draw.WHITE, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(7);
        for (var i = 0; i < 12; i++) {
            var a = i * 30.0;
            dc.drawLine(px(cx, a, r * 0.81), py(cy, a, r * 0.81), px(cx, a, r * 0.96), py(cy, a, r * 0.96));
        }
        dc.setPenWidth(1);
    }

    // Apple-style hand: a short solid stem from the pivot, then a hollow capsule.
    private function hand(dc as Dc, cx as Number, cy as Number, angle as Float, length as Float, width as Number, inner as Number, color as Number) as Void {
        var stem = 26.0;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(4);
        dc.drawLine(cx, cy, px(cx, angle, stem), py(cy, angle, stem));
        capsule(dc, px(cx, angle, stem), py(cy, angle, stem), px(cx, angle, length), py(cy, angle, length), width, color);
        capsule(dc, px(cx, angle, stem), py(cy, angle, stem), px(cx, angle, length), py(cy, angle, length), inner, Graphics.COLOR_BLACK);
        dc.setPenWidth(1);
    }

    private function capsule(dc as Dc, x1 as Number, y1 as Number, x2 as Number, y2 as Number, width as Number, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(width);
        dc.drawLine(x1, y1, x2, y2);
        dc.fillCircle(x1, y1, width / 2);
        dc.fillCircle(x2, y2, width / 2);
    }

    // Dark disc with a small colored icon above a white value.
    private function stat(dc as Dc, x as Number, y as Number, radius as Number, icon as Symbol, value as String, color as Number) as Void {
        dc.setColor(DISC, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, radius);

        var font = Graphics.FONT_XTINY;
        var textH = dc.getFontHeight(font);
        var iconY = y - textH / 2 + 2;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        if (icon == :sun) {
            dc.fillCircle(x, iconY, 6);
            dc.setPenWidth(2);
            for (var i = 0; i < 8; i++) {
                var a = i * 45.0;
                dc.drawLine(px(x, a, 9), py(iconY, a, 9), px(x, a, 12), py(iconY, a, 12));
            }
            dc.setPenWidth(1);
        } else if (icon == :cloud || icon == :rain || icon == :snow) {
            // Cloud from three circles on a flat base, with drops or flakes under it.
            var cy = icon == :cloud ? iconY + 2 : iconY - 2;
            dc.setColor(CLOUD, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x - 6, cy + 1, 5);
            dc.fillCircle(x + 1, cy - 3, 7);
            dc.fillCircle(x + 7, cy + 1, 5);
            dc.fillRectangle(x - 6, cy + 1, 13, 5);
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            if (icon == :rain) {
                dc.setPenWidth(2);
                for (var i = -1; i <= 1; i++) { dc.drawLine(x + i * 6 + 1, cy + 9, x + i * 6 - 1, cy + 13); }
                dc.setPenWidth(1);
            } else if (icon == :snow) {
                for (var i = -1; i <= 1; i++) { dc.fillCircle(x + i * 6, cy + 11, 2); }
            }
        } else if (icon == :heart) {
            dc.fillCircle(x - 5, iconY - 3, 6);
            dc.fillCircle(x + 5, iconY - 3, 6);
            dc.fillPolygon([[x - 11, iconY - 1], [x + 11, iconY - 1], [x, iconY + 11]]);
        } else if (icon == :calories) {
            dc.fillCircle(x, iconY + 4, 7);
            dc.fillPolygon([[x - 7, iconY + 3], [x + 7, iconY + 3], [x + 2, iconY - 12]]);
            dc.setColor(DISC, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x, iconY + 6, 3);
        } else {
            var fraction = HubData.battery() / 100.0;
            dc.setPenWidth(2);
            dc.drawRoundedRectangle(x - 13, iconY - 7, 24, 14, 3);
            dc.fillRectangle(x + 12, iconY - 3, 3, 6);
            dc.setPenWidth(1);
            var fill = (18 * fraction).toNumber();
            if (fill > 0) { dc.fillRectangle(x - 10, iconY - 4, fill, 8); }
        }

        dc.setColor(Draw.WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, iconY + 12, font, value, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Temperature in the watch's units and a sky for the icon.
    private function readWeather() as Void {
        var now = Time.now().value();
        if (_weatherAt >= 0 && now - _weatherAt < 60) { return; }
        _weatherAt = now;
        _temp = "--";
        _sky = :cloud;
        if (!(Toybox has :Weather)) { return; }
        var current = Weather.getCurrentConditions();
        if (current == null) { return; }
        if (current.temperature != null) {
            var t = (current.temperature as Numeric).toFloat();
            if (System.getDeviceSettings().temperatureUnits == System.UNIT_STATUTE) { t = t * 9.0 / 5.0 + 32.0; }
            _temp = Math.round(t).toNumber().format("%d") + "°";
        }
        if (current.condition != null) { _sky = sky(current.condition as Number); }
    }

    private function sky(condition as Number) as Symbol {
        var clear = [Weather.CONDITION_CLEAR, Weather.CONDITION_MOSTLY_CLEAR, Weather.CONDITION_PARTLY_CLEAR, Weather.CONDITION_FAIR];
        var snow = [Weather.CONDITION_SNOW, Weather.CONDITION_LIGHT_SNOW, Weather.CONDITION_HEAVY_SNOW, Weather.CONDITION_FLURRIES,
            Weather.CONDITION_WINTRY_MIX, Weather.CONDITION_SLEET, Weather.CONDITION_HAIL, Weather.CONDITION_ICE, Weather.CONDITION_ICE_SNOW,
            Weather.CONDITION_RAIN_SNOW, Weather.CONDITION_LIGHT_RAIN_SNOW, Weather.CONDITION_HEAVY_RAIN_SNOW,
            Weather.CONDITION_CHANCE_OF_SNOW, Weather.CONDITION_CHANCE_OF_RAIN_SNOW, Weather.CONDITION_CLOUDY_CHANCE_OF_SNOW,
            Weather.CONDITION_CLOUDY_CHANCE_OF_RAIN_SNOW, Weather.CONDITION_FREEZING_RAIN];
        var rain = [Weather.CONDITION_RAIN, Weather.CONDITION_LIGHT_RAIN, Weather.CONDITION_HEAVY_RAIN, Weather.CONDITION_DRIZZLE,
            Weather.CONDITION_SHOWERS, Weather.CONDITION_LIGHT_SHOWERS, Weather.CONDITION_HEAVY_SHOWERS, Weather.CONDITION_SCATTERED_SHOWERS,
            Weather.CONDITION_CHANCE_OF_SHOWERS, Weather.CONDITION_CLOUDY_CHANCE_OF_RAIN, Weather.CONDITION_THUNDERSTORMS,
            Weather.CONDITION_SCATTERED_THUNDERSTORMS, Weather.CONDITION_CHANCE_OF_THUNDERSTORMS, Weather.CONDITION_TROPICAL_STORM,
            Weather.CONDITION_HURRICANE];
        if (clear.indexOf(condition) >= 0) { return :sun; }
        if (snow.indexOf(condition) >= 0) { return :snow; }
        if (rain.indexOf(condition) >= 0) { return :rain; }
        return :cloud;
    }

    private function skyColor(sky as Symbol) as Number {
        if (sky == :sun) { return SUN; }
        if (sky == :rain) { return Draw.TEAL; }
        if (sky == :snow) { return Draw.WHITE; }
        return CLOUD;
    }

    private function caloriesToday() as Number? {
        return ActivityMonitor.getInfo().calories;
    }

    // Point at `dist` from the center along a clock angle (degrees, 0 = 12 o'clock, clockwise).
    private function px(cx as Number, angle as Float, dist as Float or Number) as Number {
        return (cx + dist * Math.sin(Math.toRadians(angle))).toNumber();
    }

    private function py(cy as Number, angle as Float, dist as Float or Number) as Number {
        return (cy - dist * Math.cos(Math.toRadians(angle))).toNumber();
    }
}
