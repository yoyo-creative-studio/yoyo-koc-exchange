const assert = require('assert');
const rules = require('../tier-rules.js');

function oldScores(values) {
  return Object.keys(values).map(period => ({ period, historical_final_score: values[period] }));
}
function newScores(values) {
  return Object.keys(values).map(period => ({ period, content_capped_points: values[period] }));
}

assert.equal(rules.evaluateOld(oldScores({'2026-07': 6, '2026-08': 6}), 'certified'), 'gold');
assert.equal(rules.evaluateOld(oldScores({'2026-07': 5, '2026-08': 6}), 'certified'), 'certified');
assert.equal(rules.evaluateOld(oldScores({'2026-06': 6, '2026-07': 6, '2026-08': 6}), 'certified'), 'platinum');
assert.equal(rules.evaluateNew(newScores({'2026-09': 20, '2026-10': 20}), '2026-10', 'certified'), 'gold');
assert.equal(rules.evaluateNew(newScores({'2026-09': 19, '2026-10': 40}), '2026-10', 'certified'), 'certified');
assert.equal(rules.evaluateNew(newScores({'2026-09': 40, '2026-10': 40, '2026-11': 40}), '2026-11', 'certified'), 'platinum');
assert.equal(rules.evaluateNew(newScores({'2026-09': 40, '2026-10': 39, '2026-11': 40}), '2026-11', 'gold'), 'gold');
assert.equal(rules.evaluateNew(newScores({'2026-08': 40, '2026-09': 20}), '2026-09', 'certified'), 'certified');
assert.equal(rules.capContentPoints(19), 19);
assert.equal(rules.capContentPoints(20), 20);
assert.equal(rules.capContentPoints(39), 20);
assert.equal(rules.capContentPoints(40), 40);
assert.equal(rules.evaluateNew(newScores({'2026-09': 20, '2026-10': 20}), '2026-10', 'platinum'), 'platinum');
assert.equal(rules.evaluateOld(oldScores({'2026-06': 6, '2026-07': 6, '2026-08': 6}), 'platinum'), 'platinum');

console.log('Creator tier rule tests passed (12 acceptance scenarios).');
