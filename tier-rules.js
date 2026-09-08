(function(root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.CreatorTierRules = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function() {
  var RANK = { certified: 0, gold: 1, platinum: 2 };

  function previousPeriod(period) {
    var parts = String(period || '').split('-');
    var year = Number(parts[0]);
    var month = Number(parts[1]) - 1;
    if (month < 1) { month = 12; year -= 1; }
    return year + '-' + String(month).padStart(2, '0');
  }

  function capContentPoints(rawPoints) {
    var raw = Math.max(0, Number(rawPoints) || 0);
    if (raw >= 40) return 40;
    if (raw >= 20) return 20;
    return raw;
  }

  function scoreMap(rows, field) {
    return (rows || []).reduce(function(result, row) {
      if (row && /^\d{4}-\d{2}$/.test(String(row.period || ''))) {
        result[row.period] = Number(row[field]) || 0;
      }
      return result;
    }, {});
  }

  function consecutiveEndingAt(rows, endPeriod, months, field, threshold, inclusive, floorPeriod) {
    var scores = scoreMap(rows, field);
    var period = endPeriod;
    for (var i = 0; i < months; i++) {
      if (floorPeriod && period < floorPeriod) return false;
      var value = scores[period];
      if (value == null || (inclusive ? value < threshold : value <= threshold)) return false;
      period = previousPeriod(period);
    }
    return true;
  }

  function highestTier(currentTier, candidateTier) {
    return (RANK[candidateTier] || 0) > (RANK[currentTier] || 0) ? candidateTier : currentTier;
  }

  function evaluateOld(rows, currentTier) {
    var candidate = consecutiveEndingAt(rows, '2026-08', 3, 'historical_final_score', 5, false)
      ? 'platinum'
      : (consecutiveEndingAt(rows, '2026-08', 2, 'historical_final_score', 5, false) ? 'gold' : 'certified');
    return highestTier(currentTier || 'certified', candidate);
  }

  function evaluateNew(rows, period, currentTier) {
    if (String(period || '') < '2026-09') return currentTier || 'certified';
    var candidate = consecutiveEndingAt(rows, period, 3, 'content_capped_points', 40, true, '2026-09')
      ? 'platinum'
      : (consecutiveEndingAt(rows, period, 2, 'content_capped_points', 20, true, '2026-09') ? 'gold' : 'certified');
    return highestTier(currentTier || 'certified', candidate);
  }

  return {
    capContentPoints: capContentPoints,
    consecutiveEndingAt: consecutiveEndingAt,
    evaluateOld: evaluateOld,
    evaluateNew: evaluateNew,
    highestTier: highestTier,
    previousPeriod: previousPeriod
  };
});
