/**
 * S3 / MINIO / R2 OBJECT STORAGE SERVICE (AWS SigV4 Pre-Signed URLs)
 *
 * Where this belongs: `src/services/s3Service.js` (Service Layer).
 * Called by:
 *   - `controllers/uploadController.js` (`presignUpload` creates direct-PUT URL, `confirmUpload` verifies S3 object SHA-256)
 *   - `controllers/photoController.js` (`redirectIfS3` issues a temporary 302 pre-signed GET redirect for fast direct downloads)
 *   - `controllers/healthController.js` & `controllers/accountController.js` (`isS3Configured`)
 * Pure crypto implementation using Node's built-in `crypto` module — zero AWS SDK dependencies needed.
 */

const crypto = require('crypto');

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
  return key
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

/**
 * Generates an AWS Signature Version 4 pre-signed PUT or GET URL for S3 / MinIO / R2.
 */
function createPresignedUrl({
  s3Config,
  method = 'PUT',
  objectKey,
  expiresIn = 900,
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
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${s3Config.accessKeyId}/${credentialScope}`,
    'X-Amz-Date': amzDate,
    'X-Amz-Expires': String(expiresIn),
    'X-Amz-SignedHeaders': 'host',
  };

  const canonicalQueryString = Object.keys(queryParams)
    .sort()
    .map((k) => `${encodeRfc3986(k)}=${encodeRfc3986(queryParams[k])}`)
    .join('&');

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
 * Downloads the object from S3/MinIO via a pre-signed GET URL and verifies its exact SHA-256 checksum.
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

module.exports = {
  isS3Configured,
  createPresignedUrl,
  verifyS3ObjectChecksum,
};
