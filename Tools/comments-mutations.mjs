import {createHash, randomUUID} from 'node:crypto';
import {realpathSync, existsSync} from 'node:fs';
import {writeFile, readFile, rename, unlink} from 'node:fs/promises';
import {homedir} from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';

export function inboxFor(file, base = path.join(homedir(), 'Library/Application Support/Web Frames/MCP Requests')) {
  return path.join(base, createHash('sha256').update(realpathSync(file)).digest('hex'));
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
  const directory = inboxFor(project.file, base);
  if (!existsSync(directory)) throw Error('Open this project in Web Frames first. Enable Allow agents to resolve comments in Settings.');
  const id = randomUUID();
  const request = path.join(directory, id + '.request.json');
  const reply = path.join(directory, id + '.response.json');
  const temporary = request + '.tmp';
  try {
    const end = Date.now() + timeout;
    await writeFile(temporary, JSON.stringify({id, deadline: end / 1000, comments, resolved: args.resolved}), {flag: 'wx', mode: 0o600});
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
