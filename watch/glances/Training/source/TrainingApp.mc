import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.UserProfile;
import Toybox.WatchUi;

// Training: the workout week and streak, what's next in push / pull / legs,
// recovery time, VO2max, intensity minutes and the last few workouts. After a
// sync the phone also writes the hub's readiness, load, recovery and VO2max
// into this app's settings (Pushed); those win while they're under a day and a
// half old, else the watch's own recovery time and VO2max show.

// How long pushed training numbers stay current without a new sync.
const HUB_TRAINING_AGE = 36 * 3600;

(:glance)
function hubTraining() as Boolean { return Pushed.fresh("at", HUB_TRAINING_AGE); }
class TrainingApp extends Application.AppBase {
    function initialize() { AppBase.initialize(); }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new TrainingView()];
    }

    (:glance)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new TrainingGlance()];
    }
}

(:glance)
class TrainingGlance extends WatchUi.GlanceView {
    function initialize() { GlanceView.initialize(); }

    function onUpdate(dc as Dc) as Void {
        var workouts = HubData.workouts();
        var ready = hubTraining() ? Pushed.number("ready") : null;
        var sub = workouts.next.toLower() + (ready == null ? "" : "  ready " + ready.format("%d"));
        Card.glance(dc, "TRAINING", workouts.streak.format("%d"), workouts.streak == 1 ? "day" : "days", sub, Draw.GREEN);
        var x = Card.chartX(dc);
        var w = Card.chartW(dc);
        Draw.weekRow(dc, x + w / 2, dc.getHeight() / 2, workouts.week, w / 18, w / 7);
    }
}

class TrainingView extends WatchUi.View {
    function initialize() { View.initialize(); }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        Card.screen(dc, "TRAINING", Draw.GREEN);

        var workouts = HubData.workouts();
        dc.setColor(Draw.WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 13 / 100, Graphics.FONT_MEDIUM, workouts.next, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
        var streak = workouts.streak == 0 ? "NO STREAK YET" : workouts.streak.format("%d") + (workouts.streak == 1 ? " DAY" : " DAYS") + " IN A ROW";
        dc.drawText(cx, h * 23 / 100, Graphics.FONT_XTINY, streak, Graphics.TEXT_JUSTIFY_CENTER);

        Draw.weekRow(dc, cx, h * 34 / 100, workouts.week, 13, 44);

        // Recovery, VO2max and this week's intensity minutes: the hub's when pushed, else the watch's.
        var hub = hubTraining();
        var info = ActivityMonitor.getInfo();
        var recovery = hub ? Pushed.number("recH") : null;
        if (recovery == null) { recovery = (info has :timeToRecovery) ? info.timeToRecovery : null; }
        var hubVo2 = hub ? Pushed.number("vo2") : null;
        var vo2 = null as String?;
        if (hubVo2 != null) {
            vo2 = (hubVo2 / 10).format("%d") + "." + (hubVo2 % 10).format("%d");
        } else {
            var profile = UserProfile.getProfile();
            var watchVo2 = (profile != null && (profile has :vo2maxRunning)) ? profile.vo2maxRunning : null;
            vo2 = Draw.orDash(watchVo2);
        }
        Card.stats3(dc, h * 42 / 100,
            [recovery == null ? "--" : recovery.format("%d") + "h", "RECOVERY"],
            [vo2 as String, "VO2MAX"],
            [HubData.activeMinutes().format("%d"), "INT MIN"],
            [recovery != null && recovery > 24 ? Draw.ORANGE : Draw.WHITE, Draw.TEAL, Draw.INDIGO]);
        Draw.bar(dc, cx - 110, h * 58 / 100, 220, HubData.activeMinutes().toFloat() / HubData.activeMinutesGoal().toFloat(), Draw.INDIGO);

        // The hub's readiness and load, one line.
        var y = h * 63 / 100;
        var ready = hub ? Pushed.number("ready") : null;
        var acute = hub ? Pushed.number("acute") : null;
        if (ready != null || acute != null) {
            var level = Pushed.text("readyLv");
            var status = Pushed.text("loadSt");
            var line = (ready == null ? "" : "READY " + ready.format("%d") + (level == null ? "" : " " + level.toUpper()))
                + (ready != null && acute != null ? "  ·  " : "")
                + (acute == null ? "" : "LOAD " + acute.format("%d") + (status == null ? "" : " " + status.toUpper()));
            dc.setColor(ready != null && ready < 50 ? Draw.ORANGE : Draw.GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, y, Graphics.FONT_XTINY, line, Graphics.TEXT_JUSTIFY_CENTER);
            y += dc.getFontHeight(Graphics.FONT_XTINY) + 4;
        }

        // The last three workouts, newest first.
        var recent = recentWorkouts(ready != null || acute != null ? 2 : 3);
        var lineH = dc.getFontHeight(Graphics.FONT_XTINY);
        if (recent.size() == 0) {
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, y, Graphics.FONT_XTINY, "No workouts on the watch yet", Graphics.TEXT_JUSTIFY_CENTER);
        }
        for (var i = 0; i < recent.size(); i++) {
            var entry = recent[i];
            var ago = HubData.daysAgo(entry.startTime as Time.Moment);
            var when = ago == 0 ? "TODAY" : (ago == 1 ? "YESTERDAY" : ago.format("%d") + "D AGO");
            var minutes = entry.duration == null ? "" : "  " + ((entry.duration as Time.Duration).value() / 60).format("%d") + " MIN";
            dc.setColor(Draw.WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx - 8, y + i * lineH, Graphics.FONT_XTINY, sportName(entry.type), Graphics.TEXT_JUSTIFY_RIGHT);
            dc.setColor(Draw.GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx + 8, y + i * lineH, Graphics.FONT_XTINY, when + minutes, Graphics.TEXT_JUSTIFY_LEFT);
        }
    }

    // Newest `limit` activities from the watch's history.
    private function recentWorkouts(limit as Number) as Array<UserProfile.UserActivity> {
        var result = [] as Array<UserProfile.UserActivity>;
        if (!(UserProfile has :getUserActivityHistory)) { return result; }
        var history = UserProfile.getUserActivityHistory();
        var entry = history.next();
        while (entry != null) {
            if (entry.startTime != null) {
                // Insert sorted by start time, newest first, keeping at most `limit`.
                var at = (entry.startTime as Time.Moment).value();
                var i = 0;
                while (i < result.size() && ((result[i].startTime as Time.Moment).value() > at)) { i++; }
                if (i < limit) {
                    result = result.slice(0, i).add(entry).addAll(result.slice(i, null));
                    if (result.size() > limit) { result = result.slice(0, limit); }
                }
            }
            entry = history.next();
        }
        return result;
    }

    private function sportName(sport as Activity.Sport or Null) as String {
        switch (sport) {
            case Activity.SPORT_RUNNING: return "RUN";
            case Activity.SPORT_CYCLING: return "RIDE";
            case Activity.SPORT_WALKING: return "WALK";
            case Activity.SPORT_HIKING: return "HIKE";
            case Activity.SPORT_SWIMMING: return "SWIM";
            case Activity.SPORT_TRAINING: return "STRENGTH";
            case Activity.SPORT_FITNESS_EQUIPMENT: return "CARDIO";
            default: return "WORKOUT";
        }
    }
}
