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
            const buffer = Buffer.concat(chunks);
            const raw = buffer.toString('utf8');
            resolve({
              status: res.statusCode,
              headers: res.headers,
              buffer,
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

  await t.test('4. GET /api/whoami reports the resolved userFolder for the provided key', async () => {
    const res = await ctx.request('/api/whoami', {
      headers: { 'X-API-Key': 'alice_secret' },
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.success, true);
    assert.equal(body.userFolder, 'alice');
    assert.equal(body.indexedPhotos, 1);
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
    const sampleVideoProxy = Buffer.from('FAKE_MP4_PROXY_STREAM');
    const regRes = await ctx.request('/api/proxy/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        masterHash,
        proxyHash,
        assetId: 'LOCAL-ASSET-123',
        videoProxyBase64: sampleVideoProxy.toString('base64'),
      }),
    });
    assert.equal(regRes.status, 200);
    const regBody = await regRes.json();
    assert.equal(regBody.success, true);
    assert.equal(regBody.masterHash, masterHash);
    assert.equal(regBody.proxyHash, proxyHash);
    assert.equal(regBody.videoProxySize, sampleVideoProxy.length);

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

  await t.test('4. List backed-up photos via GET /api/photos, stream video proxy, and check 404 on unknown GET /api/photo/:hash', async () => {
    const listRes = await ctx.request('/api/photos');
    assert.equal(listRes.status, 200);
    const listBody = await listRes.json();
    assert.equal(listBody.success, true);
    assert.equal(listBody.total, 1);
    assert.equal(listBody.hasMore, false);
    assert.equal(listBody.photos[0].hash, masterHash);
    assert.equal(listBody.photos[0].hasProxy, true);
    assert.equal(listBody.photos[0].hasPreview, false);
    assert.equal(listBody.photos[0].proxyHash, proxyHash);
    assert.equal(listBody.photos[0].hasVideoProxy, true);
    assert.equal(listBody.photos[0].videoProxySize, Buffer.from('FAKE_MP4_PROXY_STREAM').length);

    const vpRes = await ctx.request(`/api/photo/${masterHash}/video-proxy`);
    assert.equal(vpRes.status, 200);
    assert.equal(vpRes.headers['x-photo-variant'], 'video-proxy');
    assert.equal(vpRes.buffer.toString('utf8'), 'FAKE_MP4_PROXY_STREAM');

    const missingVp = await ctx.request(`/api/photo/${'a'.repeat(64)}/video-proxy`);
    assert.equal(missingVp.status, 404);

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

  await t.test('6. GET /api/photos?sync=1 discovers all server disk files, paginates cleanly, and guards un-proxied video /preview', async () => {
    const manualPhotoDir = path.join(ctx.storageDir, '2026', '2026-11-18');
    await fsp.mkdir(manualPhotoDir, { recursive: true });
    const rawPhotoBytes = Buffer.from('MANUAL_SERVER_JPG_BYTES');
    const rawVideoBytes = Buffer.from('MANUAL_SERVER_MOV_BYTES_RAW_STREAM');
    await fsp.writeFile(path.join(manualPhotoDir, 'MANUAL_001.JPG'), rawPhotoBytes);
    await fsp.writeFile(path.join(manualPhotoDir, 'MANUAL_002.MOV'), rawVideoBytes);
    await fsp.writeFile(path.join(manualPhotoDir, '.DS_Store'), Buffer.from('junk'));

    const page1Res = await ctx.request('/api/photos?sync=1&limit=2&offset=0');
    assert.equal(page1Res.status, 200);
    const page1 = await page1Res.json();
    assert.equal(page1.success, true);
    assert.equal(page1.total, 3);
    assert.equal(page1.hasMore, true);
    assert.equal(page1.photos.length, 2);

    const page2Res = await ctx.request('/api/photos?limit=2&offset=2');
    assert.equal(page2Res.status, 200);
    const page2 = await page2Res.json();
    assert.equal(page2.hasMore, false);
    assert.equal(page2.photos.length, 1);

    const allItems = [...page1.photos, ...page2.photos];
    const manualPhoto = allItems.find((p) => p.originalName === 'MANUAL_001.JPG');
    const manualVideo = allItems.find((p) => p.originalName === 'MANUAL_002.MOV');
    assert.ok(manualPhoto, 'Manual JPG on disk should be discovered');
    assert.ok(manualVideo, 'Manual MOV on disk should be discovered');
    assert.equal(allItems.some((p) => p.originalName === '.DS_Store'), false);
    assert.equal(manualPhoto.hasProxy, false);
    assert.equal(manualPhoto.hasPreview, false);
    assert.equal(manualVideo.hasProxy, false);
    assert.equal(manualVideo.hasPreview, false);

    // Un-proxied image falls back to master bytes on /preview; un-proxied video refuses raw stream with 404 needsProxy
    const imgPrevRes = await ctx.request(`/api/photo/${manualPhoto.hash}/preview`);
    assert.equal(imgPrevRes.status, 200);
    assert.equal(imgPrevRes.headers['x-photo-variant'], 'master');
    assert.equal(imgPrevRes.buffer.toString('utf8'), 'MANUAL_SERVER_JPG_BYTES');

    const vidPrevRes = await ctx.request(`/api/photo/${manualVideo.hash}/preview`);
    assert.equal(vidPrevRes.status, 404);
    const vidPrevJson = await vidPrevRes.json();
    assert.equal(vidPrevJson.needsProxy, true);

    // Register a proxy afterwards and confirm /photos + /preview reflect proxied state
    const manualProxyHash = crypto.createHash('sha256').update('SMALL_JPG_PROXY').digest('hex');
    const regManual = await ctx.request('/api/proxy/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        masterHash: manualPhoto.hash,
        proxyHash: manualProxyHash,
        proxyFormat: 'jpeg',
        proxyBase64: Buffer.from('SMALL_JPG_PROXY').toString('base64'),
      }),
    });
    assert.equal(regManual.status, 200);

    const afterRes = await ctx.request('/api/photos');
    const afterBody = await afterRes.json();
    const updatedManualPhoto = afterBody.photos.find((p) => p.hash === manualPhoto.hash);
    assert.equal(updatedManualPhoto.hasProxy, true);
    assert.equal(updatedManualPhoto.hasPreview, true);

    const cachedPrevRes = await ctx.request(`/api/photo/${manualPhoto.hash}/preview`);
    assert.equal(cachedPrevRes.status, 200);
    assert.equal(cachedPrevRes.headers['x-photo-variant'], 'proxy');
    assert.equal(cachedPrevRes.buffer.toString('utf8'), 'SMALL_JPG_PROXY');
  });

  await t.test('7. Raw binary video proxy streaming upload & server-side sharp proxy generation', async () => {
    const manualPhotoDir = path.join(ctx.storageDir, '2026', '2026-11-18');
    await fsp.mkdir(manualPhotoDir, { recursive: true });

    // Create a valid PNG image on server disk using sharp (32x32 red square)
    let sharpLib = null;
    try {
      sharpLib = require('sharp');
    } catch {
      sharpLib = null;
    }

    const listBefore = await ctx.request('/api/photos?sync=1');
    const beforeBody = await listBefore.json();
    const videoItem = beforeBody.photos.find((p) => p.originalName === 'MANUAL_002.MOV');
    assert.ok(videoItem);

    // Stream compressed binary MP4 proxy without base64 bloat
    const rawMp4 = Buffer.from('RAW_BINARY_MP4_PROXY_STREAM_DATA_XYZ');
    const mp4Sha = crypto.createHash('sha256').update(rawMp4).digest('hex');
    const binUpRes = await ctx.request(`/api/proxy/${videoItem.hash}/video`, {
      method: 'POST',
      headers: {
        'Content-Type': 'video/mp4',
        'X-Proxy-Hash': mp4Sha,
      },
      body: rawMp4,
    });
    assert.equal(binUpRes.status, 200);
    const binUpBody = await binUpRes.json();
    assert.equal(binUpBody.success, true);
    assert.equal(binUpBody.videoProxySize, rawMp4.length);

    const streamRes = await ctx.request(`/api/photo/${videoItem.hash}/video-proxy`);
    assert.equal(streamRes.status, 200);
    assert.equal(streamRes.buffer.toString('utf8'), 'RAW_BINARY_MP4_PROXY_STREAM_DATA_XYZ');

    if (sharpLib) {
      const realPng = await sharpLib({
        create: {
          width: 64,
          height: 64,
          channels: 3,
          background: { r: 220, g: 40, b: 40 },
        },
      })
        .png()
        .toBuffer();
      const pngPath = path.join(manualPhotoDir, 'REAL_IMG_003.PNG');
      await fsp.writeFile(pngPath, realPng);

      const syncRes = await ctx.request('/api/photos?sync=1');
      const syncBody = await syncRes.json();
      const realPhoto = syncBody.photos.find((p) => p.originalName === 'REAL_IMG_003.PNG');
      assert.ok(realPhoto);
      assert.equal(realPhoto.hasProxy, false);

      const genRes = await ctx.request('/api/proxy/generate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          masterHash: realPhoto.hash,
          maxPixelSize: 32,
          quality: 0.7,
        }),
      });
      assert.equal(genRes.status, 200);
      const genBody = await genRes.json();
      assert.equal(genBody.success, true);
      assert.equal(genBody.photo.hasProxy, true);
      assert.equal(genBody.photo.hasPreview, true);
      assert.ok(genBody.photo.proxySize > 0);

      const genPrevRes = await ctx.request(`/api/photo/${realPhoto.hash}/preview`);
      assert.equal(genPrevRes.status, 200);
      assert.equal(genPrevRes.headers['x-photo-variant'], 'proxy');
      assert.equal(genPrevRes.buffer.length, genBody.photo.proxySize);
    }
  });

  await t.test('8. Chronological timeline ordering by date, takenAt, path/filename/EXIF inference, and /api/photos year filter', async () => {
    const timelineCtx = await startTestServer();
    try {
      // Upload morning photo BEFORE afternoon photo on same day; API must still list afternoon photo FIRST
      const morningBytes = Buffer.from('same-day-morning-photo');
      const afternoonBytes = Buffer.from('same-day-afternoon-video');
      const morningForm = new FormData();
      morningForm.append('photo', new Blob([morningBytes], { type: 'image/jpeg' }), 'MORNING.JPG');
      morningForm.append('createdAt', '2025-07-04T12:15:00Z');
      await timelineCtx.request('/api/upload', { method: 'POST', body: morningForm });

      // Slight delay / upload order reverse check: upload an older-date photo AFTER
      const olderUploadForm = new FormData();
      olderUploadForm.append('photo', new Blob([Buffer.from('older-day-uploaded-later')], { type: 'image/jpeg' }), 'EARLIER_DATE.JPG');
      olderUploadForm.append('createdAt', '2024-02-20T12:00:00Z');
      await timelineCtx.request('/api/upload', { method: 'POST', body: olderUploadForm });

      const afternoonForm = new FormData();
      afternoonForm.append('photo', new Blob([afternoonBytes], { type: 'video/mp4' }), 'AFTERNOON.MP4');
      afternoonForm.append('createdAt', '2025-07-04T14:45:00Z');
      await timelineCtx.request('/api/upload', { method: 'POST', body: afternoonForm });

      // Drop disk files into historical path, filename date, and EXIF JPEG (with current mtime = today)
      const histDir = path.join(timelineCtx.storageDir, '2022', '2022-05-03');
      await fsp.mkdir(histDir, { recursive: true });
      await fsp.writeFile(path.join(histDir, 'VACATION_CLIP.MOV'), Buffer.from('fake-historical-mov'));

      const unorganizedDir = path.join(timelineCtx.storageDir, 'imports');
      await fsp.mkdir(unorganizedDir, { recursive: true });
      await fsp.writeFile(path.join(unorganizedDir, 'VID_20231102_091530.mp4'), Buffer.from('filename-dated-mp4'));

      // Build minimal valid JPEG with APP1 EXIF DateTimeOriginal = "2021:03:14 15:09:26"
      const tiff = Buffer.alloc(64);
      tiff.write('II', 0, 'ascii');
      tiff.writeUInt16LE(0x002a, 2);
      tiff.writeUInt32LE(8, 4);
      // IFD0 at offset 8
      tiff.writeUInt16LE(1, 8);
      tiff.writeUInt16LE(0x8769, 10);
      tiff.writeUInt16LE(4, 12);
      tiff.writeUInt32LE(1, 14);
      tiff.writeUInt32LE(26, 18);
      tiff.writeUInt32LE(0, 22);
      // ExifIFD at offset 26
      tiff.writeUInt16LE(1, 26);
      tiff.writeUInt16LE(0x9003, 28);
      tiff.writeUInt16LE(2, 30);
      tiff.writeUInt32LE(20, 32);
      tiff.writeUInt32LE(44, 36);
      tiff.writeUInt32LE(0, 40);
      tiff.write('2021:03:14 15:09:26\0', 44, 'ascii');

      const exifHeader = Buffer.from('Exif\0\0', 'ascii');
      const segLen = 2 + exifHeader.length + tiff.length;
      const app1 = Buffer.alloc(4);
      app1[0] = 0xff;
      app1[1] = 0xe1;
      app1.writeUInt16BE(segLen, 2);
      const exifJpg = Buffer.concat([
        Buffer.from([0xff, 0xd8]),
        app1,
        exifHeader,
        tiff,
        Buffer.from([0xff, 0xd9]),
      ]);
      await fsp.writeFile(path.join(unorganizedDir, 'IMG_UNORGANIZED.JPG'), exifJpg);

      const syncRes = await timelineCtx.request('/api/photos?sync=1');
      assert.equal(syncRes.status, 200);
      const syncBody = await syncRes.json();
      assert.equal(syncBody.total, 6);

      // Should be strictly ordered newest -> oldest across years & intra-day takenAt!
      const orderedNames = syncBody.photos.map((p) => p.originalName);
      assert.deepEqual(orderedNames, [
        'AFTERNOON.MP4',
        'MORNING.JPG',
        'EARLIER_DATE.JPG',
        'VID_20231102_091530.mp4',
        'VACATION_CLIP.MOV',
        'IMG_UNORGANIZED.JPG',
      ]);

      const exifEntry = syncBody.photos.find((p) => p.originalName === 'IMG_UNORGANIZED.JPG');
      assert.equal(exifEntry.photoDate, '2021-03-14');
      assert.equal(exifEntry.year, 2021);
      assert.ok(exifEntry.takenAt);

      const histEntry = syncBody.photos.find((p) => p.originalName === 'VACATION_CLIP.MOV');
      assert.equal(histEntry.photoDate, '2022-05-03');
      assert.equal(histEntry.year, 2022);

      const fnEntry = syncBody.photos.find((p) => p.originalName === 'VID_20231102_091530.mp4');
      assert.equal(fnEntry.photoDate, '2023-11-02');
      assert.equal(fnEntry.year, 2023);

      // Years summary array sorted newest first
      assert.deepEqual(
        syncBody.years.map((y) => [y.year, y.count]),
        [
          [2025, 2],
          [2024, 1],
          [2023, 1],
          [2022, 1],
          [2021, 1],
        ]
      );

      // Optional year & mediaType query filters
      const videosOnly = await (await timelineCtx.request('/api/photos?mediaType=video')).json();
      assert.deepEqual(
        videosOnly.photos.map((p) => p.originalName),
        ['AFTERNOON.MP4', 'VID_20231102_091530.mp4', 'VACATION_CLIP.MOV']
      );

      const y2025 = await (await timelineCtx.request('/api/photos?year=2025&order=asc')).json();
      assert.deepEqual(
        y2025.photos.map((p) => p.originalName),
        ['MORNING.JPG', 'AFTERNOON.MP4']
      );
    } finally {
      await timelineCtx.cleanup();
    }
  });
});

