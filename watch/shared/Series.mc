import Toybox.Lang;
import Toybox.SensorHistory;
import Toybox.Time;

// Sensor history squeezed into a fixed number of time bins while it's read,
// so a glance (64 KB) never holds hours of raw samples.
(:glance)
module Series {

    class Binned {
        // Average per bin, oldest first; null where the watch has no samples.
        var values as Array<Number?>;
        var min as Number? = null;
        var max as Number? = null;
        // Newest sample and when it was taken (epoch seconds).
        var last as Number? = null;
        var lastAt as Number = 0;
        // Sum and count over the whole window, for an average.
        var total as Number = 0;
        var count as Number = 0;

        function initialize(bins as Number) {
            values = new Array<Number?>[bins];
        }

        function average() as Number? {
            return count == 0 ? null : total / count;
        }
    }

    function history(kind as Symbol, seconds as Number) as SensorHistory.SensorHistoryIterator? {
        if (!(Toybox has :SensorHistory)) { return null; }
        var options = { :period => new Time.Duration(seconds), :order => SensorHistory.ORDER_OLDEST_FIRST };
        if (kind == :heartRate && (SensorHistory has :getHeartRateHistory)) { return SensorHistory.getHeartRateHistory(options); }
        if (kind == :bodyBattery && (SensorHistory has :getBodyBatteryHistory)) { return SensorHistory.getBodyBatteryHistory(options); }
        if (kind == :stress && (SensorHistory has :getStressHistory)) { return SensorHistory.getStressHistory(options); }
        if (kind == :oxygen && (SensorHistory has :getOxygenSaturationHistory)) { return SensorHistory.getOxygenSaturationHistory(options); }
        return null;
    }

    // `kind` is :heartRate, :bodyBattery, :stress or :oxygen. Samples outside 1..250 are dropped
    // (the watch reports gaps and off-wrist readings as 0 or out of range).
    function read(kind as Symbol, seconds as Number, bins as Number) as Binned {
        return readWindow(kind, Time.now().value() - seconds, Time.now().value(), seconds, bins);
    }

    // Only the samples between `from` and `to` (epoch seconds); `lookback` is how far back to ask the watch for.
    function readWindow(kind as Symbol, from as Number, to as Number, lookback as Number, bins as Number) as Binned {
        var result = new Binned(bins);
        var iterator = history(kind, lookback);
        if (iterator == null || to <= from) { return result; }

        var sums = new Array<Number>[bins];
        var counts = new Array<Number>[bins];
        for (var i = 0; i < bins; i++) {
            sums[i] = 0;
            counts[i] = 0;
        }
        var span = to - from;
        var sample = iterator.next();
        while (sample != null) {
            var data = sample.data;
            var when = sample.when;
            if (data != null && when != null) {
                var value = (data as Numeric).toNumber();
                var at = when.value();
                if (value > 0 && value <= 250 && at >= from && at <= to) {
                    var bin = ((at - from).toLong() * bins / span).toNumber();
                    if (bin >= bins) { bin = bins - 1; }
                    sums[bin] += value;
                    counts[bin] += 1;
                    result.total += value;
                    result.count += 1;
                    if (result.min == null || value < result.min) { result.min = value; }
                    if (result.max == null || value > result.max) { result.max = value; }
                    result.last = value;
                    result.lastAt = at;
                }
            }
            sample = iterator.next();
        }
        for (var i = 0; i < bins; i++) {
            result.values[i] = counts[i] == 0 ? null : sums[i] / counts[i];
        }
        return result;
    }
}
