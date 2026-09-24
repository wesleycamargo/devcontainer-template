import { userInfo } from 'node:os';
import { resolve } from 'node:path';
import * as p from '@clack/prompts';
import { captureCommand, runCommand } from './runner.js';
import {
  classifyPlatform,
  commandExists,
  configPath,
  existingFile,
  linuxInstallPlan,
  readOsRelease,
  writeConfig,
} from './system.js';
import { devcontainerConfig, templates } from './templates.js';

function cancelled(value) {
  return p.isCancel(value);
}

async function confirm(prompts, options) {
  const answer = await prompts.confirm(options);
  if (cancelled(answer)) {
    prompts.cancel('Setup cancelled.');
    return undefined;
  }
  return answer;
}

async function chooseTasks(prompts, host) {
  const selected = await prompts.multiselect({
    message: 'Choose what to set up',
    options: [
      {
        value: 'docker',
        label: 'Docker Engine',
        hint: host === 'windows'
          ? 'installed inside the selected WSL distribution; skipped automatically if already present'
          : 'installed on this Linux host; skipped automatically if already present',
      },
      {
        value: 'devcontainer',
        label: 'Dev Container CLI',
        hint: '@devcontainers/cli; skipped automatically if already present',
      },
      {
        value: 'ghcr',
        label: 'GitHub Container Registry sign-in',
        hint: 'needed to pull the private Devbox images; requires the GitHub CLI (gh)',
      },
      {
        value: 'configuration',
        label: 'Devcontainer configuration',
        hint: 'choose an image and write .devcontainer/devcontainer.json',
      },
    ],
    initialValues: ['docker', 'devcontainer', 'ghcr', 'configuration'],
    required: true,
  });
  if (cancelled(selected)) {
    prompts.cancel('Setup cancelled.');
    return undefined;
  }
  return new Set(selected);
}

async function installDevcontainerCli(runner, prompts) {
  if (await runner('devcontainer', ['--version'], { quiet: true }).then((result) => result.code === 0).catch(() => false)) {
    return true;
  }

  prompts.log.step('Installing @devcontainers/cli…');
  const result = await runner('npm', ['install', '--global', '@devcontainers/cli']);
  return result.code === 0;
}

async function setupLinux({ runner, prompts, readRelease, username, tasks }) {
  const wantsDocker = tasks.has('docker');
  const wantsDevcontainer = tasks.has('devcontainer');
  const dockerInstalled = wantsDocker && await commandExists('docker', runner);
  const devcontainerInstalled = wantsDevcontainer && await commandExists('devcontainer', runner);

  if (wantsDocker) {
    if (dockerInstalled) {
      prompts.log.success('Docker Engine is already installed.');
    } else {
      const installDocker = await confirm(prompts, {
        message: 'Docker Engine is not installed. Install it now?',
        initialValue: true,
      });
      if (installDocker === undefined) return false;
      if (installDocker) {
        const plan = linuxInstallPlan(await readRelease());
        if (!plan.supported) {
          prompts.log.warn(plan.reason);
          prompts.log.info('Install Docker Engine manually, then re-run this command.');
        } else {
          prompts.log.info('Your password may be requested by sudo.');
          for (const [command, arguments_] of plan.commands) {
            const args = arguments_.map((value) => value === '<user>' ? username : value);
            if ((await runner(command, args)).code !== 0) {
              prompts.log.error('Docker installation did not complete. Resolve the error above and run the command again.');
              break;
            }
          }
          await runner('sudo', ['service', 'docker', 'start']);
        }
      }
    }
  }

  if (wantsDevcontainer) {
    if (devcontainerInstalled) {
      prompts.log.success('The Dev Container CLI is already installed.');
    } else {
      const installCli = await confirm(prompts, {
        message: 'The Dev Container CLI is not installed. Install it now?',
        initialValue: true,
      });
      if (installCli === undefined) return false;
      if (installCli && !(await installDevcontainerCli(runner, prompts))) {
        prompts.log.warn('The Dev Container CLI installation did not complete. You may need to configure npm global permissions.');
      }
    }
  }

  if (wantsDocker) {
    const dockerReady = await commandExists('docker', runner);
    if (!dockerReady) prompts.log.warn('Docker is not yet available. Complete its installation before opening the devcontainer.');
    if (dockerReady && (await runner('docker', ['info'], { quiet: true })).code !== 0) {
      prompts.log.warn('Docker is installed but its daemon is not ready. Start Docker, then re-run this command.');
    }
    if (!dockerInstalled && dockerReady) prompts.log.info('Open a new shell before using Docker so the docker group membership takes effect.');
  }
  if (wantsDevcontainer && !await commandExists('devcontainer', runner)) {
    prompts.log.warn('The devcontainer command is not yet available. Complete its installation before continuing.');
  }
  return true;
}