test('Storage Quota Reporting & Upload Enforcement', async (t) => {
  const ctx = await startTestServer({
    userKeys: 'alice_key:alice,bob_key:bob',
    userQuotaBytes: { alice: 60, bob: 200 },
  });
  t.after(() => ctx.cleanup());

  await t.test('1. Reports per-user quota and usage in /api/whoami and /api/storage', async () => {
    const fileA = Buffer.alloc(40, 0x41);
    const up = new FormData();
    up.append('photo', new Blob([fileA], { type: 'image/jpeg' }), 'FIRST.JPG');
    const upRes = await ctx.request('/api/upload?apiKey=alice_key', {
      method: 'POST',
      body: up,
    });
    assert.equal(upRes.status, 200);

    const whoRes = await ctx.request('/api/whoami', {
      headers: { 'X-API-Key': 'alice_key' },
    });
    assert.equal(whoRes.status, 200);
    const who = await whoRes.json();
    assert.equal(who.storage.usedBytes, 40);
    assert.equal(who.storage.quotaBytes, 60);
    assert.equal(who.storage.remainingBytes, 20);
    assert.equal(who.storage.itemCount, 1);

    const stRes = await ctx.request('/api/storage', {
      headers: { 'X-API-Key': 'alice_key' },
    });
    assert.equal(stRes.status, 200);
    const st = await stRes.json();
    assert.equal(st.usedBytes, 40);
    assert.equal(st.quotaBytes, 60);
    assert.equal(st.remainingBytes, 20);
  });

  await t.test('2. Blocks new uploads exceeding quota with HTTP 507 while allowing duplicates', async () => {
    const tooBig = Buffer.alloc(25, 0x42);
    const failForm = new FormData();
    failForm.append('photo', new Blob([tooBig], { type: 'image/jpeg' }), 'OVER_QUOTA.JPG');
    const failRes = await ctx.request('/api/upload?apiKey=alice_key', {
      method: 'POST',
      body: failForm,
    });
    assert.equal(failRes.status, 507);
    const failBody = await failRes.json();
    assert.equal(failBody.success, false);
    assert.equal(failBody.canDelete, false);
    assert.ok(failBody.storage);

    // Duplicate of FIRST.JPG still succeeds without increasing used space
    const dupForm = new FormData();
    dupForm.append('photo', new Blob([Buffer.alloc(40, 0x41)], { type: 'image/jpeg' }), 'FIRST_DUP.JPG');
    const dupRes = await ctx.request('/api/upload?apiKey=alice_key', {
      method: 'POST',
      body: dupForm,
    });
    assert.equal(dupRes.status, 200);
    const dupBody = await dupRes.json();
    assert.equal(dupBody.isDuplicate, true);
  });

  await t.test('3. DEFAULT_QUOTA_GB=5000 resolves to exact 5 TB (5e12 bytes) matching iOS .file display', async () => {
    const { getConfig } = require('../src/config');
    const cfg = getConfig({ defaultQuotaGb: 5000, userQuotas: 'tester:50' });
    assert.equal(cfg.defaultQuotaBytes, 5_000_000_000_000);
    assert.equal(cfg.userQuotaMap.get('tester'), 50_000_000_000);
  });
});

