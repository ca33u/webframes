"""Declare exact helper inputs/outputs for Xcode's enabled script sandbox."""
from pathlib import Path

def generate(root):
    root = Path(root)
    pairs = []
    for name in ('codex-bridge.mjs', 'context-mcp.mjs', 'comments-mcp.mjs', 'comments-mutations.mjs'):
        pairs.append((root / name, Path('Resources/Tools') / name))
    catalog = root / 'component-catalog'
    for name in ('server.mjs','project-postcss.mjs','preview-boundaries.mjs','discover.mjs','package.json','package-lock.json','client','node_modules'):
        path = catalog / name
        for item in [path] + (list(path.rglob('*')) if path.is_dir() else []):
            pairs.append((item, Path('Resources/Tools/component-catalog') / item.relative_to(catalog)))
    runtime = root / 'runtime-dist/node-v22.23.2-darwin-arm64'
    pairs += [(runtime / 'bin/node', Path('Helpers/node')),
              (runtime / 'LICENSE', Path('Resources/ThirdPartyNotices/Node.js-LICENSE.txt'))]
    inputs = {'$(SRCROOT)/Tools/package_helpers.py', '$(SRCROOT)/Tools/node.entitlements'}
    outputs = {'Resources/Tools/runtime-manifest.json'}
    for source, dest in pairs:
        inputs.add('$(SRCROOT)/Tools/' + str(source.relative_to(root)))
        outputs.add(str(dest))
        if source.suffix == '.node' or source.name == 'node': outputs.add(str(dest) + '.cstemp')
    # Explicit directory access is needed for traversal and mkdir, too.
    for item in list(outputs):
        for parent in Path(item).parents:
            if str(parent) not in ('.', 'Resources'): outputs.add(str(parent))
    (root / 'runtime-inputs.xcfilelist').write_text('\n'.join(sorted(inputs)) + '\n')
    (root / 'runtime-outputs.xcfilelist').write_text('\n'.join('$(TARGET_BUILD_DIR)/$(WRAPPER_NAME)/Contents/' + p for p in sorted(outputs)) + '\n')

if __name__ == '__main__': generate(Path(__file__).resolve().parent)
