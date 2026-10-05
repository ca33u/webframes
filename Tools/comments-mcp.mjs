import {setCommentStatus, updateFrameImage, storedImage} from './comments-mutations.mjs';
import {readFileSync, readdirSync, statSync} from 'node:fs';
import {homedir} from 'node:os';
import path from 'node:path';
import {createInterface} from 'node:readline';

const DEFAULT_PROJECTS_DIR = path.join(
  homedir(), 'Library', 'Application Support', 'Web Frames', 'Projects'
);

function argument(name) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const scopedProject = argument('--project') || process.env.WEBFRAMES_PROJECT;
const projectsDir = process.env.WEBFRAMES_PROJECTS_DIR || DEFAULT_PROJECTS_DIR;

const emptySchema = {type: 'object', properties: {}, additionalProperties: false};
const projectProperty = {
  type: 'string',
  description: 'Project id from list_projects. Optional when this server is scoped to one project.',
};

const tools = [
  {
    name: 'update_frame_image',
    description: 'Replace an existing image frame with a fresh PNG or JPEG screenshot from an absolute local file path (up to 8 MiB). Capture the correct screen using your own simulator/emulator tools first. Requires the project open and Allow agents to update frame images enabled. Preserves frame geometry, links and original comment screenshots; supports Undo. Does not resolve comments, build or launch apps.',
    inputSchema: {type: 'object', properties: {project: projectProperty, frame_id: {type: 'string', minLength: 1, maxLength: 200}, image_path: {type: 'string', minLength: 1}}, required: ['frame_id', 'image_path'], additionalProperties: false},
    annotations: {readOnlyHint: false, destructiveHint: false, idempotentHint: true},
  },
  {
    name: 'list_frames',
    description: 'List saved frames and their ids, types, sizes and image hashes. Use get_frame to inspect current pixels, or frame.id from a comment to update its image.',
    inputSchema: {type: 'object', properties: {project: projectProperty}, additionalProperties: false},
    annotations: {readOnlyHint: true},
  },
  {
    name: 'get_frame',
    description: 'Read a saved frame and its current image as MCP image content when available. Comment screenshots remain the original evidence; use this tool to inspect an updated image frame.',
    inputSchema: {type: 'object', properties: {project: projectProperty, frame_id: {type: 'string', minLength: 1, maxLength: 200}}, required: ['frame_id'], additionalProperties: false},
    annotations: {readOnlyHint: true},
  },
  {
    name: 'set_comment_status',
    description: 'Resolve or reopen 1–100 comments after verifying the requested work. Requires the project open in Web Frames and the user-enabled Allow agents to resolve comments setting. Changes are saved by the app and can be undone. Does not edit source code.',
    inputSchema: {type: 'object', properties: {project: projectProperty, ids: {type: 'array', minItems: 1, maxItems: 100, items: {type: 'string'}}, resolved: {type: 'boolean'}}, required: ['ids', 'resolved'], additionalProperties: false},
    annotations: {readOnlyHint: false, destructiveHint: false, idempotentHint: true},
  },
  {
    name: 'list_projects',
    description: 'List Web Frames projects and their unresolved comment counts.',
    inputSchema: emptySchema,
    annotations: {readOnlyHint: true},
  },
  {
    name: 'list_comments',
    description: 'List comments with frame, URL, viewport, selector and source-root context. Screenshot data is omitted; use get_comment for one comment.',
    inputSchema: {
      type: 'object',
      properties: {
        project: projectProperty,
        status: {type: 'string', enum: ['open', 'resolved', 'all'], default: 'open'},
      },
      additionalProperties: false,
    },
    annotations: {readOnlyHint: true},
  },
  {
    name: 'get_comment',
    description: 'Read one comment and its full element context. Returns its attached screenshot as an MCP image when available.',
    inputSchema: {
      type: 'object',
      properties: {
        project: projectProperty,
        id: {type: 'string', minLength: 1, maxLength: 200},
      },
      required: ['id'],
      additionalProperties: false,
    },
    annotations: {readOnlyHint: true},
  },
  {
    name: 'get_agent_brief',
    description: 'Build a compact implementation brief from all unresolved comments in one Web Frames project.',
    inputSchema: {
      type: 'object',
      properties: {project: projectProperty},
      additionalProperties: false,
    },
    annotations: {readOnlyHint: true},
  },
];

