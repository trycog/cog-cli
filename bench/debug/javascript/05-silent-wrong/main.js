const { DataFrame } = require('./dataframe');
const { groupBy } = require('./groupby');
const { sum } = require('./stats');
const { aggregate } = require('./aggregator');
const { pivot } = require('./pivot');

function main() {
  const df = new DataFrame(
    ['year', 'quarter', 'revenue'],
    [
      [2021, 'Q1', 250],
      [2021, 'Q2', 300],
      [2021, 'Q3', 280],
      [2021, 'Q4', 370],
      [2022, 'Q1', 320],
      [2022, 'Q2', 380],
      [2022, 'Q3', 350],
      [2022, 'Q4', 450],
      [2023, 'Q1', 400],
      [2023, 'Q2', 460],
      [2023, 'Q3', 420],
      [2023, 'Q4', 520],
      [2024, 'Q1', 480],
      [2024, 'Q2', 540],
      [2024, 'Q3', 500],
      [2024, 'Q4', 580],
    ]
  );

  const groups = groupBy(df, 'year', 'revenue');
  const totals = aggregate(groups, sum);

  const years = [2021, 2022, 2023, 2024];
  const pivoted = pivot(totals, years);

  const parts = Object.entries(pivoted)
    .map(([k, v]) => `${k}=$${v}`)
    .join(' ');

  console.log(`Pivot: ${parts}`);
}

main();
