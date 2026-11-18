// DOWNSTREAM-FORK (2026-11-17): the sort of the search window's strong results. Run with node --test shell/tests/*.test.cjs.
// Runs the real functions from window.js and results.js; nothing else is replaced.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

function load() {
  const window_ = readFileSync(join(__dirname, '../ui/window.js'), 'utf8');
  const results = readFileSync(join(__dirname, '../ui/results.js'), 'utf8');
  const context = vm.createContext({ Intl, state: { ranked: [], sort: 'best' } });
  // results.js's `nameOf`, whole: its signature to the closing brace of its one-line body.
  const nameOf = results.match(/function nameOf\([^)]*\) \{[^}]*\}/);
  assert.ok(nameOf, 'nameOf was not found in results.js: this test must be told where it moved');
  vm.runInContext(nameOf[0], context);
  const from = window_.indexOf('// SORT-BEGIN'), to = window_.indexOf('// SORT-END');
  assert.ok(from >= 0 && to > from, 'the SORT-BEGIN and SORT-END markers are gone from window.js');
  vm.runInContext(window_.slice(from, to), context);
  return context;
}

// In the search's order: the best match first.
const hits = [
  { path: '/a/img10.jpg', modified: 300, size: 50 },
  { path: '/b/Apple.pdf', modified: 100, size: 900 },
  { path: '/c/img2.jpg', modified: 300, size: 50 },
  { path: '/d/zebra.txt', modified: 200, size: 10 },
  { path: String.raw`C:\e\Émile.doc`, modified: 50, size: 700 },   // a Windows path
];
const order = (context, key) => context.sortedHits(hits, key).map((hit) => context.nameOf(hit.path));

test('best match is the search\'s own order, untouched', () => {
  const context = load();
  assert.equal(context.sortedHits(hits, 'best'), hits);
  assert.equal(context.sortedHits(hits, 'no such sort'), hits);
});

test('date and size sort both ways, and ties keep the search\'s order', () => {
  const context = load();
  assert.deepEqual(order(context, 'newest'), ['img10.jpg', 'img2.jpg', 'zebra.txt', 'Apple.pdf', 'Émile.doc']);
  assert.deepEqual(order(context, 'oldest'), ['Émile.doc', 'Apple.pdf', 'zebra.txt', 'img10.jpg', 'img2.jpg']);
  assert.deepEqual(order(context, 'largest'), ['Apple.pdf', 'Émile.doc', 'img10.jpg', 'img2.jpg', 'zebra.txt']);
  assert.deepEqual(order(context, 'smallest'), ['zebra.txt', 'img10.jpg', 'img2.jpg', 'Émile.doc', 'Apple.pdf']);
});

test('names sort the way a person reads them: no case, no accents, numbers by value, Windows paths too', () => {
  const context = load();
  assert.deepEqual(order(context, 'name-az'), ['Apple.pdf', 'Émile.doc', 'img2.jpg', 'img10.jpg', 'zebra.txt']);
  assert.deepEqual(order(context, 'name-za'), ['zebra.txt', 'img10.jpg', 'img2.jpg', 'Émile.doc', 'Apple.pdf']);
});

test('sorting does not change the list it was given, and a result without a date or size still sorts', () => {
  const context = load();
  const before = hits.map((hit) => hit.path);
  context.sortedHits(hits, 'largest');
  assert.deepEqual(hits.map((hit) => hit.path), before);
  const odd = [{ path: '/x/a' }, { path: '/x/b', modified: 5, size: 5 }];
  assert.deepEqual(context.sortedHits(odd, 'newest').map((hit) => hit.path), ['/x/b', '/x/a']);
  assert.deepEqual(context.sortedHits([], 'newest'), []);
});

test('strongHits sorts only the strong results, by the chosen sort', () => {
  const context = load();
  context.state.ranked = hits;
  context.state.sort = 'largest';
  assert.equal(context.strongHits()[0].path, '/b/Apple.pdf');
  context.state.sort = 'best';
  assert.equal(context.strongHits(), hits);
});

test('strongHits sorts again only when the results or the sort change', () => {
  const context = load();
  context.state.ranked = hits;
  context.state.sort = 'largest';
  const first = context.strongHits();
  assert.equal(context.strongHits(), first, 'the same array while nothing changed');
  context.state.sort = 'smallest';
  assert.notEqual(context.strongHits(), first);
  context.state.ranked = [...hits].reverse();
  assert.equal(context.strongHits()[0].path, '/d/zebra.txt', 'new results are sorted too');
});