test('Google OAuth PKCE Login, Gateway Node Routing, and Cross-Node Session Verification', async (t) => {
  const sharedSecret = 'test-shared-hmac-secret-between-gateway-and-nodes-1234567890';
  const gatewayCtx = await startTestServer({
    publicUrl: 'https://gateway.photohub.test',
    googleClientId: 'google-client-id.apps.googleusercontent.com',
    googleClientSecret: 'google-client-secret-only-on-server',
    authSessionSecret: sharedSecret,
    defaultQuotaBytes: 1024 * 1024,
    storageNodes: 'node1=https://s1.photohub.test,node2=https://s2.photohub.test',
    userNodeMap: 'alice@gmail.com=node2',
    exchangeGoogleCodeForProfile: async ({ code }) => {
      assert.equal(code, 'mock_google_auth_code');
      return {
        sub: 'google-sub-alice-001',
        email: 'alice@gmail.com',
        name: 'Alice Photo',
      };
    },
  });
  t.after(() => gatewayCtx.cleanup());

  // Second pure storage node sharing ONLY AUTH_SESSION_SECRET (no Google OAuth keys needed on worker!)
  const node2Ctx = await startTestServer({
    requireAuth: true,
    authSessionSecret: sharedSecret,
    defaultQuotaBytes: 1024 * 1024,
  });
  t.after(() => node2Ctx.cleanup());

  await t.test('1. Public /api/auth/config advertises Google login without exposing secrets', async () => {
    const cfgRes = await gatewayCtx.request('/api/auth/config');
    assert.equal(cfgRes.status, 200);
    const cfg = await cfgRes.json();
    assert.equal(cfg.googleEnabled, true);
    assert.equal(cfg.hasStorageNodes, true);
    assert.equal(cfg.nodeCount, 2);
    assert.equal(JSON.stringify(cfg).includes('google-client-secret'), false);

    // Unauthenticated API requests must fail closed with 401 on both gateway and worker node
    const unauthGw = await gatewayCtx.request('/api/photos');
    assert.equal(unauthGw.status, 401);
    const unauthNode2 = await node2Ctx.request('/api/whoami');
    assert.equal(unauthNode2.status, 401);
  });

  await t.test('2. Full PKCE start -> Google callback -> exchange mints JWT routed to node2 & rejected on wrong verifier', async () => {
    const codeVerifier = 'pkce_verifier_secret_random_string_at_least_32_chars_long';
    const codeChallenge = crypto
      .createHash('sha256')
      .update(codeVerifier, 'utf8')
      .digest('base64')
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/g, '');

    const startRes = await gatewayCtx.request(
      `/api/auth/google/start?code_challenge=${encodeURIComponent(codeChallenge)}&redirect_uri=${encodeURIComponent('photohub://auth/callback')}`
    );
    assert.equal(startRes.status, 302);
    const googleRedirect = new URL(startRes.headers.location);
    assert.equal(googleRedirect.hostname, 'accounts.google.com');
    assert.equal(
      googleRedirect.searchParams.get('redirect_uri'),
      'https://gateway.photohub.test/api/auth/google/callback'
    );
    const signedState = googleRedirect.searchParams.get('state');
    assert.ok(signedState);

    const cbRes = await gatewayCtx.request(
      `/api/auth/google/callback?code=mock_google_auth_code&state=${encodeURIComponent(signedState)}`
    );
    assert.equal(cbRes.status, 302);
    const appRedirect = new URL(cbRes.headers.location);
    assert.equal(appRedirect.protocol, 'photohub:');
    assert.equal(appRedirect.hostname, 'auth');
    const oneTimeCode = appRedirect.searchParams.get('code');
    assert.ok(oneTimeCode);

    // Wrong PKCE verifier is rejected (and single-use code is consumed)
    const badExRes = await gatewayCtx.request('/api/auth/exchange', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        code: oneTimeCode,
        codeVerifier: 'wrong_verifier_string_32_chars_plus_000000000',
      }),
    });
    assert.equal(badExRes.status, 401);

    // Fresh OAuth start + callback -> valid PKCE exchange -> cross-node authentication on node2
    const startRes2 = await gatewayCtx.request(
      `/api/auth/google/start?code_challenge=${encodeURIComponent(codeChallenge)}&redirect_uri=${encodeURIComponent('photohub://auth/callback')}`
    );
    const state2 = new URL(startRes2.headers.location).searchParams.get('state');
    const cbRes2 = await gatewayCtx.request(
      `/api/auth/google/callback?code=mock_google_auth_code&state=${encodeURIComponent(state2)}`
    );
    const oneTimeCode2 = new URL(cbRes2.headers.location).searchParams.get('code');

    const exRes = await gatewayCtx.request('/api/auth/exchange', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: oneTimeCode2, codeVerifier }),
    });
    assert.equal(exRes.status, 200);
    const session = await exRes.json();
    assert.equal(session.success, true);
    assert.equal(session.serverUrl, 'https://s2.photohub.test');
    assert.equal(session.nodeId, 'node2');
    assert.equal(session.user.email, 'alice@gmail.com');
    assert.ok(session.token);

    // Replay of the same one-time code must fail
    const replayRes = await gatewayCtx.request('/api/auth/exchange', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: oneTimeCode2, codeVerifier }),
    });
    assert.equal(replayRes.status, 401);

    // Storage node 2 accepts gateway-minted Bearer JWT, auto-creates user's folder, & enforces quota
    const nodeWho = await (
      await node2Ctx.request('/api/whoami', {
        headers: { Authorization: `Bearer ${session.token}` },
      })
    ).json();
    assert.equal(nodeWho.success, true);
    assert.equal(nodeWho.email, 'alice@gmail.com');
    assert.ok(nodeWho.userFolder.startsWith('google_alice_'));
    assert.equal(nodeWho.storage.quotaBytes, 1024 * 1024);

    // Upload directly to node2 using Bearer JWT
    const upForm = new FormData();
    upForm.append('photo', new Blob([Buffer.from('google-node2-photo-bytes')], { type: 'image/jpeg' }), 'G_IMG.JPG');
    const upRes = await node2Ctx.request('/api/upload', {
      method: 'POST',
      headers: { Authorization: `Bearer ${session.token}` },
      body: upForm,
    });
    assert.equal(upRes.status, 200);
    const upBody = await upRes.json();
    assert.equal(upBody.userFolder, nodeWho.userFolder);
  });

  await t.test('3. USER_FOLDERS maps Google login to pre-existing root "/" or named folder on disk', async () => {
    const rootCtx = await startTestServer({
      publicUrl: 'https://photohub.test',
      googleClientId: 'cid',
      googleClientSecret: 'csec',
      authSessionSecret: sharedSecret,
      userFolders: 'owner@gmail.com=/,alice@gmail.com=legacy_alice',
      exchangeGoogleCodeForProfile: async ({ code }) =>
        code === 'owner_code'
          ? { sub: 'sub-owner', email: 'owner@gmail.com', name: 'Owner' }
          : { sub: 'sub-legacy-alice', email: 'alice@gmail.com', name: 'Alice' },
    });
    try {
      // Pre-existing photos placed directly inside HOST_STORAGE_DIR root & legacy_alice subfolder
      const rootPhotoDir = path.join(rootCtx.storageDir, '2025', '2025-11-10');
      const aliceLegacyDir = path.join(rootCtx.storageDir, 'legacy_alice', '2024', '2024-08-01');
      await fsp.mkdir(rootPhotoDir, { recursive: true });
      await fsp.mkdir(aliceLegacyDir, { recursive: true });
      await fsp.writeFile(path.join(rootPhotoDir, 'EXISTING_ROOT.JPG'), Buffer.from('root-existing-photo'));
      await fsp.writeFile(path.join(aliceLegacyDir, 'EXISTING_ALICE.JPG'), Buffer.from('alice-legacy-photo'));

      const codeVerifier = 'pkce_verifier_secret_random_string_at_least_32_chars_long';
      const challenge = crypto
        .createHash('sha256')
        .update(codeVerifier, 'utf8')
        .digest('base64')
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/g, '');

      async function loginWith(code) {
        const start = await rootCtx.request(
          `/api/auth/google/start?code_challenge=${encodeURIComponent(challenge)}&redirect_uri=${encodeURIComponent('photohub://auth/callback')}`
        );
        const state = new URL(start.headers.location).searchParams.get('state');
        const cb = await rootCtx.request(
          `/api/auth/google/callback?code=${encodeURIComponent(code)}&state=${encodeURIComponent(state)}`
        );
        const oneTimeCode = new URL(cb.headers.location).searchParams.get('code');
        const ex = await rootCtx.request('/api/auth/exchange', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ code: oneTimeCode, codeVerifier }),
        });
        return ex.json();
      }

      const ownerSession = await loginWith('owner_code');
      assert.equal(ownerSession.user.folderName, '');
      const ownerPhotos = await (
        await rootCtx.request('/api/photos?sync=1', {
          headers: { Authorization: `Bearer ${ownerSession.token}` },
        })
      ).json();
      assert.ok(ownerPhotos.photos.some((p) => p.originalName === 'EXISTING_ROOT.JPG'));

      const aliceSession = await loginWith('alice_code');
      assert.equal(aliceSession.user.folderName, 'legacy_alice');
      const alicePhotos = await (
        await rootCtx.request('/api/photos?sync=1', {
          headers: { Authorization: `Bearer ${aliceSession.token}` },
        })
      ).json();
      assert.deepEqual(
        alicePhotos.photos.map((p) => p.originalName),
        ['EXISTING_ALICE.JPG']
      );
    } finally {
      await rootCtx.cleanup();
    }
  });
});

