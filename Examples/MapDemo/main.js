import { MetricCard, PageHeader } from './components.js';
document.querySelector('main').prepend(PageHeader(document.body.dataset.title));
for (const [label,value] of [['Active projects','12'],['Team members','8'],['Completed this week','24']]) document.querySelector('.metrics').append(MetricCard(label,value));
document.querySelector('button').onclick = e => { e.target.textContent = 'Saved ✓'; };
