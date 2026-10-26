// GENERATED FILE — do not edit by hand.
//
// The status orb readout formatter's shared conformance table, embedded so the
// tvOS port is held to exactly the same cases as the web dashboard's
// lib/orb-info/format.test.ts. Regenerate with:
//
//   node nova-appletv-dashboard/scripts/generate-orb-info-cases.mjs
//
// Source of truth: nova-ha-dashboard/lib/orb-info/format-cases.json

enum OrbInfoConformanceCases {
    static let json = #"""
{
  "comment": "Shared conformance table for formatOrbValue. BOTH the TypeScript formatter (lib/orb-info/format.test.ts) and the Swift port (nova-appletv-dashboard OrbInfoFormatTests) run this table, so the web dashboard and the Apple TV can never render the same reading differently. `display` is a PARTIAL merged over DEFAULT_ORB_DISPLAY in each implementation.",
  "cases": [
    {
      "name": "gym default display matches the pre-module readout exactly",
      "output": { "value": 46, "baseUnit": "hours", "status": "ok", "alert": true, "alertThreshold": 46 },
      "display": { "format": "duration", "unit": "hours", "decimals": 0, "rounding": "floor" },
      "expectText": "46",
      "expectAlert": true
    },
    {
      "name": "gym below threshold does not alert",
      "output": { "value": 45, "baseUnit": "hours", "status": "ok", "alert": false, "alertThreshold": 46 },
      "display": { "format": "duration", "unit": "hours", "decimals": 0, "rounding": "floor" },
      "expectText": "45",
      "expectAlert": false
    },
    {
      "name": "no reading renders emptyText, never zero",
      "output": { "value": null, "baseUnit": "hours", "status": "unavailable", "alert": false, "alertThreshold": 46 },
      "display": { "format": "duration", "unit": "hours" },
      "expectText": "—",
      "expectAlert": false
    },
    {
      "name": "an absent reading never raises the alert pulse",
      "output": { "value": null, "baseUnit": "hours", "status": "unavailable", "alert": true, "alertThreshold": 46 },
      "display": { "format": "duration", "unit": "hours" },
      "expectText": "—",
      "expectAlert": false
    },
    {
      "name": "hours shown as days at one decimal",
      "output": { "value": 46, "baseUnit": "hours", "status": "ok", "alert": false, "alertThreshold": 46 },
      "display": { "format": "duration", "unit": "days", "decimals": 1, "rounding": "floor", "showUnit": true },
      "expectText": "1.9d",
      "expectAlert": false
    },
    {
      "name": "floor and round disagree at the boundary",
      "output": { "value": 47.8, "baseUnit": "hours", "status": "ok", "alert": false, "alertThreshold": 46 },
      "display": { "format": "duration", "unit": "hours", "decimals": 0, "rounding": "round" },
      "expectText": "48",
      "expectAlert": false
    },
    {
      "name": "ceil never reports less than elapsed",
      "output": { "value": 47.1, "baseUnit": "hours", "status": "ok", "alert": false, "alertThreshold": 46 },
      "display": { "format": "duration", "unit": "hours", "decimals": 0, "rounding": "ceil" },
      "expectText": "48",
      "expectAlert": false
    },
    {
      "name": "auto duration unit picks hours under two days",
      "output": { "value": 40, "baseUnit": "hours", "status": "ok", "alert": false, "alertThreshold": 46 },
      "display": { "format": "duration", "unit": "auto", "decimals": 0, "showUnit": true },
      "expectText": "40h",
      "expectAlert": false
    },
    {
      "name": "auto duration unit escalates to weeks",
      "output": { "value": 400, "baseUnit": "hours", "status": "ok", "alert": false, "alertThreshold": 46 },
      "display": { "format": "duration", "unit": "auto", "decimals": 1, "showUnit": true },
      "expectText": "2.3w",
      "expectAlert": false
    },
    {
      "name": "percent of the module threshold",
      "output": { "value": 23, "baseUnit": "hours", "status": "ok", "alert": false, "alertThreshold": 46 },
      "display": { "format": "percent", "decimals": 0, "rounding": "floor", "showUnit": true },
      "expectText": "50%",
      "expectAlert": false
    },
    {
      "name": "percent clamps past the threshold",
      "output": { "value": 92, "baseUnit": "hours", "status": "ok", "alert": true, "alertThreshold": 46 },
      "display": { "format": "percent", "decimals": 0, "percentClamp": true, "showUnit": true },
      "expectText": "100%",
      "expectAlert": true
    },
    {
      "name": "unclamped percent runs past the threshold",
      "output": { "value": 92, "baseUnit": "hours", "status": "ok", "alert": true, "alertThreshold": 46 },
      "display": { "format": "percent", "decimals": 0, "percentClamp": false, "showUnit": true },
      "expectText": "200%",
      "expectAlert": true
    },
    {
      "name": "inverted percent counts down to the threshold",
      "output": { "value": 23, "baseUnit": "hours", "status": "ok", "alert": false, "alertThreshold": 46 },
      "display": { "format": "percent", "decimals": 0, "percentInvert": true, "showUnit": true },
      "expectText": "50%",
      "expectAlert": false
    },
    {
      "name": "inverted percent alerts when it reaches zero",
      "output": { "value": 46, "baseUnit": "hours", "status": "ok", "alert": true, "alertThreshold": 46 },
      "display": { "format": "percent", "decimals": 0, "percentInvert": true, "showUnit": true },
      "expectText": "0%",
      "expectAlert": true
    },
    {
      "name": "percent against a fixed basis",
      "output": { "value": 250, "baseUnit": "watts", "status": "ok", "alert": false, "alertThreshold": null },
      "display": { "format": "percent", "decimals": 0, "percentOf": { "kind": "fixed", "value": 1000 }, "showUnit": true },
      "expectText": "25%",
      "expectAlert": false
    },
    {
      "name": "a ratio base unit is already a percentage",
      "output": { "value": 0.42, "baseUnit": "ratio", "status": "ok", "alert": false, "alertThreshold": null },
      "display": { "format": "percent", "decimals": 0, "rounding": "round", "showUnit": true },
      "expectText": "42%",
      "expectAlert": false
    },
    {
      "name": "watts shown as kilowatts",
      "output": { "value": 1450, "baseUnit": "watts", "status": "ok", "alert": false, "alertThreshold": null },
      "display": { "format": "number", "unit": "kilowatts", "decimals": 2, "rounding": "round", "showUnit": true },
      "expectText": "1.45kW",
      "expectAlert": false
    },
    {
      "name": "watts stay watts at zero decimals",
      "output": { "value": 1450, "baseUnit": "watts", "status": "ok", "alert": false, "alertThreshold": null },
      "display": { "format": "number", "unit": "watts", "decimals": 0, "rounding": "round", "showUnit": true },
      "expectText": "1450W",
      "expectAlert": false
    },
    {
      "name": "celsius to fahrenheit",
      "output": { "value": 21.5, "baseUnit": "celsius", "status": "ok", "alert": false, "alertThreshold": null },
      "display": { "format": "temperature", "unit": "fahrenheit", "decimals": 1, "rounding": "round", "showUnit": true },
      "expectText": "70.7°F",
      "expectAlert": false
    },
    {
      "name": "temperature keeps one decimal in celsius",
      "output": { "value": 21.46, "baseUnit": "celsius", "status": "ok", "alert": false, "alertThreshold": null },
      "display": { "format": "temperature", "unit": "celsius", "decimals": 1, "rounding": "round", "showUnit": true },
      "expectText": "21.5°C",
      "expectAlert": false
    },
    {
      "name": "signed delta shows a leading plus",
      "output": { "value": 4.2, "baseUnit": "celsius", "status": "ok", "alert": false, "alertThreshold": null },
      "display": { "format": "temperature", "unit": "celsius", "decimals": 1, "rounding": "round", "signed": true, "showUnit": true },
      "expectText": "+4.2°C",
      "expectAlert": false
    },
    {
      "name": "a negative delta keeps its minus sign",
      "output": { "value": -3.5, "baseUnit": "celsius", "status": "ok", "alert": false, "alertThreshold": null },
      "display": { "format": "temperature", "unit": "celsius", "decimals": 1, "rounding": "round", "signed": true, "showUnit": true },
      "expectText": "-3.5°C",
      "expectAlert": false
    },
    {
      "name": "zero decimals never renders a decimal point",
      "output": { "value": 46.0, "baseUnit": "hours", "status": "ok", "alert": false, "alertThreshold": 46 },
      "display": { "format": "duration", "unit": "hours", "decimals": 0 },
      "expectText": "46",
      "expectAlert": false
    },
    {
      "name": "prefix and suffix wrap the number",
      "output": { "value": 7, "baseUnit": "count", "status": "ok", "alert": false, "alertThreshold": null },
      "display": { "format": "number", "decimals": 0, "prefix": "×", "suffix": " on" },
      "expectText": "×7 on",
      "expectAlert": false
    },
    {
      "name": "text modules render their words",
      "output": { "value": null, "text": "degraded", "baseUnit": "none", "status": "ok", "alert": true, "alertThreshold": null },
      "display": { "format": "text" },
      "expectText": "degraded",
      "expectAlert": true
    },
    {
      "name": "a text module with nothing to say falls back to emptyText",
      "output": { "value": null, "text": null, "baseUnit": "none", "status": "ok", "alert": false, "alertThreshold": null },
      "display": { "format": "text" },
      "expectText": "—",
      "expectAlert": false
    },
    {
      "name": "an errored reading renders emptyText",
      "output": { "value": 46, "baseUnit": "hours", "status": "error", "alert": false, "alertThreshold": 46 },
      "display": { "format": "duration", "unit": "hours" },
      "expectText": "—",
      "expectAlert": false
    },
    {
      "name": "count with no unit symbol",
      "output": { "value": 3, "baseUnit": "count", "status": "ok", "alert": false, "alertThreshold": null },
      "display": { "format": "number", "decimals": 0, "showUnit": true },
      "expectText": "3",
      "expectAlert": false
    }
  ]
}
"""#

    /// Stack ordering table (lib/orb-info/stack-cases.json, run by stack.test.ts).
    static let stackJson = #"""
{
  "comment": "Shared conformance table for orderOrbStack. BOTH lib/orb-info/stack.test.ts and the Apple TV ParitySelfTests run it. Outputs omit fields that are absent; entries default to enabled.",
  "cases": [
    {
      "name": "alert beats countdown beats on",
      "entries": [{ "id": "clock", "moduleId": "clock" }, { "id": "timer", "moduleId": "timer" }, { "id": "lan", "moduleId": "wan-status" }],
      "outputs": { "clock": {}, "timer": { "active": true, "remainingMs": 60000 }, "lan": { "alert": true } },
      "expectOrder": ["lan", "timer", "clock"]
    },
    {
      "name": "two countdowns order by remaining, overrun counts as zero",
      "entries": [{ "id": "timer", "moduleId": "timer" }, { "id": "rain", "moduleId": "rain-arriving" }, { "id": "wash", "moduleId": "washing" }],
      "outputs": { "timer": { "active": true, "remainingMs": 300000 }, "rain": { "active": true, "remainingMs": 120000 }, "wash": { "active": true, "remainingMs": -7000 } },
      "expectOrder": ["wash", "rain", "timer"]
    },
    {
      "name": "off never appears: disabled, inactive and quiet alert-only rows",
      "entries": [{ "id": "a", "moduleId": "clock", "enabled": false }, { "id": "b", "moduleId": "timer" }, { "id": "c", "moduleId": "openings-open", "showOnlyWhenAlerting": true }, { "id": "d", "moduleId": "lights-on" }],
      "outputs": { "a": {}, "b": { "active": false }, "c": { "alert": false }, "d": {} },
      "expectOrder": ["d"]
    },
    {
      "name": "alerts order most recent first; a finished timer is an alert",
      "entries": [{ "id": "timer", "moduleId": "timer" }, { "id": "wash", "moduleId": "washing" }, { "id": "open", "moduleId": "openings-open", "showOnlyWhenAlerting": true }],
      "outputs": { "timer": { "active": true, "alert": true, "alertAt": 1000 }, "wash": { "active": true, "alert": true, "alertAt": 3000 }, "open": { "alert": true, "alertAt": 2000 } },
      "expectOrder": ["wash", "open", "timer"]
    },
    {
      "name": "on entries keep user order",
      "entries": [{ "id": "z", "moduleId": "lights-on" }, { "id": "y", "moduleId": "clock" }, { "id": "x", "moduleId": "gym" }],
      "outputs": { "z": {}, "y": {}, "x": {} },
      "expectOrder": ["z", "y", "x"]
    },
    {
      "name": "gym alert sinks below everything, even plain on rows",
      "entries": [{ "id": "gym", "moduleId": "gym" }, { "id": "timer", "moduleId": "timer" }, { "id": "clock", "moduleId": "clock" }],
      "outputs": { "gym": { "alert": true, "alertAt": 9000 }, "timer": { "active": true, "remainingMs": 60000 }, "clock": {} },
      "expectOrder": ["timer", "clock", "gym"]
    },
    {
      "name": "gym alerts sink together, most recent of them first",
      "entries": [{ "id": "gym", "moduleId": "gym" }, { "id": "gymp", "moduleId": "gym-progress" }, { "id": "lan", "moduleId": "wan-status" }],
      "outputs": { "gym": { "alert": true, "alertAt": 1000 }, "gymp": { "alert": true, "alertAt": 2000 }, "lan": { "alert": true, "alertAt": 500 } },
      "expectOrder": ["lan", "gymp", "gym"]
    },
    {
      "name": "gym is off before showAfterHours",
      "entries": [{ "id": "gym", "moduleId": "gym" }, { "id": "clock", "moduleId": "clock" }],
      "outputs": { "gym": { "active": false }, "clock": {} },
      "expectOrder": ["clock"]
    }
  ]
}
"""#
}