test('Multi-device proxy dedupe (proxyHashes) & Restored Original protection', async (t) => {
  const ctx = await startTestServer();
  t.after(() => ctx.cleanup());

  const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
  const masterBytes = Buffer.from('FAKE-MASTER-ORIGINAL-HEIC-BYTES-2026-001');
  const proxy1Bytes = Buffer.from('FAKE-PROXY-IPHONE-A-BYTES-001');
  const proxy2Bytes = Buffer.from('FAKE-PROXY-IPHONE-B-REENCODED-002');
  const masterHash = sha256(masterBytes);
  const proxy1Hash = sha256(proxy1Bytes);
  const proxy2Hash = sha256(proxy2Bytes);

  // 1. Upload original master from iPhone A
  const form = new FormData();
  form.append('expectedHash', masterHash);
  form.append('strictChecksum', 'true');
  form.append('photo', new Blob([masterBytes], { type: 'image/jpeg' }), 'IMG_4200.JPG');
  const upRes = await ctx.request('/api/upload', { method: 'POST', body: form });
  assert.equal(upRes.status, 200);

  // 2. Register proxy from iPhone A and a second proxy hash (e.g. iCloud re-encode) from iPhone B
  const reg1 = await ctx.request('/api/proxy/register', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      masterHash,
      proxyHash: proxy1Hash,
      previewBase64: proxy1Bytes.toString('base64'),
    }),
  });
  assert.equal(reg1.status, 200);

  const reg2 = await ctx.request('/api/proxy/register', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      masterHash,
      proxyHash: proxy2Hash,
    }),
  });
  assert.equal(reg2.status, 200);

  // Both proxy hashes remain mapped to the same master and cannot be re-proxied or deleted
  const checkBoth = await (
    await ctx.request('/api/check/batch', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ hashes: [masterHash, proxy1Hash, proxy2Hash] }),
    })
  ).json();

  assert.equal(checkBoth.results[proxy1Hash].exists, true);
  assert.equal(checkBoth.results[proxy1Hash].isProxy, true);
  assert.equal(checkBoth.results[proxy1Hash].masterHash, masterHash);
  assert.equal(checkBoth.results[proxy1Hash].canReplaceWithProxy, false);
  assert.equal(checkBoth.results[proxy1Hash].canDelete, false);

  assert.equal(checkBoth.results[proxy2Hash].exists, true);
  assert.equal(checkBoth.results[proxy2Hash].isProxy, true);
  assert.equal(checkBoth.results[proxy2Hash].masterHash, masterHash);
  assert.equal(checkBoth.results[proxy2Hash].canReplaceWithProxy, false);

  // Uploading proxy1Bytes directly must NOT store a duplicate master file on server
  const dupForm = new FormData();
  dupForm.append('photo', new Blob([proxy1Bytes], { type: 'image/jpeg' }), 'PHOTOHUB_PROXY.jpg');
  const dupUpRes = await ctx.request('/api/upload', { method: 'POST', body: dupForm });
  assert.equal(dupUpRes.status, 200);
  const dupUpBody = await dupUpRes.json();
  assert.equal(dupUpBody.isProxy, true);
  assert.equal(dupUpBody.status, 'existing_proxy');
  assert.equal(dupUpBody.canReplaceWithProxy, false);

  const photosBefore = await (await ctx.request('/api/photos')).json();
  assert.equal(photosBefore.total, 1);

  // 3. Protect original (triggered when user taps Restore)
  const protRes = await ctx.request(`/api/photo/${masterHash}/protect-original`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ keepOriginalOnDevice: true }),
  });
  assert.equal(protRes.status, 200);
  const protBody = await protRes.json();
  assert.equal(protBody.keepOriginalOnDevice, true);
  assert.equal(protBody.photo.keepOriginalOnDevice, true);

  // Check endpoint & GET /api/photos reflect protection across all devices
  const checkProtected = await (await ctx.request(`/api/check/${masterHash}`)).json();
  assert.equal(checkProtected.isMaster, true);
  assert.equal(checkProtected.isProtectedOriginal, true);
  assert.equal(checkProtected.keepOriginalOnDevice, true);
  assert.equal(checkProtected.canReplaceWithProxy, false);
  assert.equal(checkProtected.canDelete, false);

  const listProtected = await (await ctx.request('/api/photos')).json();
  assert.equal(listProtected.photos[0].keepOriginalOnDevice, true);

  // 4. Clearing protection restores ability to compress/proxy again if user unlocks manually
  const unlockRes = await ctx.request(`/api/photo/${masterHash}/protect-original`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ keepOriginalOnDevice: false }),
  });
  assert.equal(unlockRes.status, 200);
  const checkUnlocked = await (await ctx.request(`/api/check/${masterHash}`)).json();
  assert.equal(checkUnlocked.isProtectedOriginal, false);
  assert.equal(checkUnlocked.canReplaceWithProxy, true);
  assert.equal(checkUnlocked.canDelete, true);
});
