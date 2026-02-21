async function fetchPage(paginator) {
  const result = await paginator.nextPage();
  return result;
}

module.exports = { fetchPage };
