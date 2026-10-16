const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { spawn } = require('node:child_process');
const { KoSyncClient, partialMd5, filenameMd5, documentChecksum } = require('../dist/index.cjs');
const secret = 'top secret 密碼';
const key = createHash('md5').update(secret).digest('hex');
const config = { username:'test_reader', password:secret, allowInsecureLocal:true };
const update = { document:'abc123', progress:'/body/DocFragment[2]/body/p[5].0', percentage:0.5, device:'Neovim', device_id:'test-device' };
async function server(t, handler) {
  const srv=http.createServer(async (req,res) => {
    let text=''; for await (const chunk of req) text+=chunk;
    try { await handler(req,res,text ? JSON.parse(text) : undefined); }
    catch (err) { res.statusCode=500; res.end(JSON.stringify({testError:err.message})); }
  });
  await new Promise(resolve=>srv.listen(0,'127.0.0.1',resolve));
  t.after(()=>{ srv.closeAllConnections(); return new Promise(resolve=>srv.close(resolve)); });
  return `http://127.0.0.1:${srv.address().port}`;
}
const send=(res,body,status=200)=>{ res.writeHead(status,{'content-type':'application/json'}); res.end(JSON.stringify(body)); };

test('KoSync uses upstream methods, media type, MD5 key and reverse-proxy prefix', async t=>{
  const seen=[];
  const url=await server(t,(req,res,body)=>{
    seen.push(req.url);
    assert.equal(req.headers.accept,'application/vnd.koreader.v1+json');
    if(req.url==='/prefix/users/create') {
      assert.equal(req.method,'POST'); assert.deepEqual(body,{username:config.username,password:key});
      send(res,{username:config.username},201);
    } else {
      assert.equal(req.headers['x-auth-user'],config.username); assert.equal(req.headers['x-auth-key'],key);
      if(req.url==='/prefix/users/auth') { assert.equal(req.method,'GET'); send(res,{authorized:'OK'}); }
      else if(req.url==='/prefix/syncs/progress' && req.method==='PUT') { assert.deepEqual(body,update); send(res,{document:update.document,timestamp:123}); }
      else if(req.url==='/prefix/syncs/progress/abc123') { assert.equal(req.method,'GET'); send(res,{...update,timestamp:123}); }
      else send(res,{},404);
    }
  });
  const client=new KoSyncClient({...config,baseUrl:url+'/prefix/'});
  assert.deepEqual(await client.register(),{username:config.username});
  assert.deepEqual(await client.authorize(),{authorized:true});
  assert.deepEqual(await client.push(update),{document:'abc123',timestamp:123,accepted:false});
  assert.deepEqual(await client.pull('abc123'),{found:true,...update,timestamp:123});
  assert.equal(seen.length,4);
});

test('prehashed key is not hashed twice and no secrets enumerate on client', async t=>{
  const url=await server(t,(req,res)=>{ assert.equal(req.headers['x-auth-key'],key); send(res,{authorized:'OK'}); });
  const client=new KoSyncClient({username:config.username,userkey:key.toUpperCase(),baseUrl:url,allowInsecureLocal:true});
  assert.deepEqual(await client.authorize(),{authorized:true});
  assert.equal(JSON.stringify(client),'{}');
});

test('empty progress is not found; 202 reflects queued acceptance', async t=>{
  const url=await server(t,(req,res)=> req.method==='PUT' ? send(res,{},202) : send(res,{}));
  const client=new KoSyncClient({...config,baseUrl:url});
  assert.deepEqual(await client.pull('abc123'),{found:false,document:'abc123'});
  assert.deepEqual(await client.push(update),{document:'abc123',accepted:true});
});

test('reject bad credentials, URLs, insecure endpoints, timeout settings', ()=>{
  for(const options of [
    {...config,username:'x:y'}, {...config,username:'bad\nheader'}, {...config,password:undefined}, {...config,userkey:key},
    {...config,password:undefined,userkey:'not a hash'}, {...config,baseUrl:'http://example.com',allowInsecureLocal:true},
    {...config,baseUrl:'http://127.0.0.1',allowInsecureLocal:false}, {...config,baseUrl:'https://user:password@example.com'},
    {...config,baseUrl:'https://example.com?key=secret'}, {...config,baseUrl:'https://example.com#secret'},
    {...config,baseUrl:'file:///tmp/foo'}, {...config,timeoutMs:0},
  ]) assert.throws(()=>new KoSyncClient(options));
});

test('reject path-injection document IDs and invalid progress before sending', async t=>{
  let calls=0;
  const url=await server(t,(_req,res)=>{ calls++; send(res,{}); });
  const client=new KoSyncClient({...config,baseUrl:url});
  for(const doc of ['../x','a/b','a%2fb','a:b','a?x','']) await assert.rejects(client.pull(doc));
  for(const value of [-1,1.1,Infinity,NaN,'0.5']) await assert.rejects(client.push({...update,percentage:value}));
  for(const data of [null,{}, {...update,device_id:''},{...update,progress:7}]) await assert.rejects(client.push(data));
  assert.equal(calls,0);
});

