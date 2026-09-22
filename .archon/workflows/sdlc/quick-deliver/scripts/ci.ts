type Run = (args: string[]) => string;
interface Check {
  name: string;
  bucket: string;
}
interface PullRequest {
  headRefOid: string;
  state: string;
  isDraft: boolean;
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function readPr(run: Run, url: string, head: string): PullRequest {
  const value: unknown = JSON.parse(
    run(['gh', 'pr', 'view', url, '--json', 'headRefOid,state,isDraft'])
  );
  if (
    !record(value) ||
    value.headRefOid !== head ||
    value.state !== 'OPEN' ||
    typeof value.isDraft !== 'boolean'
  ) {
    throw new Error('The PR must be open at the independently reviewed revision.');
  }
  return { headRefOid: head, state: value.state, isDraft: value.isDraft };
}

export function probe(
  run: Run,
  url: string,
  head: string
): { state: 'pending' | 'green' | 'red'; detail: string } {
  readPr(run, url, head);
  const value: unknown = JSON.parse(
    run([
      'gh',
      'pr',
      'view',
      url,
      '--json',
      'statusCheckRollup',
      '--jq',
      '.statusCheckRollup | length',
    ])
  );
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0)
    throw new Error('Could not read the PR check count.');
  if (value === 0)
    return {
      state: 'pending',
      detail: 'No checks registered yet; quick delivery requires observed CI.',
    };
  const checks: unknown = JSON.parse(run(['gh', 'pr', 'checks', url, '--json', 'name,bucket']));
  if (
    !Array.isArray(checks) ||
    checks.length === 0 ||
    !checks.every(
      (v: unknown): v is Check =>
        record(v) && typeof v.name === 'string' && typeof v.bucket === 'string'
    )
  ) {
    throw new Error('Could not read the PR check states.');
  }
  const red = checks.filter(c => !['pass', 'skipping', 'pending'].includes(c.bucket));
  if (red.length)
    return { state: 'red', detail: red.map(c => `${c.name}: ${c.bucket}`).join(', ') };
  if (checks.some(c => c.bucket === 'pending'))
    return { state: 'pending', detail: 'CI is still running.' };
  return { state: 'green', detail: checks.map(c => `${c.name}: ${c.bucket}`).join(', ') };
}

export function ready(run: Run, url: string, head: string) {
  if (
    run(['git', 'rev-parse', 'HEAD']).trim() !== head ||
    run(['git', 'status', '--porcelain']).trim() !== ''
  ) {
    throw new Error('The checkout changed after independent review.');
  }
  const checks = probe(run, url, head);
  if (checks.state !== 'green') throw new Error(`PR remains draft: ${checks.detail}`);
  run(['gh', 'pr', 'ready', url]);
  if (readPr(run, url, head).isDraft)
    throw new Error('GitHub did not confirm that the PR is ready.');
  return {
    delivered: true,
    pr_url: url,
    head,
    summary: `Independently reviewed; CI accepted (${checks.detail}). Not merged.`,
  };
}

if (import.meta.main) {
  const action = process.env.INPUTS_ACTION;
  const url = process.env.INPUTS_PR_URL ?? '';
  const head = process.env.INPUTS_HEAD ?? '';
  const run: Run = args => {
    const result = Bun.spawnSync(args, { stdout: 'pipe', stderr: 'pipe' });
    // gh checks encodes failed/pending checks in its exit status; inspect its JSON.
    const checkStatus =
      args[0] === 'gh' &&
      args[1] === 'pr' &&
      args[2] === 'checks' &&
      [1, 8].includes(result.exitCode);
    if (result.exitCode !== 0 && !checkStatus)
      throw new Error(result.stderr.toString().trim() || `${args[0]} exited ${result.exitCode}`);
    return result.stdout.toString();
  };
  try {
    if (!url || !head) throw new Error('A recorded PR URL and reviewed revision are required.');
    if (action !== 'probe' && action !== 'ready') throw new Error('Unknown CI action.');
    console.log(JSON.stringify(action === 'probe' ? probe(run, url, head) : ready(run, url, head)));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
