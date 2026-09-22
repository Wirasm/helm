import { describe, expect, test } from 'bun:test';
import { prepare, probe, ready } from './ci.ts';

const head = 'a'.repeat(40);
const url = 'https://github.com/example/repo/pull/1';
function fake(
  options: {
    buckets?: string[];
    changedHead?: boolean;
    dirty?: boolean;
    refuseReady?: boolean;
    readFailure?: boolean;
  } = {}
) {
  const calls: string[][] = [];
  let draft = true;
  const run = (args: string[]) => {
    calls.push(args);
    if (options.readFailure) throw new Error('GitHub unavailable');
    if (args[0] === 'git') return args[1] === 'status' ? (options.dirty ? ' M file.ts' : '') : head;
    if (args[2] === 'ready') {
      if (!options.refuseReady) draft = false;
      return '';
    }
    const buckets = options.buckets ?? ['pass'];
    if (args.includes('statusCheckRollup')) return String(buckets.length);
    if (args[2] === 'checks')
      return JSON.stringify(buckets.map((bucket, i) => ({ name: `check-${i}`, bucket })));
    return JSON.stringify({
      headRefOid: options.changedHead ? 'b'.repeat(40) : head,
      state: 'OPEN',
      isDraft: draft,
    });
  };
  return { run, promoted: () => calls.some(args => args[2] === 'ready') };
}

describe('quick delivery only promotes the reviewed revision with observed green CI', () => {
  test('green CI is re-read, the PR is made ready, and the mutation is verified', () => {
    const api = fake({ buckets: ['pass', 'skipping'] });
    expect(ready(api.run, url, head).delivered).toBe(true);
    expect(api.promoted()).toBe(true);
  });
  for (const buckets of [['pending'], ['fail'], ['cancel'], ['unknown'], []]) {
    test(`does not promote checks ${JSON.stringify(buckets)}`, () => {
      const api = fake({ buckets });
      expect(() => ready(api.run, url, head)).toThrow('PR readiness refused');
      expect(api.promoted()).toBe(false);
    });
  }
  test('no registered CI remains pending, never silently green', () => {
    expect(probe(fake({ buckets: [] }).run, url, head).state).toBe('pending');
  });
  for (const option of [{ changedHead: true }, { dirty: true }, { readFailure: true }]) {
    test(`does not promote when evidence is invalid: ${JSON.stringify(option)}`, () => {
      const api = fake(option);
      expect(() => ready(api.run, url, head)).toThrow();
      expect(api.promoted()).toBe(false);
    });
  }
  test('does not report delivery when GitHub leaves the PR draft', () => {
    expect(() => ready(fake({ refuseReady: true }).run, url, head)).toThrow('did not confirm');
  });
  test('malformed check payload cannot be treated as green', () => {
    const api = fake();
    expect(() => probe(args => (args[2] === 'checks' ? '{}' : api.run(args)), url, head)).toThrow(
      'check states'
    );
  });
});

describe('publication target is checked before the PR component can push', () => {
  function publication(existing: unknown) {
    const calls: string[][] = [];
    const run = (args: string[]) => {
      calls.push(args);
      if (args[0] === 'git')
        return args[1] === 'branch' ? 'fix/example' : 'git@github.com:owner/fork.git';
      return JSON.stringify(existing);
    };
    return { run, calls };
  }
  for (const existing of [[], [{ url, isDraft: true }]]) {
    test(`allows a new or draft PR: ${JSON.stringify(existing)}`, () => {
      const api = publication(existing);
      expect(prepare(api.run)).toEqual({ repository: 'owner/fork', branch: 'fix/example' });
      expect(api.calls.at(-1)).toEqual([
        'gh',
        'pr',
        'list',
        '--repo',
        'owner/fork',
        '--head',
        'fix/example',
        '--state',
        'open',
        '--json',
        'url,isDraft',
      ]);
    });
  }
  test('refuses an existing ready PR instead of implicitly changing its state', () => {
    const api = publication([{ url, isDraft: false }]);
    expect(() => prepare(api.run)).toThrow('will not push into an existing ready PR');
    expect(api.calls.some(args => args.includes('push') || args.includes('ready'))).toBe(false);
  });
  test('missing draft-state evidence refuses publication', () => {
    expect(() => prepare(publication([{ url }]).run)).toThrow('draft state');
  });
});