function projectFiles() {
  if (scopedProject) return [path.resolve(scopedProject)];
  try {
    return readdirSync(projectsDir)
      .filter(name => name.endsWith('.webframes'))
      .map(name => path.join(projectsDir, name));
  } catch {
    return [];
  }
}

function readProject(file) {
  const resolved = path.resolve(file);
  if (!resolved.endsWith('.webframes')) throw new Error('Expected a .webframes project file');
  // Web Frames 1.0.2+ saves a package: <name>.webframes/document.json with
  // screenshots under images/. 1.0.1 and earlier wrote one JSON file.
  const isPackage = statSync(resolved).isDirectory();
  const documentFile = isPackage ? path.join(resolved, 'document.json') : resolved;
  const data = JSON.parse(readFileSync(documentFile, 'utf8'));
  const projectMap = data.projectMap || {};
  const annotations = Array.isArray(data.annotations) ? data.annotations : [];
  const frames = Array.isArray(data.frames) ? data.frames : [];
  const byFrame = new Map(frames.map(frame => [frame.id, frame]));
  // Sections name canvas areas ("Onboarding", "Settings"). A frame belongs
  // to the smallest section containing its card's center, as in the app.
  const num = v => (Number.isFinite(v) ? v : NaN);
  const sections = (Array.isArray(data.sections) ? data.sections : [])
    .filter(s => s && typeof s.name === 'string' && [s.x, s.y, s.w, s.h].every(v => Number.isFinite(num(v))))
    .sort((a, b) => a.w * a.h - b.w * b.h);
  const sectionOf = new Map();
  for (const frame of frames) {
    const cx = num(frame.x) + (num(frame.w) + 2) / 2, cy = num(frame.y) + (num(frame.h) + 35) / 2;
    const s = sections.find(s => cx >= s.x && cx <= s.x + s.w && cy >= s.y && cy <= s.y + s.h);
    if (s) sectionOf.set(frame.id, s.name.slice(0, 200));
  }
  return {
    id: path.basename(resolved, '.webframes'),
    file: resolved,
    modifiedAt: statSync(documentFile).mtime.toISOString(),
    name: typeof data.name === 'string' && data.name ? data.name : 'Untitled',
    sourceRoot: typeof projectMap.rootPath === 'string' ? projectMap.rootPath : '',
    framework: typeof projectMap.framework === 'string' ? projectMap.framework : '',
    annotations,
    byFrame,
    sectionOf,
    packageRoot: isPackage ? resolved : null,
  };
}

function loadProjects() {
  return projectFiles().flatMap(file => {
    try { return [readProject(file)]; }
    catch { return []; }
  }).sort((a, b) => b.modifiedAt.localeCompare(a.modifiedAt));
}

function selectProject(project) {
  const projects = loadProjects();
  if (!projects.length) throw new Error('No saved Web Frames projects were found');
  if (scopedProject) return projects[0];
  if (project) {
    const match = projects.find(item => item.id === project || item.file === path.resolve(project));
    if (!match) throw new Error('Unknown Web Frames project. Call list_projects first.');
    return match;
  }
  if (projects.length === 1) return projects[0];
  throw new Error('Choose a project id from list_projects');
}

function elementContext(annotation) {
  const element = annotation?.element && typeof annotation.element === 'object'
    ? annotation.element : {};
  return {
    selector: element.selector || element.path || element.tagName || '—',
    tagName: element.tagName || '',
    text: typeof element.text === 'string' ? element.text.slice(0, 500) : '',
    component: element.component || '',
    className: typeof element.className === 'string' ? element.className.slice(0, 500) : '',
    bounds: element.bounds || null,
    styles: element.styles || null,
    area: areaContext(annotation, element),
  };
}

