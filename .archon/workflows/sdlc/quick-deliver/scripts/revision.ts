export {};

const checkoutStatus = Bun.spawnSync(['git', 'status', '--porcelain'], {
  stdout: 'pipe',
  stderr: 'pipe',
});
const head = Bun.spawnSync(['git', 'rev-parse', 'HEAD'], { stdout: 'pipe', stderr: 'pipe' });
if (
  checkoutStatus.exitCode !== 0 ||
  head.exitCode !== 0 ||
  checkoutStatus.stdout.toString().trim() !== ''
) {
  console.error('Quick delivery requires a clean, committed revision before independent review.');
  process.exitCode = 1;
} else {
  console.log(JSON.stringify({ head: head.stdout.toString().trim() }));
}
