import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import {
  classifyPlatform,
  configPath,
  linuxInstallPlan,
  parseOsRelease,
  writeConfig,
} from '../lib/system.js';

test('classifies the supported host platforms', () => {
  assert.equal(classifyPlatform('linux'), 'linux');
  assert.equal(classifyPlatform('win32'), 'windows');
  assert.equal(classifyPlatform('darwin'), 'unsupported');
});

test('reads quoted fields from os-release', () => {
  assert.deepEqual(parseOsRelease('ID=ubuntu\nPRETTY_NAME="Ubuntu 24.04 LTS"\n'), {
    ID: 'ubuntu',
    PRETTY_NAME: 'Ubuntu 24.04 LTS',
  });
});

test('creates an apt Docker plan for Debian and Ubuntu only', () => {
  const plan = linuxInstallPlan('ID=debian\nPRETTY_NAME="Debian GNU/Linux"\n');
  assert.equal(plan.supported, true);
  assert.deepEqual(plan.commands.at(-1), ['sudo', ['usermod', '-aG', 'docker', '<user>']]);

  const unsupported = linuxInstallPlan('ID=fedora\nPRETTY_NAME="Fedora Linux"\n');
  assert.equal(unsupported.supported, false);
  assert.match(unsupported.reason, /Fedora Linux/);
});

test('writes devcontainer.json without replacing an existing file by default', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'devcontainer-setup-cli-'));
  try {
    const config = { name: 'Example', image: 'ghcr.io/example/image:latest' };
    const first = await writeConfig(directory, config);
    assert.equal(first.written, true);
    assert.equal(first.path, configPath(directory));
    assert.deepEqual(JSON.parse(await readFile(first.path, 'utf8')), config);

    const second = await writeConfig(directory, { name: 'Replacement' });
    assert.deepEqual(second, { written: false, path: first.path, reason: 'exists' });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