// Area comments (selected region instead of a point): the region in CSS
// pixels of the page viewport and the elements visible inside it.
function areaContext(annotation, element) {
  const a = element.area;
  if (!a || typeof a !== 'object' || !annotation?.area) return null;
  const n = v => (Number.isFinite(v) ? Math.round(v) : 0);
  const inside = Array.isArray(element.areaElements) ? element.areaElements.slice(0, 12)
    .filter(item => item && typeof item.selector === 'string')
    .map(item => ({selector: item.selector.slice(0, 300), text: typeof item.text === 'string' ? item.text.slice(0, 80) : ''})) : [];
  return {x: n(a.x), y: n(a.y), width: n(a.width), height: n(a.height), elements: inside};
}

function areaLine(area) {
  const inside = area.elements.map(e => (e.text ? `${e.selector} "${e.text}"` : e.selector)).join(', ');
  return `Area: x ${area.x}, y ${area.y}, ${area.width}×${area.height} CSS px of the viewport${inside ? `; contains ${inside}` : ''}`;
}

function contextURL(value) {
  if (typeof value !== 'string') return '';
  try {
    const url = new URL(value);
    url.username = ''; url.password = '';
    for (const name of [...url.searchParams.keys()]) {
      if (/token|api.?key|authorization|secret|password/i.test(name)) url.searchParams.delete(name);
    }
    return url.href;
  } catch { return value.replace(/([?&](?:token|access_token|api_key)=)[^&#]*/gi, '$1[redacted]'); }
}

function publicComment(project, annotation) {
  const frame = project.byFrame.get(annotation.frameId) || {};
  const element = elementContext(annotation);
  return {
    id: annotation.id,
    number: annotation.num ?? null,
    comment: annotation.comment || '',
    resolved: Boolean(annotation.resolved),
    resolvedBy: annotation.resolvedBy || null,
    resolvedAt: annotation.resolvedAt || null,
    color: annotation.color || '',
    frame: {
      id: annotation.frameId || frame.id || '',
      isImage: Boolean(frame.isImage),
      label: annotation.frameLabel || frame.label || '',
      url: contextURL(annotation.frameUrl || frame.url || ''),
      viewport: frame.w && frame.h ? `${Math.round(frame.w)}×${Math.round(frame.h)}` : null,
      section: project.sectionOf.get(annotation.frameId) || null,
      pin: {xPercent: annotation.xPct ?? null, yPercent: annotation.yPct ?? null},
    },
    element,
    edits: annotation.edits || {},
    origin: annotation.astraFindingID ? 'astra' : 'manual',
    astraFindingID: annotation.astraFindingID || null,
  };
}

function filteredComments(project, status = 'open') {
  if (!['open', 'resolved', 'all'].includes(status)) throw new Error('Invalid comment status');
  return project.annotations
    .filter(annotation => status === 'all'
      || (status === 'resolved' ? Boolean(annotation.resolved) : !annotation.resolved))
    .map(annotation => publicComment(project, annotation));
}

function textContent(value) {
  return [{type: 'text', text: JSON.stringify(value, null, 2)}];
}

function publicFrame(project, frame) {
  // Package filenames already carry the hash; list_frames avoids reading every image.
  const ref = /^wf-image:images\/([0-9a-f]{64})\.(png|jpg|jpeg|webp|gif|svg|heic)$/.exec(frame.imgUrl || '');
  return {
    id: frame.id, label: frame.label || '', url: contextURL(frame.url || ''), isImage: Boolean(frame.isImage),
    viewport: {width: frame.w, height: frame.h},
    section: project.sectionOf.get(frame.id) || null,
    imageHash: ref?.[1] || storedImage(frame.imgUrl, project.packageRoot)?.hash || null,
    imageUpdatedBy: frame.imageUpdatedBy || null, imageUpdatedAt: frame.imageUpdatedAt || null,
  };
}

function getScreenshot(annotation, project) {
  return imageContent(annotation?.element?.screenshot, project);
}

function imageContent(value, project) {
  const image = storedImage(value, project.packageRoot);
  return image ? {type: 'image', mimeType: image.mimeType, data: image.bytes.toString('base64')} : null;
}

async function callTool(name, args = {}) {
  if (name === 'list_projects') {
    return textContent(loadProjects().map(project => ({
      id: project.id,
      name: project.name,
      sourceRoot: project.sourceRoot,
      framework: project.framework,
      modifiedAt: project.modifiedAt,
      openComments: project.annotations.filter(item => !item.resolved).length,
      totalComments: project.annotations.length,
    })));
  }

  const project = selectProject(args.project);
  if (name === 'update_frame_image') return textContent(await updateFrameImage(project, args));
  if (name === 'list_frames') return textContent({project: {id: project.id, name: project.name}, frames: [...project.byFrame.values()].map(frame => publicFrame(project, frame))});
  if (name === 'get_frame') {
    const frame = project.byFrame.get(args.frame_id);
    if (!frame) throw new Error('Frame not found. Call list_frames first.');
    const content = textContent({project: {id: project.id, name: project.name}, frame: publicFrame(project, frame)});
    const screenshot = frame.isImage ? imageContent(frame.imgUrl, project) : null;
    if (screenshot) content.push(screenshot);
    return content;
  }
  if (name === 'set_comment_status') return textContent(await setCommentStatus(project, args));
  if (name === 'list_comments') {
    return textContent({
      project: {id: project.id, name: project.name, sourceRoot: project.sourceRoot, framework: project.framework},
      comments: filteredComments(project, args.status || 'open'),
    });
  }

  if (name === 'get_comment') {
    const annotation = project.annotations.find(item => item.id === args.id);
    if (!annotation) throw new Error('Comment not found');
    const content = textContent({
      project: {id: project.id, name: project.name, sourceRoot: project.sourceRoot, framework: project.framework},
      comment: publicComment(project, annotation),
    });
    const screenshot = getScreenshot(annotation, project);
    if (screenshot) content.push(screenshot);
    return content;
  }

  if (name === 'get_agent_brief') {
    const comments = filteredComments(project, 'open');
    const lines = [
      `Web Frames project: ${project.name}`,
      `Source root: ${project.sourceRoot || '(not connected)'}`,
      `Framework: ${project.framework || '(unknown)'}`,
      `Open comments: ${comments.length}`,
      '',
      ...comments.flatMap(comment => [
        `#${comment.number ?? '?'} [${comment.id}] ${comment.frame.label || comment.frame.url} · frame_id: ${comment.frame.id}${comment.frame.isImage ? ' (image)' : ''}`,
        `URL: ${comment.frame.url || '—'} · viewport: ${comment.frame.viewport || '—'}`,
        ...(comment.frame.section ? [`Section: ${comment.frame.section}`] : []),
        `Element: ${comment.element.selector}`,
        ...(comment.element.area ? [areaLine(comment.element.area)] : []),
        `Comment: ${comment.comment || '(empty)'}`,
        '',
      ]),
      'Inspect the source, implement the requested changes, run appropriate checks, and report which comment ids were addressed. Only use set_comment_status after verifying the fix and when the user has enabled comment changes in Web Frames Settings.',
      'For image frames, use your own build and simulator/emulator tools to open the correct updated screen and capture a PNG or JPEG. Use update_frame_image with frame_id and the absolute image_path when frame image updates are enabled. Use get_frame for current pixels; get_comment keeps the original screenshot. Replacing an image does not resolve its comments.',
    ];
    return [{type: 'text', text: lines.join('\n')}];
  }

  throw new Error('Unknown tool');
}

const lines = createInterface({input: process.stdin, crlfDelay: Infinity});
lines.on('line', async line => {
  let request;
  try {
    request = JSON.parse(line);
    if (request.id === undefined) return;
    let result;
    switch (request.method) {
      case 'initialize':
        result = {
          protocolVersion: request.params?.protocolVersion || '2024-11-05',
          capabilities: {tools: {}},
          serverInfo: {name: 'webframes-comments', version: '0.1.0'},
        };
        break;
      case 'ping': result = {}; break;
      case 'tools/list': result = {tools}; break;
      case 'tools/call':
        try { result = {content: await callTool(request.params?.name, request.params?.arguments || {})}; }
        catch (error) { result = {isError: true, content: [{type: 'text', text: error.message}]}; }
        break;
      default: throw new Error('Unsupported method');
    }
    process.stdout.write(JSON.stringify({jsonrpc: '2.0', id: request.id, result}) + '\n');
  } catch (error) {
    if (request?.id !== undefined) {
      process.stdout.write(JSON.stringify({
        jsonrpc: '2.0', id: request.id,
        error: {code: -32602, message: error.message},
      }) + '\n');
    }
  }
});
