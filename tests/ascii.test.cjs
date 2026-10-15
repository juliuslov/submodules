const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { deflateSync } = require('node:zlib');
const { imageToAscii } = require('../dist/index.cjs');
function fixture(t, bytes = Buffer.from('P6\n2 1\n255\n\0\0\0\xff\xff\xff', 'latin1')) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wiz-ascii-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'image with spaces.ppm'); fs.writeFileSync(file, bytes); return file;
}
function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type), data]); let crc = 0xffffffff;
  for (const byte of body) { crc ^= byte; for (let i=0; i<8; i++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0); }
  const prefix=Buffer.alloc(4), suffix=Buffer.alloc(4);
  prefix.writeUInt32BE(data.length); suffix.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([prefix, body, suffix]);
}
test('Rust ASCII bridge renders black and white, with preserved whitespace', async t => {
  const result = await imageToAscii(fixture(t), { width: 2, height: 1, ramp: '@ ' });
  assert.deepEqual(result, { text: '@ \n', columns: 2, rows: 1 });
});
test('inversion and custom dimensions', async t => {
  assert.equal((await imageToAscii(fixture(t), { width:2, height:1, ramp:'@ ', invert:true })).text, ' @\n');
});
test('PNG alpha composited onto configurable background', async t => {
  const header=Buffer.alloc(13); header.writeUInt32BE(1,0); header.writeUInt32BE(1,4); header[8]=8; header[9]=6;
  const png=Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header),chunk('IDAT',deflateSync(Buffer.from([0,0,0,0,0]))),chunk('IEND',Buffer.alloc(0))]);
  const file=fixture(t,png);
  assert.equal((await imageToAscii(file,{width:1,height:1,ramp:'@ '})).text, ' \n');
  assert.equal((await imageToAscii(file,{width:1,height:1,ramp:'@ ',background:'black'})).text, '@\n');
});
test('reject invalid options, corrupt images and missing files', async t => {
  const file=fixture(t);
  for (const options of [{width:0},{width:401},{height:201},{invert:1},{ramp:'\x1b '},{ramp:'x'},{background:'blue'},[]]) {
    await assert.rejects(imageToAscii(file,options));
  }
  await assert.rejects(imageToAscii(fixture(t,Buffer.from('bad'))),/ASCII conversion failed/);
  await assert.rejects(imageToAscii('/nonexistent/image'),/cannot open image/);
});
test('ASCII JSON RPC dispatch and standalone CLI', t => {
  const file=fixture(t);
  const direct=spawnSync(path.resolve('build/wiz-ascii'),[file,'--width','2','--height','1','--ramp','@ '],{encoding:'utf8'});
  assert.equal(direct.status,0,direct.stderr); assert.equal(direct.stdout,'@ \n');
  const rpc=spawnSync(process.execPath,[path.resolve('dist/cli.cjs'),'rpc'],{
    input:JSON.stringify({action:'ascii',path:file,options:{width:2,height:1,ramp:'@ '}}),encoding:'utf8',
  });
  assert.equal(rpc.status,0,rpc.stderr); assert.equal(JSON.parse(rpc.stdout).data.text,'@ \n');
});
