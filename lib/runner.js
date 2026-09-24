import { spawn } from 'node:child_process';

export function runCommand(command, args, { input, quiet = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: quiet
        ? ['ignore', 'ignore', 'ignore']
        : input === undefined
          ? 'inherit'
          : ['pipe', 'inherit', 'inherit'],
    });
    child.once('error', reject);
    child.once('close', (code) => resolve({ code: code ?? 1 }));
    if (input !== undefined) child.stdin.end(input);
  });
}

export function captureCommand(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'inherit'] });
    let stdout = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.once('error', reject);
    child.once('close', (code) => resolve({ code: code ?? 1, stdout }));
  });
}
