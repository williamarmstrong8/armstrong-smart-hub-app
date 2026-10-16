import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.Lang;
import Toybox.SensorHistory;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.UserProfile;

// Everything the faces show, read on the watch itself. The phone app doesn't
// relay web requests from the watch, so nothing here needs a connection.
// Workout rules match the hub's glance feed (lib/watch-glance.ts): a day
// counts when any activity started on it, and push / pull / legs follows the
// number of strength sessions.
module HubData {

    const SPLIT = ["PUSH DAY", "PULL DAY", "LEG DAY"] as Array<String>;

    class Workouts {
        // Index 0 = six days ago ... index 6 = today.
        var week as Array<Boolean> = [false, false, false, false, false, false, false] as Array<Boolean>;
        var streak as Number = 0;
        var next as String = "START EASY";
    }

    var _cached as Workouts? = null;
    var _cachedAt as Number = -1;

    // Activity history only changes when a workout is saved, so read it at most every 5 minutes.
    function workouts() as Workouts {
        var now = Time.now().value();
        if (_cached == null || _cachedAt < 0 || now - _cachedAt > 300) {
            _cached = readWorkouts();
            _cachedAt = now;
        }
        return _cached as Workouts;
    }

    // Whole days between the start of today and the day `moment` falls on (0 = today).
    function daysAgo(moment as Time.Moment) as Number {
        var todayStart = Time.today().value();
        var t = moment.value();
        if (t >= todayStart) { return 0; }
        return (todayStart - t - 1) / Gregorian.SECONDS_PER_DAY + 1;
    }

    function readWorkouts() as Workouts {
        var result = new Workouts();
        if (!(UserProfile has :getUserActivityHistory)) { return result; }

        // Days (as days-ago numbers) with any activity, the newest workout, and the strength count.
        var days = {} as Dictionary<Number, Boolean>;
        var newest = -1;
        var strength = 0;
        var history = UserProfile.getUserActivityHistory();
        var entry = history.next();
        while (entry != null) {
            if (entry.startTime != null) {
                var ago = daysAgo(entry.startTime as Time.Moment);
                days[ago] = true;
                if (newest < 0 || ago < newest) { newest = ago; }
                if (entry.type == Activity.SPORT_TRAINING) { strength++; }
            }
            entry = history.next();
        }

        for (var i = 0; i < 7; i++) {
            result.week[i] = days.hasKey(6 - i);
        }

        // Streak counts back from today, or from yesterday while today's workout is still to come.
        var cursor = days.hasKey(0) ? 0 : 1;
        while (days.hasKey(cursor)) {
            result.streak++;
            cursor++;
        }

        if (newest >= 5) {
            result.next = "EASE BACK IN";
        } else if (newest >= 0) {
            result.next = SPLIT[strength % 3];
        }
        return result;
    }

    function steps() as Number {
        var steps = ActivityMonitor.getInfo().steps;
        return steps == null ? 0 : steps;
    }

    function stepGoal() as Number {
        var goal = ActivityMonitor.getInfo().stepGoal;
        return (goal == null || goal <= 0) ? 10000 : goal;
    }

    // This week's intensity minutes and the weekly goal.
    function activeMinutes() as Number {
        var week = ActivityMonitor.getInfo().activeMinutesWeek;
        return week == null ? 0 : week.total;
    }

    function activeMinutesGoal() as Number {
        var goal = ActivityMonitor.getInfo().activeMinutesWeekGoal;
        return (goal == null || goal <= 0) ? 150 : goal;
    }

    function heartRate() as Number? {
        var info = Activity.getActivityInfo();
        if (info != null && info.currentHeartRate != null) { return info.currentHeartRate; }
        // Between readings, fall back to the newest sample the watch kept.
        if (ActivityMonitor has :getHeartRateHistory) {
            var sample = ActivityMonitor.getHeartRateHistory(1, true).next();
            if (sample != null && sample.heartRate != ActivityMonitor.INVALID_HR_SAMPLE) {
                return sample.heartRate;
            }
        }
        return null;
    }

    function restingHeartRate() as Number? {
        var profile = UserProfile.getProfile();
        return profile == null ? null : profile.restingHeartRate;
    }

    function bodyBattery() as Number? {
        if ((Toybox has :SensorHistory) && (SensorHistory has :getBodyBatteryHistory)) {
            var sample = SensorHistory.getBodyBatteryHistory({ :period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST }).next();
            if (sample != null && sample.data != null) { return (sample.data as Numeric).toNumber(); }
        }
        return null;
    }

    function stress() as Number? {
        if ((Toybox has :SensorHistory) && (SensorHistory has :getStressHistory)) {
            var sample = SensorHistory.getStressHistory({ :period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST }).next();
            if (sample != null && sample.data != null) { return (sample.data as Numeric).toNumber(); }
        }
        return null;
    }

    function battery() as Number {
        return System.getSystemStats().battery.toNumber();
    }

    function timeString() as String {
        var clock = System.getClockTime();
        var hour = clock.hour;
        if (!System.getDeviceSettings().is24Hour) {
            hour = hour % 12;
            if (hour == 0) { hour = 12; }
        }
        return hour.format("%d") + ":" + clock.min.format("%02d");
    }

    function dateString() as String {
        var now = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        return (now.day_of_week as String).toUpper() + " " + now.day.format("%d");
    }
}
