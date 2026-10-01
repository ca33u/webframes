// Missing required inputs are a setup state, not a crashed component.
export function missingProps(component, args = {}) {
  return (component.props || []).filter(p => p.required && p.kind !== 'action' && args[p.name] === undefined).map(p => p.name);
}
export function validExamples(value) {
  const result = {};
  if (!value || typeof value !== 'object' || Array.isArray(value)) return result;
  for (const [name, examples] of Object.entries(value)) {
    if (!Array.isArray(examples)) continue;
    result[name] = examples.filter(e => e && typeof e.name === 'string' && e.args && typeof e.args === 'object' && !Array.isArray(e.args));
  }
  return result;
}
export function initialState(c, manifest, saved = {}) {
  const local = Object.values(saved[c.id] || {}).find(s => s?.args && typeof s.args === 'object' && !Array.isArray(s.args));
  return local || {args: {...c.defaults, ...(manifest.examples[c.name]?.[0]?.args || {})}, theme:'light', width:640, background:'solid'};
}
