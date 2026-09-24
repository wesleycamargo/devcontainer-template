import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { run } from '../lib/cli.js';

function promptsFor({ selections, tasks = ['docker', 'devcontainer', 'ghcr', 'configuration'], directory, confirmations = [false] }) {
  const messages = [];
  const successes = [];
  return {
    intro: () => {},
    outro: (message) => messages.push(message),
    cancel: (message) => messages.push(message),
    isCancel: () => false,
    multiselect: async () => tasks,
    select: async () => selections.shift(),
    text: async () => directory,
    confirm: async () => confirmations.shift(),
    log: {
      error: () => {},
      info: () => {},
      step: () => {},
      success: (message) => successes.push(message),
      warn: () => {},
    },
    messages,
    successes,
  };
}

function successfulRunner(calls) {
  return async (command, args, options = {}) => {
    calls.push({ command, args, options });
    return { code: 0 };
  };
}

test('Linux flow selects an image and writes a safe configuration', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'devcontainer-setup-cli-linux-'));
  try {
    const calls = [];
    const prompts = promptsFor({ selections: ['ai-devbox'], directory });
    await run({
      platform: 'linux',
      cwd: directory,
      prompts,
      runner: successfulRunner(calls),
      readRelease: async () => 'ID=ubuntu\n',
      username: 'developer',
    });

    assert.deepEqual(JSON.parse(await readFile(join(directory, '.devcontainer', 'devcontainer.json'), 'utf8')), {
      name: 'AI Devbox',
      image: 'ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image:latest',
    });
    assert(calls.some(({ command, args }) => command === 'docker' && args[0] === 'info'));
    assert.equal(calls.some(({ command }) => command === 'wsl'), false);
    assert.match(prompts.messages.at(-1), /Wrote/);
    assert(prompts.successes.some((message) => /Docker Engine is already installed/.test(message)));
    assert(prompts.successes.some((message) => /Dev Container CLI is already installed/.test(message)));
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('selected tasks can skip Docker, the Dev Container CLI, and GHCR login', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'devcontainer-setup-cli-selective-'));
  try {
    const calls = [];
    const prompts = promptsFor({
      selections: ['ai-devbox'],
      tasks: ['configuration'],
      directory,
    });
    await run({
      platform: 'linux',
      cwd: directory,
      prompts,
      runner: successfulRunner(calls),
    });

    assert.equal(calls.length, 0);
    assert.deepEqual(JSON.parse(await readFile(join(directory, '.devcontainer', 'devcontainer.json'), 'utf8')).image,
      'ghcr.io/wesleycamargo/devcontainer-template/ai-devbox-image:latest');
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('Windows flow targets the selected WSL distribution and never Docker Desktop', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'devcontainer-setup-cli-windows-'));
  try {
    const calls = [];
    const prompts = promptsFor({ selections: ['Ubuntu', 'ai-openhands-devbox'], directory });
    await run({
      platform: 'win32',
      cwd: directory,
      prompts,
      runner: successfulRunner(calls),
      capture: async (command, args) => {
        if (command === 'wsl' && args[0] === '-l') return { code: 0, stdout: 'Ubuntu\n' };
        return { code: 0, stdout: '' };
      },
    });

    assert.deepEqual(JSON.parse(await readFile(join(directory, '.devcontainer', 'devcontainer.json'), 'utf8')), {
      name: 'AI OpenHands Devbox',
      image: 'ghcr.io/wesleycamargo/devcontainer-template/ai-openhands-devbox-image:latest',
    });
    assert(calls.some(({ command, args }) => command === 'wsl' && args.includes('docker')));
    assert.equal(calls.some(({ command }) => command.toLowerCase().includes('desktop')), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