async function wslCommandExists(distro, command, runner) {
  try {
    return (await runner('wsl', ['-d', distro, '--', 'bash', '-lc', `command -v ${command}`], { quiet: true })).code === 0;
  } catch {
    return false;
  }
}

async function setupWindows({ runner, capture, prompts, tasks }) {
  const wantsDocker = tasks.has('docker');
  const wantsDevcontainer = tasks.has('devcontainer');
  if (!wantsDocker && !wantsDevcontainer && !tasks.has('ghcr')) return {};
  let distributions;
  try {
    const result = await capture('wsl', ['-l', '-q']);
    distributions = result.code === 0
      ? result.stdout.split(/\r?\n/).map((item) => item.replace(/\0/g, '').trim()).filter(Boolean)
      : [];
  } catch {
    distributions = [];
  }

  if (distributions.length === 0) {
    const installWsl = await confirm(prompts, {
      message: 'No WSL distribution was found. Install Ubuntu with WSL now?',
      initialValue: true,
    });
    if (installWsl === undefined) return false;
    if (installWsl) await runner('wsl', ['--install', '-d', 'Ubuntu']);
    prompts.log.info('Finish the WSL installation (and reboot if Windows requests it), then run this command again from Windows.');
    return false;
  }

  const distro = await prompts.select({
    message: 'Which WSL distribution should run Docker?',
    options: distributions.map((value) => ({ value, label: value })),
  });
  if (cancelled(distro)) {
    prompts.cancel('Setup cancelled. No files were changed.');
    return false;
  }

  const dockerInstalled = wantsDocker && await wslCommandExists(distro, 'docker', runner);
  const devcontainerInstalled = wantsDevcontainer && await wslCommandExists(distro, 'devcontainer', runner);
  if (wantsDocker && dockerInstalled) prompts.log.success(`Docker Engine is already installed in ${distro}.`);
  if (wantsDevcontainer && devcontainerInstalled) prompts.log.success(`The Dev Container CLI is already installed in ${distro}.`);
  if ((wantsDocker && !dockerInstalled) || (wantsDevcontainer && !devcontainerInstalled)) {
    const install = await confirm(prompts, {
      message: `Install the selected missing tools inside WSL (${distro}) now?`,
      initialValue: true,
    });
    if (install === undefined) return false;
    if (install) {
      const dockerSetup = wantsDocker ? `
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install --yes docker.io
  sudo usermod -aG docker "$USER"
fi
if command -v service >/dev/null 2>&1; then
  sudo service docker start || true
fi` : '';
      const devcontainerSetup = wantsDevcontainer ? `
if ! command -v devcontainer >/dev/null 2>&1; then
  sudo npm install --global @devcontainers/cli
fi` : '';
      const script = `
set -eu
. /etc/os-release
case "$ID" in
  debian|ubuntu) ;;
  *) echo "Automatic setup supports Debian and Ubuntu; detected $ID." >&2; exit 2 ;;
esac
${dockerSetup}
${devcontainerSetup}
`;
      prompts.log.info('Your WSL sudo password may be requested. Docker Desktop is not used.');
      const result = await runner('wsl', ['-d', distro, '--', 'bash', '-lc', script]);
      if (result.code !== 0) prompts.log.warn('WSL setup did not complete. Resolve the error above and run the command again.');
    }
  }

  if (wantsDocker) {
    const dockerReady = await wslCommandExists(distro, 'docker', runner);
    if (!dockerReady) prompts.log.warn(`Docker is not yet available in ${distro}.`);
    if (dockerReady && (await runner('wsl', ['-d', distro, '--', 'docker', 'info'], { quiet: true })).code !== 0) {
      prompts.log.warn(`Docker is installed in ${distro}, but its daemon is not ready. Start it with \`sudo service docker start\`, then re-run this command.`);
    }
  }
  if (wantsDevcontainer && !await wslCommandExists(distro, 'devcontainer', runner)) {
    prompts.log.warn(`The devcontainer command is not yet available in ${distro}.`);
  }
  if (wantsDocker || wantsDevcontainer) {
    prompts.log.info(`Open your project from ${distro}; Docker and the devcontainer CLI run inside WSL, never Docker Desktop.`);
  }
  return { distro };
}

