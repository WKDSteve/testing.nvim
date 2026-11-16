// A native messaging host: one framed message in (4-byte length, little endian, then JSON), { pong } out: the value
// of SHEET_HOST_SAYS from the environment Chromium started it with, else "host".
const chunks = [];
process.stdin.on('data', (d) => {
  chunks.push(d);
  const buf = Buffer.concat(chunks);
  if (buf.length < 4 || buf.length < 4 + buf.readUInt32LE(0)) return;
  const out = Buffer.from(JSON.stringify({ pong: process.env.SHEET_HOST_SAYS || 'host' }));
  const len = Buffer.alloc(4);
  len.writeUInt32LE(out.length);
  process.stdout.write(Buffer.concat([len, out]), () => process.exit(0));
});
