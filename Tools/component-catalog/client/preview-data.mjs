// Missing required inputs are a setup state, not a crashed component.
export function previewErrorMessage(error) {
  const message=String(error?.message||error);
  if(/(?:Can't find variable:|is not defined).*\b(?:process|__dirname|require|Buffer)\b|\b(?:process|__dirname|require|Buffer)\b is not defined/.test(message)) {
    return 'This component imports code that needs a Node/Next server environment. Supply mock providers or a browser-only wrapper in .webframes/preview.tsx, or open the live page. '+message;
  }
  return message;
}
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
