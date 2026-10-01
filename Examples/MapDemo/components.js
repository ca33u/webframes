export function MetricCard(label, value) {
  const node = document.createElement('article');
  node.innerHTML = `<small>${label}</small><h2>${value}</h2><p>Updated just now</p>`;
  return node;
}
export function PageHeader(title) {
  const node = document.createElement('header');
  node.innerHTML = `<small>NORTHSTAR WORKSPACE</small><h1>${title}</h1><p>Your project, in one place.</p>`;
  return node;
}
