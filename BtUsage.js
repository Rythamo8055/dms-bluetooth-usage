.pragma library

function pad(value) {
    return value < 10 ? "0" + value : "" + value;
}

function dateKey(ms) {
    var d = new Date(ms);
    return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
}

function dayStart(ms) {
    var d = new Date(ms);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

function nextDayStart(ms) {
    var d = new Date(ms);
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime();
}

// Human readable duration. Under a minute we show seconds so a fresh
// connection still gives feedback in the bar.
function duration(seconds, compact) {
    seconds = Math.max(0, Math.round(Number(seconds) || 0));
    if (seconds < 60)
        return seconds + "s";

    var minutes = Math.floor(seconds / 60);
    var hours = Math.floor(minutes / 60);
    var days = Math.floor(hours / 24);

    if (days > 0)
        return days + "d " + (hours % 24) + "h";
    if (hours > 0)
        return hours + "h " + pad(minutes % 60) + "m";
    return minutes + "m";
}

function durationLong(seconds) {
    seconds = Math.max(0, Math.round(Number(seconds) || 0));
    if (seconds < 60)
        return seconds + (seconds === 1 ? " second" : " seconds");

    var minutes = Math.floor(seconds / 60);
    var hours = Math.floor(minutes / 60);
    var days = Math.floor(hours / 24);

    if (days > 0)
        return days + "d " + (hours % 24) + "h";
    if (hours > 0)
        return hours + "h " + (minutes % 60) + "m";
    return minutes + (minutes === 1 ? " minute" : " minutes");
}

function liveSeconds(record, now) {
    if (!record || !record.activeStart)
        return 0;
    return Math.max(0, (now - record.activeStart) / 1000);
}

// Portion of the currently running session that falls on today's date.
function liveToday(record, now) {
    if (!record || !record.activeStart)
        return 0;
    var start = Math.max(record.activeStart, dayStart(now));
    if (now <= start)
        return 0;
    return (now - start) / 1000;
}

// Actual audio output time, as opposed to merely being connected.
function livePlaying(record, now) {
    if (!record || !record.playingStart)
        return 0;
    return Math.max(0, (now - record.playingStart) / 1000);
}

function livePlayingToday(record, now) {
    if (!record || !record.playingStart)
        return 0;
    var start = Math.max(record.playingStart, dayStart(now));
    if (now <= start)
        return 0;
    return (now - start) / 1000;
}

function todaySeconds(record, now) {
    if (!record)
        return 0;
    var stored = record.days ? (record.days[dateKey(now)] || 0) : 0;
    return stored + liveToday(record, now);
}

function playingToday(record, now) {
    if (!record)
        return 0;
    var stored = record.playingDays ? (record.playingDays[dateKey(now)] || 0) : 0;
    return stored + livePlayingToday(record, now);
}

function totalSeconds(record, now) {
    if (!record)
        return 0;
    return (record.totalSeconds || 0) + liveSeconds(record, now);
}

function playingTotal(record, now) {
    if (!record)
        return 0;
    return (record.playingSeconds || 0) + livePlaying(record, now);
}

function idleToday(record, now) {
    return Math.max(0, todaySeconds(record, now) - playingToday(record, now));
}

function idleTotal(record, now) {
    return Math.max(0, totalSeconds(record, now) - playingTotal(record, now));
}

function lastSessionSeconds(record) {
    if (!record)
        return 0;
    if (record.activeStart)
        return liveSeconds(record, Date.now());
    return record.lastSessionSeconds || 0;
}

function batteryPercent(record) {
    if (!record || record.battery === undefined || record.battery < 0)
        return null;
    return Math.round(record.battery);
}

// Aggregate day buckets for the trailing week, oldest first.
function weekDays(devices, now) {
    return buildWeek(devices, now, true);
}

// Same as weekDays but without the currently running session. Useful when
// the UI wants to add the live seconds itself so the chart and the "today"
// total never disagree.
function weekDaysStored(devices, now) {
    return buildWeek(devices, now, false);
}

function buildWeek(devices, now, includeLive) {
    var result = [];
    var todayStart = dayStart(now);
    for (var offset = 6; offset >= 0; offset--) {
        var day = new Date(todayStart);
        day.setDate(day.getDate() - offset);
        var start = day.getTime();
        var key = dateKey(start);
        var seconds = 0;
        var playing = 0;

        for (var address in devices) {
            var record = devices[address];
            if (!record)
                continue;
            seconds += record.days ? (record.days[key] || 0) : 0;
            playing += record.playingDays ? (record.playingDays[key] || 0) : 0;
            if (includeLive && offset === 0) {
                seconds += liveToday(record, now);
                playing += livePlayingToday(record, now);
            }
        }

        result.push({
            key: key,
            label: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][day.getDay()],
            seconds: seconds,
            playingSeconds: playing,
            isToday: offset === 0
        });
    }
    return result;
}

function weekTotal(devices, now) {
    var days = weekDays(devices, now);
    var total = 0;
    for (var i = 0; i < days.length; i++)
        total += days[i].seconds;
    return total;
}

function relativeTime(timestamp, now) {
    if (!timestamp || timestamp <= 0)
        return "never";

    var diff = Math.max(0, now - timestamp);
    var minutes = Math.floor(diff / 60000);
    if (minutes < 1)
        return "just now";
    if (minutes < 60)
        return minutes + "m ago";

    var hours = Math.floor(minutes / 60);
    if (hours < 24)
        return hours + "h ago";

    var days = Math.floor(hours / 24);
    if (days < 7)
        return days + "d ago";

    var date = new Date(timestamp);
    return date.toLocaleDateString(Qt.locale(), "d MMM");
}