async function signInToGhcr({ host, distro, runner, capture, prompts }) {
  if (!await commandExists('gh', runner)) {
    prompts.log.warn('GitHub CLI is not installed, so GHCR login was skipped. Install gh and log in with read:packages before pulling these private images.');
    return;
  }
  prompts.log.success('GitHub CLI is already installed.');
  const wantsLogin = await confirm(prompts, {
    message: 'Sign in to GHCR now so Docker can pull the private images?',
    initialValue: true,
  });
  if (!wantsLogin) return;

  let token = await capture('gh', ['auth', 'token']);
  if (token.code !== 0) {
    await runner('gh', ['auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web', '--scopes', 'read:packages']);
    token = await capture('gh', ['auth', 'token']);
  }
  const account = await capture('gh', ['api', 'user', '-q', '.login']);
  if (token.code !== 0 || account.code !== 0 || !account.stdout.trim()) {
    prompts.log.warn('GitHub authentication did not complete; GHCR login was skipped.');
    return;
  }
  const args = host === 'windows'
    ? ['-d', distro, '--', 'docker', 'login', 'ghcr.io', '-u', account.stdout.trim(), '--password-stdin']
    : ['login', 'ghcr.io', '-u', account.stdout.trim(), '--password-stdin'];
  const result = await runner(host === 'windows' ? 'wsl' : 'docker', args, { input: token.stdout });
  if (result.code === 0) prompts.log.success('Signed Docker in to ghcr.io.');
  else prompts.log.warn('Docker login to ghcr.io failed. Run it manually after resolving the error above.');
}

export async function run({
  platform = process.platform,
  cwd = process.cwd(),
  runner = runCommand,
  capture = captureCommand,
  prompts = p,
  readRelease = readOsRelease,
  username = userInfo().username,
} = {}) {
  prompts.intro('AI Devbox devcontainer setup');
  const host = classifyPlatform(platform);
  if (host === 'unsupported') {
    prompts.log.error('This setup tool currently supports Linux and Windows with WSL only.');
    prompts.outro('No changes were made.');
    return;
  }

  const tasks = await chooseTasks(prompts, host);
  if (!tasks) return;

  const setup = host === 'windows'
    ? await setupWindows({ runner, capture, prompts, tasks })
    : await setupLinux({ runner, prompts, readRelease, username, tasks });
  if (!setup) return;

  if (!tasks.has('configuration')) {
    if (tasks.has('ghcr')) await signInToGhcr({ host, distro: setup.distro, runner, capture, prompts });
    prompts.outro('Selected setup tasks completed.');
    return;
  }

  const selectedId = await prompts.select({
    message: 'Choose the devcontainer image to use',
    options: templates.map((template) => ({ value: template.id, label: template.label, hint: template.hint })),
  });
  if (cancelled(selectedId)) {
    prompts.cancel('Setup cancelled. No files were changed.');
    return;
  }
  const template = templates.find((item) => item.id === selectedId);
  const target = await prompts.text({
    message: 'Project directory for the devcontainer configuration',
    initialValue: cwd,
    validate: (value) => value.trim() ? undefined : 'Enter a project directory.',
  });
  if (cancelled(target)) {
    prompts.cancel('Setup cancelled. No files were changed.');
    return;
  }

  const path = configPath(target);
  const overwrite = await existingFile(path)
    ? await confirm(prompts, { message: `${path} already exists. Replace it?`, initialValue: false })
    : true;
  if (overwrite === undefined || !overwrite) {
    prompts.outro('Existing configuration was left unchanged.');
    return;
  }

  const result = await writeConfig(resolve(target), devcontainerConfig(template), { overwrite: true });
  if (tasks.has('ghcr')) await signInToGhcr({ host, distro: setup.distro, runner, capture, prompts });
  prompts.outro(`Wrote ${result.path}. Open the project in VS Code and choose “Dev Containers: Reopen in Container”.`);
}
