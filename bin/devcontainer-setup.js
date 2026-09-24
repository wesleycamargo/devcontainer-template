#!/usr/bin/env node

import { run } from '../lib/cli.js';

run().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
