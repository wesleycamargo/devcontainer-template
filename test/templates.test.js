import assert from 'node:assert/strict';
import test from 'node:test';
import { devcontainerConfig, templateById, templates } from '../lib/templates.js';

test('offers every published devcontainer image', () => {
  assert.deepEqual(templates.map((template) => template.id), [
    'ai-devbox',
    'ai-hermes-devbox',
    'ai-openhands-devbox',
  ]);
  for (const template of templates) {
    assert.match(template.image, /^ghcr\.io\/wesleycamargo\/devcontainer-template\/.+-image:latest$/);
  }
});

test('builds a minimal valid image-based devcontainer configuration', () => {
  const template = templateById('ai-hermes-devbox');
  assert.deepEqual(devcontainerConfig(template), {
    name: 'AI Hermes Devbox',
    image: 'ghcr.io/wesleycamargo/devcontainer-template/ai-hermes-devbox-image:latest',
  });
  assert.throws(() => devcontainerConfig(), /known devcontainer image/);
});
