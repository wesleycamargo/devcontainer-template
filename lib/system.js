import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

export const supportedLinuxIds = new Set(['debian', 'ubuntu']);

export function classifyPlatform(platform) {
  if (platform === 'win32') return 'windows';
  if (platform === 'linux') return 'linux';
  return 'unsupported';
}

export function parseOsRelease(content) {
  const values = {};
  for (const line of content.split(/\r?\n/)) {
    const match = line.match(/^([A-Z_]+)=(.*)$/);
    if (match) values[match[1]] = match[2].replace(/^['"]|['"]$/g, '');
  }
  return values;
}

export function linuxInstallPlan(osRelease) {
  const platform = parseOsRelease(osRelease);
  if (!supportedLinuxIds.has(platform.ID)) {
    return {
      supported: false,
      reason: `Automatic Docker installation supports Debian and Ubuntu; detected ${platform.PRETTY_NAME || platform.ID || 'an unknown distribution'}.`,
    };
  }

  return {
    supported: true,
    packageManager: 'apt',
    commands: [
      ['sudo', ['apt-get', 'update']],
      ['sudo', ['apt-get', 'install', '--yes', 'docker.io']],
      ['sudo', ['usermod', '-aG', 'docker', '<user>']],
    ],
  };
}

export async function commandExists(command, runner) {
  try {
    return (await runner(command, ['--version'], { quiet: true })).code === 0;
  } catch {
    return false;
  }
}

export async function readOsRelease(read = readFile) {
  return read('/etc/os-release', 'utf8');
}

export async function existingFile(path) {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

export function configPath(targetDirectory) {
  return join(resolve(targetDirectory), '.devcontainer', 'devcontainer.json');
}

export async function writeConfig(targetDirectory, config, { overwrite = false } = {}) {
  const path = configPath(targetDirectory);
  if (!overwrite && await existingFile(path)) {
    return { written: false, path, reason: 'exists' };
  }
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(config, null, 2)}\n`, 'utf8');
  return { written: true, path };
}
