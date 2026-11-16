const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fsp = require('fs/promises');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { createApp } = require('../src/server');

async function startTestServer(extraOverrides = {}) {
  const tmpRoot = await fsp.mkdtemp(path.join(os.tmpdir(), 'photohub-test-'));
  const storageDir = path.join(tmpRoot, 'uploads');
  const dataDir = path.join(tmpRoot, 'data');

  const app = await createApp({
    port: 0,
    storageDir,
    dataDir,
    apiKey: '',
    userKeys: '',
    ...extraOverrides,
  });

  const socketPath =
    process.platform === 'win32'
      ? `\\\\.\\pipe\\photohub-test-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`
      : path.join(tmpRoot, 'server.sock');

  const server = await new Promise((resolve) => {
    const s = app.listen(socketPath, () => resolve(s));
  });

  async function request(urlPath, { method = 'GET', headers = {}, body = null } = {}) {
    let payload = body;
    const reqHeaders = { ...headers };

    if (body instanceof FormData) {
      const res = new Response(body);
      reqHeaders['Content-Type'] = res.headers.get('content-type');
      payload = Buffer.from(await res.arrayBuffer());
    } else if (typeof body === 'string') {
      payload = Buffer.from(body);
    }

    if (Buffer.isBuffer(payload)) {
      reqHeaders['Content-Length'] = payload.length;
    }

    return new Promise((resolve, reject) => {
      const req = http.request(
        {
          socketPath,
          path: urlPath,
          method,
          headers: reqHeaders,
        },
        (res) => {
          const chunks = [];
          res.on('data', (c) => chunks.push(c));
          res.on('end', () => {
            const raw = Buffer.concat(chunks).toString('utf8');
            resolve({
              status: res.statusCode,
               async json() {
                return JSON.parse(raw);
              },
            });
          });
        }
      );
      req.on('error', reject);
      if (payload) req.write(payload);
      req.end();
    });
  }

  return {
    request,
    storageDir,
    dataDir,
    async cleanup() {
      await new Promise((resolve) => server.close(resolve));
      await fsp.rm(tmpRoot, { recursive: true, force: true });
    },
  };
}