test('HTTP errors do not reflect passwords, keys or remote bodies', async t=>{
  const url=await server(t,(_req,res)=>send(res,{error:`${secret} ${key}`},401));
  await assert.rejects(new KoSyncClient({...config,baseUrl:url}).authorize(),err=>{
    assert.match(err.message,/401/); assert.ok(!err.message.includes(secret) && !err.message.includes(key)); return true;
  });
});

test('redirects do not forward credentials or trigger another request', async t=>{
  let leaked=false;
  const target=await server(t,(_req,res)=>{leaked=true;send(res,{authorized:'OK'});});
  const url=await server(t,(_req,res)=>{res.writeHead(302,{location:target+'/users/auth'});res.end();});
  await assert.rejects(new KoSyncClient({...config,baseUrl:url}).authorize(),/302/);
  assert.equal(leaked,false);
});

test('reject malformed, excessive, mismatched and invalid remote JSON', async t=>{
  let mode='json';
  const url=await server(t,(_req,res)=>{
    if(mode==='json') res.end('not JSON');
    if(mode==='large') res.end('x'.repeat(128*1024+1));
    if(mode==='chunked') {res.write(' '.repeat(80000));res.end(' '.repeat(80000));}
    if(mode==='mismatch') send(res,{...update,document:'other'});
    if(mode==='range') send(res,{...update,percentage:2});
    if(mode==='timestamp') send(res,{...update,timestamp:-1});
  });
  const client=new KoSyncClient({...config,baseUrl:url});
  for(const value of ['json','large','chunked','mismatch','range','timestamp']) {mode=value;await assert.rejects(client.pull('abc123'));}
});

test('deadline covers response headers and streaming body', async t=>{
  let headers=false;
  const url=await server(t,async (_req,res)=>{
    if(headers) {res.writeHead(200,{'content-type':'application/json'});res.write('{');}
    await new Promise(resolve=>setTimeout(resolve,150));res.end('{}');
  });
  const client=new KoSyncClient({...config,baseUrl:url,timeoutMs:50});
  await assert.rejects(client.authorize(),/timed out/);
  headers=true; await assert.rejects(client.authorize(),/timed out/);
});

test('KOReader partial checksum offsets match independent implementation', t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'wiz-checksum-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const file=path.join(dir,'book.epub');
  const bytes=Buffer.alloc(20000);for(let i=0;i<bytes.length;i++)bytes[i]=(i*37+(i>>8))%256;
  fs.writeFileSync(file,bytes);
  const samples=[0,1024,4096,16384].map(offset=>bytes.subarray(offset,offset+1024));
  const expected=createHash('md5').update(Buffer.concat(samples)).digest('hex');
  assert.equal(partialMd5(file),expected);assert.equal(documentChecksum(file),expected);
  assert.notEqual(expected,createHash('md5').update(bytes).digest('hex'));
  assert.equal(documentChecksum(file,'filename'),createHash('md5').update('book.epub').digest('hex'));
  assert.equal(filenameMd5('Sách.epub'),createHash('md5').update('Sách.epub').digest('hex'));
  assert.throws(()=>filenameMd5('folder/book.epub'));
  assert.throws(()=>partialMd5(dir));
  fs.writeFileSync(file,'short');assert.equal(partialMd5(file),createHash('md5').update('short').digest('hex'));
});

function rpc(payload,environment) {
  return new Promise((resolve,reject)=>{
    const child=spawn(process.execPath,[path.resolve('dist/cli.cjs'),'rpc'],{
      env:{...process.env,KOSYNC_USERNAME:'test_reader',KOSYNC_PASSWORD:secret,KOSYNC_USERKEY:'',...environment},
    });
    let stdout='',stderr='';child.stdout.on('data',data=>stdout+=data);child.stderr.on('data',data=>stderr+=data);
    child.on('error',reject);child.on('close',code=>resolve({code,stdout,stderr}));child.stdin.end(JSON.stringify(payload));
  });
}
test('KoSync RPC gets credentials from env and returns normalized progress', async t=>{
  const url=await server(t,(_req,res)=>send(res,{...update,timestamp:123}));
  const result=await rpc({action:'kosync',sync:{operation:'pull',document:'abc123'}},{KOSYNC_URL:url,KOSYNC_ALLOW_INSECURE_LOCAL:'1',KOSYNC_USERKEY:undefined});
  assert.equal(result.code,0,result.stderr);
  assert.equal(JSON.parse(result.stdout).data.progress,update.progress);
  assert.ok(!result.stdout.includes(secret) && !result.stdout.includes(key));
});

test('doctor never contacts server or exposes KoSync secrets', async t=>{
  let calls=0;
  const url=await server(t,(_req,res)=>{calls++;send(res,{});});
  const result=await rpc({action:'doctor'},{KOSYNC_URL:url,KOSYNC_USERKEY:undefined});
  assert.equal(result.code,0,result.stderr);
  assert.deepEqual(JSON.parse(result.stdout).data.kosync,{available:true,configured:true,onlineCheck:false});
  assert.equal(calls,0); assert.ok(!result.stdout.includes(secret) && !result.stdout.includes(key));
});

test('empty array response represents no progress', async t=>{
  const url=await server(t,(_req,res)=>send(res,[]));
  assert.deepEqual(await new KoSyncClient({...config,baseUrl:url}).pull('abc123'),{found:false,document:'abc123'});
});
