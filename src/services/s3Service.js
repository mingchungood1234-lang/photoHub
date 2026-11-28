/**
 * MEGA S4 / S3 / MINIO / R2 OBJECT STORAGE SERVICE (Zero External Dependencies)
 *
 * Pure Node.js AWS Signature Version 4 (SigV4) client supporting:
 *   - Path-style & virtual-hosted-style addressing (MEGA S4 recommends `forcePathStyle: true`)
 *   - Pre-signed PUT / GET / DELETE URLs
 *   - Direct Buffer PUT (`putS3Buffer`) & streaming File PUT (`uploadFileToS3`)
 *   - S3 Multipart Upload for large 4K videos (zero full-file RAM buffering, automatic abort on error)
 *   - Backend-proxied streaming GET/HEAD with full HTTP 206 Range & ETag 304 support (eliminates browser CORS issues)
 *   - Temporary download to file/buffer for server-side proxy/thumbnail generation and visual analysis
 */

const crypto = require('crypto');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const { Readable } = require('stream');

const DEFAULT_MULTIPART_THRESHOLD = 64 * 1024 * 1024; // 64 MB
const DEFAULT_MULTIPART_PART_SIZE = 16 * 1024 * 1024; // 16 MB

function sha256Hex(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function hmacSha256(key, data) {
  return crypto.createHmac('sha256', key).update(data).digest();
}

function getSigningKey(secretKey, dateStamp, region, service) {
  const kDate = hmacSha256(`AWS4${secretKey}`, dateStamp);
  const kRegion = hmacSha256(kDate, region);
  const kService = hmacSha256(kRegion, service);
  return hmacSha256(kService, 'aws4_request');
}

function encodeRfc3986(str) {
  return encodeURIComponent(str).replace(
    /[!'()*]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

function encodeS3Key(key) {
  return String(key || '')
    .split('/')
    .map((seg) => encodeRfc3986(seg))
    .join('/');
}

function isS3Configured(s3Config) {
  return Boolean(
    s3Config &&
      s3Config.bucket &&
      s3Config.accessKeyId &&
      s3Config.secretAccessKey
  );
}

function isPrimaryS3Backend(config) {
  return Boolean(config && config.storageBackend === 's3' && isS3Configured(config.s3));
}

function normalizeS3Prefix(rawPrefix) {
  return String(rawPrefix || '')
    .trim()
    .replace(/\\/g, '/')
    .replace(/^\/+|\/+$/g, '');
}

function buildS3ObjectKey({ folderName = null, year, dateFolder, hash, fileName, prefix = '' }) {
  const parts = [];
  const cleanPrefix = normalizeS3Prefix(prefix);
  if (cleanPrefix) parts.push(cleanPrefix);
  const cleanFolder = normalizeS3Prefix(folderName);
  if (cleanFolder) parts.push(cleanFolder);
  if (year) parts.push(String(year));
  if (dateFolder) parts.push(String(dateFolder));
  const hashPrefix = String(hash || '').trim().toLowerCase().slice(0, 8);
  const cleanName = path.basename(String(fileName || 'media.bin')).replace(/[<>:"/\\|?*\x00-\x1F]/g, '_');
  parts.push(hashPrefix ? `${hashPrefix}_${cleanName}` : cleanName);
  return parts.join('/');
}

function buildS3ProxyKey({ folderName = null, masterHash, ext = '.jpg', prefix = '' }) {
  const parts = [];
  const cleanPrefix = normalizeS3Prefix(prefix);
  if (cleanPrefix) parts.push(cleanPrefix);
  const cleanFolder = normalizeS3Prefix(folderName);
  if (cleanFolder) parts.push(cleanFolder);
  const normMaster = String(masterHash || '')
    .trim()
    .toLowerCase()
    .replace(/[^a-f0-9]/g, '');
  const cleanExt = ext.startsWith('.') ? ext : `.${ext}`;
  parts.push('.proxies', `${normMaster}${cleanExt}`);
  return parts.join('/');
}

function resolveS3UrlParts(s3Config, objectKey) {
  const cleanKey = String(objectKey || '').replace(/^\/+/, '');
  const region = s3Config.region || 'us-east-1';
  const base = s3Config.endpoint
    ? s3Config.endpoint.replace(/\/+$/, '')
    : `https://s3.${region}.amazonaws.com`;

  const parsed = new URL(base);
  const encodedKey = encodeS3Key(cleanKey);

  let host = parsed.host;
  let canonicalUri;

  if (s3Config.forcePathStyle !== false || s3Config.endpoint) {
    canonicalUri = `${parsed.pathname.replace(/\/+$/, '')}/${encodeRfc3986(s3Config.bucket)}/${encodedKey}`;
  } else {
    host = `${s3Config.bucket}.${parsed.host}`;
    canonicalUri = `/${encodedKey}`;
  }

  return {
    protocol: parsed.protocol,
    host,
    canonicalUri,
    region,
  };
}

function buildCanonicalQueryString(queryObj = {}) {
  const keys = Object.keys(queryObj).sort();
  return keys
    .map((k) => `${encodeRfc3986(k)}=${encodeRfc3986(queryObj[k] === undefined || queryObj[k] === null ? '' : String(queryObj[k]))}`)
    .join('&');
}

/**
 * Generates an AWS Signature Version 4 pre-signed PUT / GET / DELETE / HEAD URL.
 */
function createPresignedUrl({
  s3Config,
  method = 'PUT',
  objectKey,
  expiresIn = 900,
  query = null,
}) {
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const { protocol, host, canonicalUri, region } = resolveS3UrlParts(
    s3Config,
    objectKey
  );

  const credentialScope = `${dateStamp}/${region}/s3/aws4_request`;
  const queryParams = {
    ...(query || {}),
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${s3Config.accessKeyId}/${credentialScope}`,
    'X-Amz-Date': amzDate,
    'X-Amz-Expires': String(expiresIn),
    'X-Amz-SignedHeaders': 'host',
  };

  const canonicalQueryString = buildCanonicalQueryString(queryParams);
  const canonicalHeaders = `host:${host}\n`;
  const signedHeaders = 'host';
  const payloadHash = 'UNSIGNED-PAYLOAD';

  const canonicalRequest = [
    method.toUpperCase(),
    canonicalUri,
    canonicalQueryString,
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join('\n');

  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    credentialScope,
    sha256Hex(canonicalRequest),
  ].join('\n');

  const signingKey = getSigningKey(
    s3Config.secretAccessKey,
    dateStamp,
    region,
    's3'
  );
  const signature = crypto
    .createHmac('sha256', signingKey)
    .update(stringToSign)
    .digest('hex');

  return `${protocol}//${host}${canonicalUri}?${canonicalQueryString}&X-Amz-Signature=${signature}`;
}

/**
 * Performs an AWS SigV4 Authorization-header signed S3 HTTP request.
 * Works cleanly for PUT, POST (multipart), GET, HEAD, and DELETE on MEGA S4, AWS S3, MinIO, and R2.
 */
async function signedS3Fetch({
  s3Config,
  method = 'GET',
  objectKey,
  query = {},
  headers = {},
  body = undefined,
  payloadHash = null,
  signal = undefined,
  duplex = undefined,
}) {
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const { protocol, host, canonicalUri, region } = resolveS3UrlParts(s3Config, objectKey);
  const credentialScope = `${dateStamp}/${region}/s3/aws4_request`;

  const resolvedPayloadHash =
    payloadHash ||
    (Buffer.isBuffer(body)
      ? sha256Hex(body)
      : typeof body === 'string'
        ? sha256Hex(Buffer.from(body, 'utf8'))
        : body === undefined || body === null
          ? sha256Hex('')
          : 'UNSIGNED-PAYLOAD');

  const headerMap = new Map();
  headerMap.set('host', host);
  headerMap.set('x-amz-content-sha256', resolvedPayloadHash);
  headerMap.set('x-amz-date', amzDate);

  const fetchHeaders = {
    'x-amz-content-sha256': resolvedPayloadHash,
    'x-amz-date': amzDate,
  };

  for (const [k, v] of Object.entries(headers || {})) {
    if (v === undefined || v === null) continue;
    const lower = k.toLowerCase();
    const val = String(v).trim();
    fetchHeaders[k] = val;
    if (lower === 'content-type' || lower === 'range' || lower.startsWith('x-amz-')) {
      headerMap.set(lower, val);
    }
  }

  const sortedHeaderKeys = Array.from(headerMap.keys()).sort();
  const canonicalHeaders = sortedHeaderKeys.map((k) => `${k}:${headerMap.get(k)}\n`).join('');
  const signedHeaders = sortedHeaderKeys.join(';');
  const canonicalQueryString = buildCanonicalQueryString(query);

  const canonicalRequest = [
    method.toUpperCase(),
    canonicalUri,
    canonicalQueryString,
    canonicalHeaders,
    signedHeaders,
    resolvedPayloadHash,
  ].join('\n');

  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    credentialScope,
    sha256Hex(canonicalRequest),
  ].join('\n');

  const signingKey = getSigningKey(s3Config.secretAccessKey, dateStamp, region, 's3');
  const signature = crypto.createHmac('sha256', signingKey).update(stringToSign).digest('hex');

  fetchHeaders.Authorization = `AWS4-HMAC-SHA256 Credential=${s3Config.accessKeyId}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

  const url = `${protocol}//${host}${canonicalUri}${canonicalQueryString ? `?${canonicalQueryString}` : ''}`;
  const fetchOpts = {
    method: method.toUpperCase(),
    headers: fetchHeaders,
    ...(body !== undefined ? { body } : {}),
    ...(signal ? { signal } : {}),
    ...(duplex ? { duplex } : {}),
  };

  return fetch(url, fetchOpts);
}

/**
 * Uploads an in-memory Buffer directly to MEGA S4 / S3 via SigV4 PUT.
 */
async function putS3Buffer({
  s3Config,
  objectKey,
  buffer,
  contentType = 'application/octet-stream',
}) {
  if (!Buffer.isBuffer(buffer)) {
    throw new Error('putS3Buffer requires a Buffer');
  }
  const response = await signedS3Fetch({
    s3Config,
    method: 'PUT',
    objectKey,
    headers: {
      'Content-Type': contentType,
      'Content-Length': String(buffer.length),
    },
    body: buffer,
  });
  if (!response.ok) {
    const errText = await response.text().catch(() => '');
    const err = new Error(
      `S3 PUT failed for ${objectKey} (HTTP ${response.status})${errText ? `: ${errText.slice(0, 180)}` : ''}`
    );
    err.statusCode = 502;
    throw err;
  }
  return {
    objectKey,
    size: buffer.length,
    etag: response.headers.get('etag') || null,
  };
}

function escapeXml(str) {
  return String(str || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

async function readExactSlice(fh, offset, length) {
  const buf = Buffer.allocUnsafe(length);
  let totalRead = 0;
  while (totalRead < length) {
    const { bytesRead } = await fh.read(buf, totalRead, length - totalRead, offset + totalRead);
    if (bytesRead <= 0) break;
    totalRead += bytesRead;
  }
  return totalRead === length ? buf : buf.subarray(0, totalRead);
}

/**
 * Streams a local file to MEGA S4 / S3 without loading large videos into RAM.
 * Automatically switches to S3 Multipart Upload when file size exceeds `multipartThresholdBytes`.
 */
async function uploadFileToS3({
  s3Config,
  objectKey,
  filePath,
  contentType = 'application/octet-stream',
  multipartThresholdBytes = null,
  partSizeBytes = null,
}) {
  const stat = await fsp.stat(filePath);
  const totalSize = stat.size;
  const threshold =
    Number(multipartThresholdBytes || (s3Config && s3Config.multipartThresholdBytes)) ||
    DEFAULT_MULTIPART_THRESHOLD;
  const partSize = Math.max(
    5 * 1024 * 1024, // S3 minimum multipart chunk size is 5 MiB (except final part)
    Number(partSizeBytes || (s3Config && s3Config.multipartPartSizeBytes)) ||
      DEFAULT_MULTIPART_PART_SIZE
  );

  // Single streaming PUT for normal photos & medium videos (<= threshold)
  if (totalSize <= threshold) {
    const rs = fs.createReadStream(filePath, { highWaterMark: 512 * 1024 });
    const response = await signedS3Fetch({
      s3Config,
      method: 'PUT',
      objectKey,
      headers: {
        'Content-Type': contentType,
        'Content-Length': String(totalSize),
      },
      body: Readable.toWeb(rs),
      payloadHash: 'UNSIGNED-PAYLOAD',
      duplex: 'half',
    });
    if (!response.ok) {
      const errText = await response.text().catch(() => '');
      const err = new Error(
        `S3 streaming PUT failed for ${objectKey} (HTTP ${response.status})${errText ? `: ${errText.slice(0, 180)}` : ''}`
      );
      err.statusCode = 502;
      throw err;
    }
    return {
      objectKey,
      size: totalSize,
      etag: response.headers.get('etag') || null,
      multipart: false,
    };
  }

  // S3 Multipart Upload for large 4K videos (> threshold)
  const initRes = await signedS3Fetch({
    s3Config,
    method: 'POST',
    objectKey,
    query: { uploads: '' },
    headers: { 'Content-Type': contentType },
  });
  if (!initRes.ok) {
    const errText = await initRes.text().catch(() => '');
    const err = new Error(
      `S3 CreateMultipartUpload failed (HTTP ${initRes.status})${errText ? `: ${errText.slice(0, 180)}` : ''}`
    );
    err.statusCode = 502;
    throw err;
  }
  const initXml = await initRes.text();
  const uploadIdMatch = initXml.match(/<UploadId>([^<]+)<\/UploadId>/);
  if (!uploadIdMatch || !uploadIdMatch[1]) {
    const err = new Error('S3 CreateMultipartUpload response missing UploadId');
    err.statusCode = 502;
    throw err;
  }
  const uploadId = uploadIdMatch[1].trim();
  const completedParts = [];
  let fh = null;

  try {
    fh = await fsp.open(filePath, 'r');
    let offset = 0;
    let partNumber = 1;
    while (offset < totalSize) {
      const chunkLen = Math.min(partSize, totalSize - offset);
      const partBuf = await readExactSlice(fh, offset, chunkLen);
      const partRes = await signedS3Fetch({
        s3Config,
        method: 'PUT',
        objectKey,
        query: { partNumber: String(partNumber), uploadId },
        headers: { 'Content-Length': String(partBuf.length) },
        body: partBuf,
      });
      if (!partRes.ok) {
        const errText = await partRes.text().catch(() => '');
        const err = new Error(
          `S3 UploadPart ${partNumber} failed (HTTP ${partRes.status})${errText ? `: ${errText.slice(0, 180)}` : ''}`
        );
        err.statusCode = 502;
        throw err;
      }
      const etag = partRes.headers.get('etag') || `"${sha256Hex(partBuf).slice(0, 32)}"`;
      completedParts.push({ partNumber, etag });
      offset += partBuf.length;
      partNumber += 1;
    }

    const completeXml =
      `<CompleteMultipartUpload>` +
      completedParts
        .map((p) => `<Part><PartNumber>${p.partNumber}</PartNumber><ETag>${escapeXml(p.etag)}</ETag></Part>`)
        .join('') +
      `</CompleteMultipartUpload>`;

    const completeRes = await signedS3Fetch({
      s3Config,
      method: 'POST',
      objectKey,
      query: { uploadId },
      headers: {
        'Content-Type': 'application/xml',
        'Content-Length': String(Buffer.byteLength(completeXml, 'utf8')),
      },
      body: Buffer.from(completeXml, 'utf8'),
    });
    if (!completeRes.ok) {
      const errText = await completeRes.text().catch(() => '');
      const err = new Error(
        `S3 CompleteMultipartUpload failed (HTTP ${completeRes.status})${errText ? `: ${errText.slice(0, 180)}` : ''}`
      );
      err.statusCode = 502;
      throw err;
    }
    const completeBody = await completeRes.text().catch(() => '');
    const etagMatch = completeBody.match(/<ETag>([^<]+)<\/ETag>/);
    return {
      objectKey,
      size: totalSize,
      etag: (etagMatch && etagMatch[1]) || completeRes.headers.get('etag') || null,
      multipart: true,
      parts: completedParts.length,
    };
  } catch (err) {
    // Always abort incomplete multipart upload so no orphan chunks accumulate on MEGA S4
    await signedS3Fetch({
      s3Config,
      method: 'DELETE',
      objectKey,
      query: { uploadId },
    }).catch(() => {});
    throw err;
  } finally {
    if (fh) {
      await fh.close().catch(() => {});
    }
  }
}

/**
 * Checks object existence & byte size on MEGA S4 / S3 via HEAD.
 */
async function headS3Object({ s3Config, objectKey }) {
  try {
    const response = await signedS3Fetch({
      s3Config,
      method: 'HEAD',
      objectKey,
    });
    if (response.status === 404) {
      return { exists: false, size: 0, etag: null, contentType: null };
    }
    if (!response.ok) {
      return { exists: false, size: 0, etag: null, contentType: null, status: response.status };
    }
    return {
      exists: true,
      size: Number(response.headers.get('content-length')) || 0,
      etag: response.headers.get('etag') || null,
      contentType: response.headers.get('content-type') || null,
    };
  } catch {
    return { exists: false, size: 0, etag: null, contentType: null };
  }
}

/**
 * Downloads an S3 object to a local temporary file (streaming, zero full-file RAM buffer).
 */
async function downloadS3ObjectToFile({ s3Config, objectKey, destPath }) {
  const getUrl = createPresignedUrl({
    s3Config,
    method: 'GET',
    objectKey,
    expiresIn: 600,
  });
  const response = await fetch(getUrl);
  if (!response.ok || !response.body) {
    const err = new Error(`Failed to fetch S3 object ${objectKey} (HTTP ${response.status})`);
    err.statusCode = response.status === 404 ? 404 : 502;
    throw err;
  }
  await fsp.mkdir(path.dirname(destPath), { recursive: true });
  await new Promise((resolve, reject) => {
    const ws = fs.createWriteStream(destPath, { highWaterMark: 512 * 1024 });
    const rs = Readable.fromWeb(response.body);
    rs.on('error', (err) => {
      ws.destroy();
      reject(err);
    });
    ws.on('error', reject);
    ws.on('finish', resolve);
    rs.pipe(ws);
  });
  return destPath;
}

/**
 * Fetches a bounded S3 object directly into a Buffer (ideal for small proxies/thumbnails).
 */
async function fetchS3ObjectBuffer({ s3Config, objectKey, maxBytes = 25 * 1024 * 1024 }) {
  const getUrl = createPresignedUrl({
    s3Config,
    method: 'GET',
    objectKey,
    expiresIn: 300,
  });
  const response = await fetch(getUrl);
  if (!response.ok) {
    return null;
  }
  const declared = Number(response.headers.get('content-length'));
  if (Number.isFinite(declared) && declared > maxBytes) {
    return null;
  }
  const chunks = [];
  let total = 0;
  if (response.body && typeof response.body.getReader === 'function') {
    const reader = response.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value) {
        total += value.byteLength;
        if (total > maxBytes) {
          await reader.cancel().catch(() => {});
          return null;
        }
        chunks.push(Buffer.from(value));
      }
    }
    return Buffer.concat(chunks, total);
  }
  const buf = Buffer.from(await response.arrayBuffer());
  return buf.length <= maxBytes ? buf : null;
}

/**
 * Streams an S3 / MEGA S4 object directly through Express to the client with full HTTP 206 Range,
 * HEAD, ETag 304, client-disconnect abort, and zero browser CORS issues.
 */
async function streamS3ObjectToResponse({
  req,
  res,
  s3Config,
  objectKey,
  variant = null,
  masterHash = null,
  contentType = null,
  contentDisposition = null,
  cacheControl = 'private, max-age=31536000, immutable',
}) {
  const isHead = req.method === 'HEAD';
  const signedUrl = createPresignedUrl({
    s3Config,
    method: isHead ? 'HEAD' : 'GET',
    objectKey,
    expiresIn: 600,
  });

  const upstreamHeaders = {};
  if (req.headers && req.headers.range) {
    upstreamHeaders.Range = String(req.headers.range);
  }
  if (req.headers && req.headers['if-none-match'] && !req.headers.range) {
    upstreamHeaders['If-None-Match'] = String(req.headers['if-none-match']);
  }

  const abortController = new AbortController();
  const onClientClose = () => {
    if (!res.writableEnded) abortController.abort();
  };
  res.on('close', onClientClose);

  try {
    const upstreamRes = await fetch(signedUrl, {
      method: isHead ? 'HEAD' : 'GET',
      headers: upstreamHeaders,
      signal: abortController.signal,
    });

    if (upstreamRes.status === 404) {
      res.off('close', onClientClose);
      return res.status(404).json({
        success: false,
        error: 'Media object not found in S3 storage',
      });
    }
    if (upstreamRes.status === 304) {
      res.off('close', onClientClose);
      if (cacheControl) res.setHeader('Cache-Control', cacheControl);
      const etag = upstreamRes.headers.get('etag');
      if (etag) res.setHeader('ETag', etag);
      return res.status(304).end();
    }
    if (!upstreamRes.ok && upstreamRes.status !== 206 && upstreamRes.status !== 416) {
      res.off('close', onClientClose);
      return res.status(502).json({
        success: false,
        error: `Object storage returned HTTP ${upstreamRes.status}`,
      });
    }

    if (req.socket && typeof req.socket.setNoDelay === 'function') {
      req.socket.setNoDelay(true);
    }

    res.status(upstreamRes.status);
    res.setHeader('Accept-Ranges', upstreamRes.headers.get('accept-ranges') || 'bytes');
    if (cacheControl) res.setHeader('Cache-Control', cacheControl);
    res.setHeader('Content-Type', contentType || upstreamRes.headers.get('content-type') || 'application/octet-stream');
    for (const h of ['content-length', 'content-range', 'etag', 'last-modified']) {
      const val = upstreamRes.headers.get(h);
      if (val !== null) res.setHeader(h, val);
    }
    if (variant) res.setHeader('X-Photo-Variant', variant);
    if (masterHash) res.setHeader('X-Master-Sha256', masterHash);
    if (contentDisposition) res.setHeader('Content-Disposition', contentDisposition);

    if (isHead || upstreamRes.status === 416 || !upstreamRes.body) {
      res.off('close', onClientClose);
      return res.end();
    }

    return await new Promise((resolve) => {
      const nodeStream = Readable.fromWeb(upstreamRes.body);
      let finished = false;
      const done = () => {
        if (finished) return;
        finished = true;
        res.off('close', onClientClose);
        resolve();
      };
      nodeStream.on('error', () => {
        if (!res.headersSent) {
          res.status(502).end();
        } else if (!res.writableEnded) {
          res.end();
        }
        done();
      });
      res.on('finish', done);
      res.on('close', done);
      nodeStream.pipe(res);
    });
  } catch (err) {
    res.off('close', onClientClose);
    if (abortController.signal.aborted) return undefined;
    if (!res.headersSent) {
      return res.status(502).json({
        success: false,
        error: `Failed to stream object from S3 storage: ${err.message}`,
      });
    }
    return res.end();
  }
}

/**
 * Downloads the object from S3/MEGA S4/MinIO via a pre-signed GET URL and verifies its exact SHA-256 checksum.
 */
async function verifyS3ObjectChecksum({ s3Config, objectKey, expectedSha256 }) {
  const getUrl = createPresignedUrl({
    s3Config,
    method: 'GET',
    objectKey,
    expiresIn: 300,
  });

  const response = await fetch(getUrl);
  if (!response.ok) {
    const err = new Error(
      `Failed to read S3 object for checksum verification (HTTP ${response.status})`
    );
    err.statusCode = response.status === 404 ? 404 : 502;
    throw err;
  }

  const hash = crypto.createHash('sha256');
  let size = 0;

  if (response.body && typeof response.body.getReader === 'function') {
    const reader = response.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value) {
        hash.update(value);
        size += value.byteLength;
      }
    }
  } else {
    const buf = Buffer.from(await response.arrayBuffer());
    hash.update(buf);
    size = buf.length;
  }

  const actualSha256 = hash.digest('hex');
  const cleanExpected = String(expectedSha256 || '').trim().toLowerCase();

  if (cleanExpected && actualSha256 !== cleanExpected) {
    const err = new Error(
      `S3 checksum mismatch: expected ${cleanExpected}, got ${actualSha256}`
    );
    err.statusCode = 422;
    throw err;
  }

  return {
    actualSha256,
    size,
  };
}

/**
 * Deletes an object from MEGA S4/S3/MinIO/R2 using a SigV4 pre-signed DELETE URL.
 * Treats HTTP 404 as already deleted so retries stay idempotent.
 */
async function deleteS3Object({ s3Config, objectKey }) {
  if (!objectKey) return;
  const deleteUrl = createPresignedUrl({
    s3Config,
    method: 'DELETE',
    objectKey,
    expiresIn: 300,
  });

  const response = await fetch(deleteUrl, { method: 'DELETE' });
  if (response.ok || response.status === 404) {
    return;
  }
  const err = new Error(
    `Failed to delete S3 object (HTTP ${response.status})`
  );
  err.statusCode = 502;
  throw err;
}

module.exports = {
  isS3Configured,
  isPrimaryS3Backend,
  buildS3ObjectKey,
  buildS3ProxyKey,
  createPresignedUrl,
  signedS3Fetch,
  putS3Buffer,
  uploadFileToS3,
  headS3Object,
  downloadS3ObjectToFile,
  fetchS3ObjectBuffer,
  streamS3ObjectToResponse,
  verifyS3ObjectChecksum,
  deleteS3Object,
};
