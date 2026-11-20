// Cockpit live data, trends and JSON v1 rated load store rates in MW.
// Convert only at the display and editor boundaries.
const heatRateUnit = 'GJ/h';
const _gigajoulesPerHourPerMegawatt = 3.6;

double? heatRateFromMW(double? value) =>
    value == null ? null : value * _gigajoulesPerHourPerMegawatt;

double? heatRateToMW(double? value) =>
    value == null ? null : value / _gigajoulesPerHourPerMegawatt;
