# Web Frames component catalog

A local live React catalog embedded in the main Web Frames document window. Components are imported from their original source, not reconstructed from screenshots. This runtime is independent of the Astra/Codex bridge and does not consume model quota.

## Start

Node 22.12+ is required. Install the target project's dependencies normally first.

```sh
cd Tools/component-catalog
npm ci
node server.mjs /absolute/path/to/react-project
```

Default address: `http://127.0.0.1:4319`. An optional third argument changes the port. Keep this process running while viewing catalog frames. Web Frames → Project map → choose the same project → Components → Open component catalog. The gear menu accepts a different local address and copies the development helper command. The released app bundles this helper and its Node runtime and launches it automatically for Library previews (after a one-time per-folder approval); the manual command above is for development against a checkout.

Deterministic fixture:

```sh
npm run demo
```

Select `Examples/ComponentCatalogDemo` in Web Frames. It contains six genuine React components, 25 declared props, 16 named examples, global CSS and a React context provider. No separate fixture installation is needed: the runtime supplies React when the target has none installed. When the target has React installed, that version is preferred to avoid duplicate React hooks runtimes.

## Project environment

Optional `.webframes/preview.tsx`:

```tsx
import '../src/styles.css';
import { ThemeProvider } from '../src/theme';
export function Wrapper({ children, theme }) {
  return <ThemeProvider theme={theme}>{children}</ThemeProvider>;
}
```

Import global CSS here and connect providers, routers or mock data as appropriate. The wrapper is rendered separately inside each preview. Use fixture data and mocked actions when the real component performs mutations on mount.

Optional `.webframes/catalog.json`:

```json
{"examples":{"Button":[{"name":"Primary","args":{"children":"Continue","variant":"primary"}}]}}
```

The UI edits props, switches examples, width and light/dark theme, displays callback events and saves named examples in this WebKit/browser profile's localStorage. Saved examples do not edit the imported source. A frame added to the canvas stores its complete JSON args, theme and project identity in its URL; it remains independent of later edits to a saved example. These local examples are not collaborative or stored in the .webframes document. Do not put credentials in preview args/URLs.

## Support and limits

- Exported React functions/arrows, default exports, local export aliases, inline memo/forwardRef bodies containing JSX. Exported classes with JSX are listed; props controls for class declarations are not inferred yet.
- Local TypeScript interfaces/type literals/unions and literal destructured defaults → string, number, boolean, enum, callback and JSON controls. Unknown/imported/complex types can be supplied through JSON, without fabricated type information.
- Plain HTML pages belong in the existing live page map; Vue, Svelte, React Native, server components and framework-only modules require separate adapters.
- `@/` and `~/` resolve to src when present, otherwise project root. Other aliases, framework plugins, Tailwind processing, monorepo dependency boundaries and imported prop type analysis are not automatically reproduced. Existing Vite/Next configs are deliberately not executed.
- Gallery previews have a compact scale; the detail view renders at its selected viewport width. No automatic screenshot inventory.
- File-level imports are labelled “Source references”; they are not claims about observed runtime usage.
- Named project examples currently match the component name. For same-named exports in multiple files, use local saved examples (keyed by source/export identity) until per-export config keys are added.
- Bounded static discovery (1,500 source files / 12 MB, 300 KB per source). Source changes trigger rediscovery and a page refresh; unsaved inspector edits reset. Saved examples survive refresh.
- Preview processes execute trusted project UI in the browser, including any requests made by that code. There is no automatic guarantee that an arbitrary component is free of side effects. The catalog itself has no source-write endpoint.

## Boundaries and validation

Server binds only to 127.0.0.1; Host and Origin must match. Vite filesystem allowlist contains the project/runtime/dependency roots, not the whole machine. Node package config/env from the target are not automatically loaded. Native connection checks protocol and root path. Add-to-canvas accepts only main-frame messages from the connected local origin, known component IDs and matching project identity. Reusing the port for another project shows an explicit mismatch instead of rendering the wrong component.

`npm test` checks export/props discovery, source references, deterministic identity, skipped dependency/build folders, symlinks and cyclic aliases. Native ComponentCatalogueTests checks local-origin validation and old-document/scan persistence compatibility.

## Project CSS compatibility

Next.js PostCSS arrays of package names and `[name, options]` entries are resolved
from the selected project before being passed to Vite. Standard plugin maps
continue through Vite's loader. Project configuration files are not rewritten.

When a project has a PostCSS configuration, the native app uses an existing
user-installed Node (22.12+) to run that project's CSS toolchain. Native addons
such as Tailwind's Lightning CSS cannot load inside the separately signed
bundled runtime while its library validation is enabled. The bundled runtime
keeps this protection; projects without custom CSS configuration continue to use it.

## Preview recovery (September 2026)

The grid loads at most 12 previews per page. Required props without data show a setup message before rendering; fill Props or supply named examples. Saved examples are reused in the grid. A failed component is isolated; Retry preview remounts it. Readiness indicators stay neutral until a render succeeds. Invalid example entries are ignored. PostCSS configuration is loaded before Vite starts; missing plugins produce a visible styles warning while the catalogue remains usable. After fixing project PostCSS configuration, restart previews. Native Refresh restarts an exited helper and refreshes the static inventory.
