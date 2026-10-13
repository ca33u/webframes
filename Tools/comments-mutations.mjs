import {createHash, randomUUID} from 'node:crypto';
import {realpathSync, existsSync, readFileSync, constants} from 'node:fs';
import {writeFile, readFile, rename, unlink, open} from 'node:fs/promises';
import {homedir} from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';

export function inboxFor(file, base = path.join(homedir(), 'Library/Application Support/Web Frames/MCP Requests')) {
  return path.join(base, createHash('sha256').update(realpathSync(file)).digest('hex'));
}
export const MAX_IMAGE_BYTES = 8 * 1024 * 1024;

export async function captureSimulatorFrame(project, args, options = {}) {
  if (typeof args.frame_id !== 'string' || !args.frame_id || args.frame_id.length > 200) {
    throw Error('Provide an image frame_id with a saved Simulator Capture recipe.');
  }
  const frame = project.byFrame.get(args.frame_id);
  if (!frame?.isImage || !frame.simulatorCapture || typeof frame.simulatorCapture !== 'object') {
    throw Error('Choose an image frame and save its Simulator Capture settings in Web Frames first.');
  }
  const previous = storedImage(frame.imgUrl, project.packageRoot);
  if (!previous) throw Error('Could not read the current frame image. Reimport it in Web Frames first.');
  return sendRequest(project, {comments: [], resolved: false,
    simulatorCapture: {frameID: frame.id, beforeHash: previous.hash, recipe: frame.simulatorCapture}},
    {timeout: 900000, ...options, setting: 'Allow agents to capture simulator screens'});
}

export async function captureSimulatorFrames(project, args, options = {}) {
  if (!Array.isArray(args.frame_ids) || !args.frame_ids.length || args.frame_ids.length > 20 ||
      args.frame_ids.some(id => typeof id !== 'string' || !id || id.length > 200) ||
      new Set(args.frame_ids).size !== args.frame_ids.length) {
    throw Error('Provide 1–20 unique image frame_ids with saved Simulator Capture recipes.');
  }
  const simulatorCaptures = args.frame_ids.map(id => {
    const frame = project.byFrame.get(id);
    if (!frame?.isImage || !frame.simulatorCapture || typeof frame.simulatorCapture !== 'object') {
      throw Error(`Save Simulator Capture settings for frame ${id} in Web Frames first.`);
    }
    const previous = storedImage(frame.imgUrl, project.packageRoot);
    if (!previous) throw Error(`Could not read the current image for frame ${id}. Reimport it first.`);
    return {frameID: id, beforeHash: previous.hash, recipe: frame.simulatorCapture};
  });
  return sendRequest(project, {comments: [], resolved: false, simulatorCaptures},
    {timeout: 900000, ...options, setting: 'Allow agents to capture simulator screens'});
}

// In-memory data URLs and content-addressed package images have the same byte hash.
export function storedImage(value, packageRoot) {
  if (typeof value !== 'string') return null;
  const ref = /^wf-image:images\/([0-9a-f]{64})\.(png|jpg|jpeg|webp|gif|svg|heic)$/.exec(value);
  const inline = /^data:(image\/[a-z+.-]+);base64,([A-Za-z0-9+/]+=*)$/.exec(value);
  try {
    const bytes = ref && packageRoot
      ? readFileSync(path.join(packageRoot, 'images', `${ref[1]}.${ref[2]}`))
      : inline ? Buffer.from(inline[2], 'base64') : null;
    if (!bytes?.length) return null;
    const hash = createHash('sha256').update(bytes).digest('hex');
    if (ref && hash !== ref[1]) return null;
    const mimeType = inline?.[1] || ({jpg: 'image/jpeg', jpeg: 'image/jpeg', svg: 'image/svg+xml'}[ref[2]] || `image/${ref[2]}`);
    return {bytes, hash, mimeType};
  } catch { return null; }
}

export async function updateFrameImage(project, args, options = {}) {
  if (typeof args.frame_id !== 'string' || !args.frame_id || args.frame_id.length > 200 ||
      typeof args.image_path !== 'string' || !path.isAbsolute(args.image_path)) {
    throw Error('Provide a frame_id and an absolute image_path to a PNG or JPEG screenshot.');
  }
  const frame = project.byFrame.get(args.frame_id);
  if (!frame?.isImage) throw Error('Choose an existing image frame. Read the latest frames or comments again.');
  const previous = storedImage(frame.imgUrl, project.packageRoot);
  if (!previous) throw Error('Could not read the current frame image. Reimport it in Web Frames first.');
  const file = await open(args.image_path, constants.O_RDONLY | constants.O_NONBLOCK);
  let bytes;
  try {
    const info = await file.stat();
    if (!info.isFile() || info.size <= 0 || info.size > MAX_IMAGE_BYTES) throw Error('Provide a regular PNG or JPEG file up to 8 MiB.');
    const chunks = [];
    let size = 0;
    while (true) {
      const buffer = Buffer.alloc(64 * 1024);
      const {bytesRead} = await file.read(buffer);
      if (!bytesRead) break;
      size += bytesRead;
      if (size > MAX_IMAGE_BYTES) throw Error('Screenshot exceeds 8 MiB.');
      chunks.push(buffer.subarray(0, bytesRead));
    }
    bytes = Buffer.concat(chunks);
  } finally { await file.close(); }
  const png = bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  const jpeg = bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
  if (!png && !jpeg) throw Error('Screenshot must be a PNG or JPEG image.');
  return sendRequest(project, {
    comments: [], resolved: false,
    frameImage: {frameID: frame.id, beforeHash: previous.hash,
      dataURL: `data:image/${png ? 'png' : 'jpeg'};base64,${bytes.toString('base64')}`},
  }, {...options, setting: 'Allow agents to update frame images'});
}
export async function setCommentStatus(project, args, {base, timeout = 12000} = {}) {
  if (!Array.isArray(args.ids) || !args.ids.length || args.ids.length > 100 ||
      args.ids.some(id => typeof id !== 'string' || !id || id.length > 200) ||
      new Set(args.ids).size !== args.ids.length || typeof args.resolved !== 'boolean') {
    throw Error('Provide 1–100 unique comment ids and a boolean resolved value.');
  }
  const comments = args.ids.map(id => {
    const item = project.annotations.find(c => c.id === id);
    if (!item) throw Error('Unknown comment id. Read comments again.');
    return {id, comment: item.comment || '', resolved: Boolean(item.resolved)};
  });
  return sendRequest(project, {comments, resolved: args.resolved}, {base, timeout, setting: 'Allow agents to resolve comments'});
}

async function sendRequest(project, payload, {base, timeout = 12000, setting} = {}) {
  const directory = inboxFor(project.file, base);
  if (!existsSync(directory)) throw Error(`Open this project in Web Frames first. Enable ${setting} in Settings.`);
  const id = randomUUID();
  const request = path.join(directory, id + '.request.json');
  const reply = path.join(directory, id + '.response.json');
  const temporary = request + '.tmp';
  try {
    const end = Date.now() + timeout;
    await writeFile(temporary, JSON.stringify({id, deadline: end / 1000, ...payload}), {flag: 'wx', mode: 0o600});
    await rename(temporary, request);
    while (Date.now() < end) {
      try {
        const result = JSON.parse(await readFile(reply, 'utf8'));
        if (result.error) throw Error(result.error);
        return result;
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      await delay(100);
    }
    throw Error('Web Frames did not confirm the change. Open the project, check Settings, and read its status before retrying.');
  } finally {
    await Promise.all([temporary, request, reply].map(file => unlink(file).catch(() => {})));
  }
}
