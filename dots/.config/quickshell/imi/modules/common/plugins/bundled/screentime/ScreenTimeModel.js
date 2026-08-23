.pragma library

// Ported from Omalog Model.js, colors remapped to the shell's M3 palette.
// Category hues stay distinct per Daylog, but derive from theme tokens so
// the panel re-tints with the user's Material You scheme.

// ---------------------------------------------------------------------------
// Duration formatting
// ---------------------------------------------------------------------------

function formatDuration(secs) {
    var v = Number(secs) || 0
    if (v <= 0) return "0m"
    var h = Math.floor(v / 3600)
    var m = Math.floor((v % 3600) / 60)
    if (h > 0 && m > 0) return h + "h " + m + "m"
    if (h > 0) return h + "h"
    return m + "m"
}

function formatDurationShort(secs) {
    var v = Number(secs) || 0
    if (v <= 0) return "0m"
    var h = Math.floor(v / 3600)
    var m = Math.floor((v % 3600) / 60)
    if (h > 0) return h + "h" + (m > 0 ? m + "m" : "")
    return m + "m"
}

function formatWindow(start, end) {
    var fmt = function(h) {
        if (h === 0) return "12am"
        if (h < 12) return h + "am"
        if (h === 12) return "12pm"
        return (h - 12) + "pm"
    }
    return fmt(start) + " – " + fmt(end)
}

function formatPatternShift(shift) {
    if (!shift) return ""
    var sign = shift.delta_secs >= 0 ? "+" : "\u2212"
    return sign + formatDurationShort(Math.abs(shift.delta_secs)) + " " + shift.category_root + " vs " + shift.weekday
}

// ---------------------------------------------------------------------------
// Category colors — M3: each root maps to a role from the live theme
// (Appearance is injected by the caller via themeColors). Falls back to
// the Daylog hex palette when no theme is given (standalone use).
// ---------------------------------------------------------------------------

var fallbackColors = {
    Work: "#E59A6E", Comms: "#DEBF6C", Media: "#8DBD8E",
    Browsing: "#73B4CA", Documents: "#7E83C9", Uncategorized: "#606060"
}

var WEEK_ROOT_ORDER = ["Work", "Comms", "Media", "Browsing", "Documents", "Uncategorized"]

function categoryColor(root, themeColors) {
    if (themeColors) {
        switch (root) {
        case "Work":      return themeColors.colPrimary
        case "Comms":     return themeColors.colSecondary
        case "Media":     return themeColors.colTertiary
        case "Browsing":  return themeColors.colOutlineVariant || fallbackColors.Browsing
        case "Documents": return themeColors.colPrimaryContainer
        default:          return themeColors.colSubtext || fallbackColors.Uncategorized
        }
    }
    return fallbackColors[root] || fallbackColors.Uncategorized
}

// Spectrum colors for hourly chart (5-band: hour-of-day)
function spectrumColor(hour, themeColors) {
    if (hour <= 4)  return categoryColor("Work", themeColors)
    if (hour <= 9)  return categoryColor("Comms", themeColors)
    if (hour <= 14) return categoryColor("Media", themeColors)
    if (hour <= 19) return categoryColor("Browsing", themeColors)
    return categoryColor("Documents", themeColors)
}

// ---------------------------------------------------------------------------
// Heatmap intensity
// ---------------------------------------------------------------------------

function heatmapOpacity(value, maxValue) {
    if (value <= 0 || maxValue <= 0) return 0.0
    var ratio = value / maxValue
    if (ratio < 0.01) return 0.0
    if (ratio < 0.25) return 0.25
    if (ratio < 0.50) return 0.50
    if (ratio < 0.75) return 0.75
    return 1.0
}

// ---------------------------------------------------------------------------
// JSON / helpers
// ---------------------------------------------------------------------------

function parseJson(text) {
    try { return JSON.parse(String(text || "{}")) }
    catch (e) { return {} }
}

function topListMax(list, key) {
    if (!list || list.length === 0) return 0
    var max = 0
    for (var i = 0; i < list.length; i++) {
        var v = Number(list[i][key]) || 0
        if (v > max) max = v
    }
    return max
}