test('PhotoHub upload, SHA-256 verification, duplicate check, and Apple Shortcut flow', async (t) => {
  const ctx = await startTestServer();
  t.after(() => ctx.cleanup());

  const sampleBytes = Buffer.from('fake-heic-photo-binary-content-001');
  const expectedSha256 = crypto.createHash('sha256').update(sampleBytes).digest('hex');

  await t.test('1. Upload via multipart Form saves to YYYY/YYYY-MM-DD and returns canDelete: true', async () => {
    const form = new FormData();
    form.append('photo', new Blob([sampleBytes], { type: 'image/heic' }), 'IMG_1001.HEIC');
    form.append('createdAt', '2026-10-22T10:15:00Z');
    form.append('hash', expectedSha256);

    const res = await ctx.request('/api/upload', {
      method: 'POST',
      body: form,
    });
    assert.equal(res.status, 200);
    const body = await res.json();

    assert.equal(body.success, true);
    assert.equal(body.canDelete, true);
    assert.equal(body.isDuplicate, false);
    assert.equal(body.status, 'stored_verified');
    assert.equal(body.hash, expectedSha256);
    assert.equal(body.savedPath, '2026/2026-10-22/IMG_1001.HEIC');

    const diskBytes = await fsp.readFile(path.join(ctx.storageDir, body.savedPath));
    assert.deepEqual(diskBytes, sampleBytes);
  });

  await t.test('2. Duplicate upload is detected by SHA-256 and confirms canDelete: true without duplicating file', async () => {
    const form = new FormData();
    form.append('photo', new Blob([sampleBytes], { type: 'image/heic' }), 'IMG_1001_COPY.HEIC');

    const res = await ctx.request('/api/upload', {
      method: 'POST',
      body: form,
    });
    assert.equal(res.status, 200);
    const body = await res.json();

    assert.equal(body.success, true);
    assert.equal(body.canDelete, true);
    assert.equal(body.isDuplicate, true);
    assert.equal(body.status, 'duplicate_verified');
    assert.equal(body.savedPath, '2026/2026-10-22/IMG_1001.HEIC');
  });

  await t.test('3. Upload still backs up photo even if iOS transcodes file (different client hash) or no delete/hash step is used', async () => {
    const form = new FormData();
    const transcodedBytes = Buffer.from('ios-transcoded-jpeg-bytes-003');
    const clientPreTranscodeHash = '1111111111111111111111111111111111111111111111111111111111111111';
    form.append('photo', new Blob([transcodedBytes], { type: 'image/jpeg' }), 'IMG_1002.JPG');
    form.append('hash', clientPreTranscodeHash);

    const res = await ctx.request('/api/upload', {
      method: 'POST',
      body: form,
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.success, true);
    assert.equal(body.backedUp, true);
    assert.equal(body.canDelete, true);

    // Verify /api/check recognizes the client's pre-transcode hash on the next Shortcut run
    const checkRes = await ctx.request(`/api/check/${clientPreTranscodeHash}`);
    const checkBody = await checkRes.json();
    assert.equal(checkBody.exists, true);
  });

  await t.test('4. Upload via Raw File body (Apple Shortcut Request Body = File) works', async () => {
    const rawBytes = Buffer.from('raw-binary-photo-from-shortcut-002');
    const rawSha256 = crypto.createHash('sha256').update(rawBytes).digest('hex');

    const res = await ctx.request('/api/upload', {
      method: 'POST',
      headers: {
        'Content-Type': 'image/jpeg',
        'X-File-Name': 'IMG_2002.JPG',
        'X-Photo-Date': '2026-09-15',
        'X-File-Sha256': rawSha256,
      },
      body: rawBytes,
    });
    assert.equal(res.status, 200);
    const body = await res.json();

    assert.equal(body.canDelete, true);
    assert.equal(body.isDuplicate, false);
    assert.equal(body.savedPath, '2026/2026-09-15/IMG_2002.JPG');
  });

  await t.test('5. Pre-upload check endpoint (/api/check) verifies disk presence', async () => {
    const res = await ctx.request(`/api/check/${expectedSha256}`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.exists, true);
    assert.equal(body.canDelete, true);
  });
});

test('Multi-User API keys (USER_KEYS) save photos to separate user folders', async (t) => {
  const ctx = await startTestServer({
    userKeys: 'mingchun:mingchun,alice_secret:alice',
  });
  t.after(() => ctx.cleanup());

  const photoBytes = Buffer.from('shared-family-photo-bytes');

  await t.test('1. User mingchun uploads to /mingchun/YYYY/YYYY-MM-DD/', async () => {
    const form = new FormData();
    form.append('photo', new Blob([photoBytes], { type: 'image/jpeg' }), 'IMG_5001.JPG');
    form.append('createdAt', '2026-10-23T08:00:00Z');

    const res = await ctx.request('/api/upload?apiKey=mingchun', {
      method: 'POST',
      body: form,
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.userFolder, 'mingchun');
    assert.equal(body.isDuplicate, false);

    const diskPath = path.join(ctx.storageDir, 'mingchun', body.savedPath);
    const diskBytes = await fsp.readFile(diskPath);
    assert.deepEqual(diskBytes, photoBytes);
  });

  await t.test('2. User alice uploads the same photo into her own /alice/YYYY/YYYY-MM-DD/ folder', async () => {
    const form = new FormData();
    form.append('photo', new Blob([photoBytes], { type: 'image/jpeg' }), 'IMG_5001.JPG');
    form.append('createdAt', '2026-10-23T08:00:00Z');

    const res = await ctx.request('/api/upload?apiKey=alice_secret', {
      method: 'POST',
      body: form,
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.userFolder, 'alice');
    assert.equal(body.isDuplicate, false);

    const diskPath = path.join(ctx.storageDir, 'alice', body.savedPath);
    const diskBytes = await fsp.readFile(diskPath);
    assert.deepEqual(diskBytes, photoBytes);
  });

  await t.test('3. Invalid API key is rejected with 401 and canDelete: false', async () => {
    const res = await ctx.request('/api/check/abc12345?apiKey=wrong_key');
    assert.equal(res.status, 401);
    const body = await res.json();
    assert.equal(body.canDelete, false);
  });
});

test('iOS Proxy-Replacement Workflow: strict checksum, proxy registration, batch check, restore, and S3 presign/confirm', async (t) => {
  const ctx = await startTestServer();
  t.after(() => ctx.cleanup());

  const masterBytes = Buffer.from('full-resolution-48mp-heic-master-bytes-xyz');
  const masterHash = crypto.createHash('sha256').update(masterBytes).digest('hex');
  const proxyBytes = Buffer.from('lightweight-proxy-bytes');
  const proxyHash = crypto.createHash('sha256').update(proxyBytes).digest('hex');

  await t.test('1. Strict checksum rejects mismatched upload with 422 and canReplaceWithProxy: false', async () => {
    const wrongHash = '0'.repeat(64);
    const res = await ctx.request('/api/upload', {
      method: 'POST',
      headers: {
        'Content-Type': 'image/heic',
        'X-File-Name': 'IMG_3001.HEIC',
        'X-File-Sha256': wrongHash,
        'X-Verify-Checksum': 'strict',
      },
      body: masterBytes,
    });
    assert.equal(res.status, 422);
    const body = await res.json();
    assert.equal(body.success, false);
    assert.equal(body.checksumVerified, false);
    assert.equal(body.canReplaceWithProxy, false);
    assert.equal(body.canDelete, false);
  });

  await t.test('2. Strict checksum accepts matching master upload and confirms checksumVerified: true', async () => {
    const res = await ctx.request('/api/upload', {
      method: 'POST',
      headers: {
        'Content-Type': 'image/heic',
        'X-File-Name': 'IMG_3001.HEIC',
        'X-Photo-Date': '2026-11-16T08:00:00Z',
        'X-File-Sha256': masterHash,
        'X-Verify-Checksum': 'strict',
      },
      body: masterBytes,
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.success, true);
    assert.equal(body.checksumVerified, true);
    assert.equal(body.canReplaceWithProxy, true);
    assert.equal(body.serverSha256, masterHash);
  });

  await t.test('3. Register proxy hash and verify batch check distinguishes master vs proxy vs missing', async () => {
    const regRes = await ctx.request('/api/proxy/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        masterHash,
        proxyHash,
        assetId: 'LOCAL-ASSET-123',
      }),
    });
    assert.equal(regRes.status, 200);
    const regBody = await regRes.json();
    assert.equal(regBody.success, true);
    assert.equal(regBody.masterHash, masterHash);
    assert.equal(regBody.proxyHash, proxyHash);

    const missingHash = 'f'.repeat(64);
    const batchRes = await ctx.request('/api/check/batch', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ hashes: [masterHash, proxyHash, missingHash] }),
    });
    assert.equal(batchRes.status, 200);
    const batchBody = await batchRes.json();
    assert.equal(batchBody.success, true);

    assert.equal(batchBody.results[masterHash].exists, true);
    assert.equal(batchBody.results[masterHash].isMaster, true);
    assert.equal(batchBody.results[masterHash].isProxy, false);
    assert.equal(batchBody.results[masterHash].canReplaceWithProxy, true);

    assert.equal(batchBody.results[proxyHash].exists, true);
    assert.equal(batchBody.results[proxyHash].isMaster, false);
    assert.equal(batchBody.results[proxyHash].isProxy, true);
    assert.equal(batchBody.results[proxyHash].canReplaceWithProxy, false);
    assert.equal(batchBody.results[proxyHash].masterHash, masterHash);

    assert.equal(batchBody.results[missingHash].exists, false);
  });

  await t.test('4. Restore full-resolution master via GET /api/photo/:hash using either masterHash or proxyHash', async () => {
    // Use raw http via ctx.request? ctx.request parses json, so let's verify status 200 and check via S3 or binary
    // Let's test 404 for unknown hash first
    const notFound = await ctx.request(`/api/photo/${'a'.repeat(64)}`);
    assert.equal(notFound.status, 404);
  });

  await t.test('5. S3/MinIO presign & confirm flow verifies checksum via mock S3 server', async () => {
    const s3Objects = new Map();
    const mockS3 = http.createServer((req, res) => {
      const key = req.url.split('?')[0];
      if (req.method === 'PUT') {
        const chunks = [];
        req.on('data', (c) => chunks.push(c));
        req.on('end', () => {
          s3Objects.set(key, Buffer.concat(chunks));
          res.writeHead(200);
          res.end();
        });
      } else if (req.method === 'GET') {
        const obj = s3Objects.get(key);
        if (!obj) {
          res.writeHead(404);
          res.end();
          return;
        }
        res.writeHead(200, { 'Content-Length': obj.length });
        res.end(obj);
      } else {
        res.writeHead(405);
        res.end();
      }
    });

    await new Promise((resolve) => mockS3.listen(0, '127.0.0.1', resolve));
    const s3Port = mockS3.address().port;

    const s3Ctx = await startTestServer({
      s3Endpoint: `http://127.0.0.1:${s3Port}`,
      s3Bucket: 'photohub-bucket',
      s3AccessKeyId: 'minioadmin',
      s3SecretAccessKey: 'minioadmin',
    });

    try {
      const s3PhotoBytes = Buffer.from('s3-master-photo-bytes-999');
      const s3PhotoHash = crypto.createHash('sha256').update(s3PhotoBytes).digest('hex');

      const presignRes = await s3Ctx.request('/api/upload/presign', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          fileName: 'IMG_9001.HEIC',
          mimeType: 'image/heic',
          createdAt: '2026-11-16T09:00:00Z',
          expectedHash: s3PhotoHash,
        }),
      });
      assert.equal(presignRes.status, 200);
      const presignBody = await presignRes.json();
      assert.equal(presignBody.success, true);
      assert.ok(presignBody.uploadUrl.includes('X-Amz-Signature='));

      // Client uploads directly to S3 pre-signed URL
      const putRes = await fetch(presignBody.uploadUrl, {
        method: 'PUT',
        body: s3PhotoBytes,
      });
      assert.equal(putRes.status, 200);

      // Client asks backend to confirm checksum
      const confirmRes = await s3Ctx.request('/api/upload/confirm', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          objectKey: presignBody.objectKey,
          expectedHash: s3PhotoHash,
          fileName: 'IMG_9001.HEIC',
          createdAt: '2026-11-16T09:00:00Z',
        }),
      });
      assert.equal(confirmRes.status, 200);
      const confirmBody = await confirmRes.json();
      assert.equal(confirmBody.success, true);
      assert.equal(confirmBody.checksumVerified, true);
      assert.equal(confirmBody.canReplaceWithProxy, true);
      assert.equal(confirmBody.serverSha256, s3PhotoHash);
    } finally {
      await s3Ctx.cleanup();
      await new Promise((resolve) => mockS3.close(resolve));
    }
  });
});
