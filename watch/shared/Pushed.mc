import Toybox.Application;
import Toybox.Lang;
import Toybox.Time;

// Values the phone writes into a glance's app settings after each sync: the
// hub's sleep score, overnight HRV, load, readiness and VO2max, which apps
// can't read on the watch. Only the glances that declare these properties
// (resources/settings/properties.xml) call this. -1 or "" means no value.
(:glance)
module Pushed {

    // A pushed number, or null when it's missing or -1.
    function number(key as String) as Number? {
        try {
            var value = Application.Properties.getValue(key);
            if (value instanceof Number && value >= 0) { return value; }
        } catch (e) {}
        return null;
    }

    // A pushed string, or null when it's missing or empty.
    function text(key as String) as String? {
        try {
            var value = Application.Properties.getValue(key);
            if (value instanceof String && value.length() > 0) { return value; }
        } catch (e) {}
        return null;
    }

    // True when the epoch-seconds value at `key` is no older than `maxAge` seconds.
    function fresh(key as String, maxAge as Number) as Boolean {
        var at = number(key);
        return at != null && Time.now().value() - at <= maxAge;
    }
}
