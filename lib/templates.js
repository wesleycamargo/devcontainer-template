const registry = 'ghcr.io/wesleycamargo/devcontainer-template';

export const templates = [
  {
    id: 'ai-devbox',
    label: 'AI Devbox',
    hint: 'PowerShell, Claude Code, Codex, Azure Bicep, Node.js, and embedded SDLC skills.',
    image: `${registry}/ai-devbox-image:latest`,
  },
  {
    id: 'ai-hermes-devbox',
    label: 'AI Hermes Devbox',
    hint: 'AI Devbox plus Hermes Agent and its SSH gateway.',
    image: `${registry}/ai-hermes-devbox-image:latest`,
  },
  {
    id: 'ai-openhands-devbox',
    label: 'AI OpenHands Devbox',
    hint: 'AI Devbox plus the OpenHands Agent Canvas companion service.',
    image: `${registry}/ai-openhands-devbox-image:latest`,
  },
];

export function templateById(id) {
  return templates.find((template) => template.id === id);
}

export function devcontainerConfig(template) {
  if (!template) {
    throw new Error('A known devcontainer image must be selected.');
  }

  return {
    name: template.label,
    image: template.image,
  };
}
