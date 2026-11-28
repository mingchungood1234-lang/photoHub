/**
 * SERVER-SIDE PROXY TRANSCODING SERVICE (`sharp` + `ffmpeg`)
 *
 * Where this belongs: `src/services/proxyService.js` (Service Layer).
 * Called by:
 *   - `src/controllers/proxyController.js` (`generateProxy` -> compresses images/videos on server under `.proxies/`)
 *   - `src/controllers/photoController.js` (`isVideoFilename` -> checks whether a filename is a video)
 * How fallback works: If neither `sharp` nor `ffmpeg` is installed, throws HTTP `501` with
 * `fallbackToClient: true` so the Android/iOS app automatically compresses locally instead.
 */

const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');

let sharpModule = null;
try {
  // Optional dependency; gracefully falls back if unavailable
  sharpModule = require('sharp');
  if (sharpModule && typeof sharpModule.cache === 'function') {
    // Disable libvips file-descriptor cache so deleted/moved files never trigger EBUSY on Windows
    sharpModule.cache(false);
  }
} catch {
  sharpModule = null;
}

const VIDEO_EXTENSIONS = new Set(['.mov', '.mp4', '.m4v', '.3gp', '.avi']);

let cachedFfmpegAvailable = null;
let cachedNvencAvailable = null;
let ffmpegProbePromise = null;
let nvencProbePromise = null;
let transcodeSettings = {
  hwaccel: 'auto', // 'auto' | 'nvenc' | 'cpu'
  nvencPreset: 'p4',
  ffmpegConcurrency: 0, // 0 = auto (3 on NVENC, 1 on CPU)
};

function createConcurrencyGate(getMaxConcurrent) {
  let active = 0;
  const queue = [];
  const resolveLimit = () =>
    Math.max(1, Number(typeof getMaxConcurrent === 'function' ? getMaxConcurrent() : getMaxConcurrent) || 1);

  return async function runLimited(fn) {
    if (active >= resolveLimit()) {
      await new Promise((resolve) => queue.push(resolve));
    }
    active += 1;
    try {
      return await fn();
    } finally {
      active -= 1;
      const limit = resolveLimit();
      if (active < limit && queue.length > 0) {
        const next = queue.shift();
        if (next) next();
      }
    }
  };
}

function getEffectiveFfmpegConcurrency() {
  if (transcodeSettings.ffmpegConcurrency > 0) {
    return transcodeSettings.ffmpegConcurrency;
  }
  return cachedNvencAvailable === true ? 3 : 1;
}

const sharpGate = createConcurrencyGate(2);
const thumbGate = createConcurrencyGate(4);
const ffmpegGate = createConcurrencyGate(() => getEffectiveFfmpegConcurrency());
const thumbInFlight = new Map(); // cachePath -> Promise<Buffer|null>

function configureProxyService(videoTranscode = {}) {
  if (!videoTranscode || typeof videoTranscode !== 'object') return;
  const prevHwaccel = transcodeSettings.hwaccel;
  if (videoTranscode.hwaccel) {
    transcodeSettings.hwaccel = videoTranscode.hwaccel;
  }
  if (videoTranscode.nvencPreset && /^p[1-7]$/.test(String(videoTranscode.nvencPreset))) {
    transcodeSettings.nvencPreset = String(videoTranscode.nvencPreset);
  }
  if (videoTranscode.ffmpegConcurrency !== undefined) {
    const num = Number(videoTranscode.ffmpegConcurrency);
    transcodeSettings.ffmpegConcurrency = Number.isFinite(num) && num > 0 ? Math.min(8, Math.floor(num)) : 0;
  }
  if (prevHwaccel !== transcodeSettings.hwaccel) {
    cachedNvencAvailable = null;
    nvencProbePromise = null;
  }
}

function isVideoFilename(name = '') {
  return VIDEO_EXTENSIONS.has(path.extname(String(name)).toLowerCase());
}

async function hasFfmpeg() {
  if (cachedFfmpegAvailable !== null) {
    return cachedFfmpegAvailable;
  }
  if (!ffmpegProbePromise) {
    ffmpegProbePromise = new Promise((resolve) => {
      execFile('ffmpeg', ['-version'], { timeout: 3000 }, (err) => {
        cachedFfmpegAvailable = !err;
        ffmpegProbePromise = null;
        resolve(cachedFfmpegAvailable);
      });
    });
  }
  return ffmpegProbePromise;
}

/**
 * Probes real NVIDIA NVENC hardware encoding (`h264_nvenc`) with a tiny 1-frame 256x256 test
 * (above Turing's 145px minimum frame dimension). Automatically returns `false` on CPU-only VPS nodes.
 */
async function hasNvenc() {
  if (transcodeSettings.hwaccel === 'cpu') {
    return false;
  }
  if (cachedNvencAvailable !== null) {
    return cachedNvencAvailable;
  }
  if (!(await hasFfmpeg())) {
    cachedNvencAvailable = false;
    return false;
  }
  if (!nvencProbePromise) {
    nvencProbePromise = new Promise((resolve) => {
      execFile(
        'ffmpeg',
        [
          '-hide_banner',
          '-loglevel', 'error',
          '-f', 'lavfi',
          '-i', 'color=c=black:s=256x256:d=0.1',
          '-frames:v', '1',
          '-pix_fmt', 'yuv420p',
          '-c:v', 'h264_nvenc',
          '-preset', transcodeSettings.nvencPreset || 'p4',
          '-f', 'null',
          '-',
        ],
        { timeout: 8000 },
        (err) => {
          cachedNvencAvailable = !err;
          nvencProbePromise = null;
          resolve(cachedNvencAvailable);
        }
      );
    });
  }
  return nvencProbePromise;
}

async function getCapabilities() {
  const ffmpeg = await hasFfmpeg();
  const nvenc = ffmpeg ? await hasNvenc() : false;
  return {
    sharp: Boolean(sharpModule),
    ffmpeg,
    nvenc,
    videoEncoder: nvenc ? 'h264_nvenc' : ffmpeg ? 'libx264' : null,
    hwaccelMode: transcodeSettings.hwaccel,
    nvencPreset: transcodeSettings.nvencPreset,
    ffmpegConcurrency: getEffectiveFfmpegConcurrency(),
    available: Boolean(sharpModule) || ffmpeg,
  };
}

function buildVideoEncodeArgs({
  sourcePath,
  videoTmp,
  targetHeight = 720,
  qualityNum = 0.72,
  normMaster = '',
  useNvenc = false,
  nvencPreset = 'p4',
}) {
  const cqOrCrf = qualityNum >= 0.78 ? '24' : qualityNum < 0.59 ? '31' : '28';
  const videoScaleFilter = `scale='if(gte(iw,ih),-2,min(${targetHeight},iw))':'if(gte(iw,ih),min(${targetHeight},ih),-2)'`;

  if (useNvenc) {
    return [
      '-y',
      '-i', sourcePath,
      '-c:v', 'h264_nvenc',
      '-preset', nvencPreset || 'p4',
      '-rc', 'vbr',
      '-cq', cqOrCrf,
      '-b:v', '0',
      '-pix_fmt', 'yuv420p',
      '-vf', videoScaleFilter,
      '-c:a', 'aac',
      '-b:a', '96k',
      '-metadata', `description=PhotoHubProxy:${normMaster}`,
      '-metadata', `comment=PhotoHubProxy:${normMaster}`,
      '-movflags', '+faststart',
      videoTmp,
    ];
  }

  return [
    '-y',
    '-i', sourcePath,
    '-c:v', 'libx264',
    '-preset', 'veryfast',
    '-crf', cqOrCrf,
    '-pix_fmt', 'yuv420p',
    '-vf', videoScaleFilter,
    '-c:a', 'aac',
    '-b:a', '96k',
    '-metadata', `description=PhotoHubProxy:${normMaster}`,
    '-metadata', `comment=PhotoHubProxy:${normMaster}`,
    '-movflags', '+faststart',
    videoTmp,
  ];
}

function runFfmpeg(args, timeoutMs = 120000) {
  return ffmpegGate(
    () =>
      new Promise((resolve, reject) => {
        execFile('ffmpeg', args, { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 }, (err, _stdout, stderr) => {
          if (err) {
            const msg = stderr ? String(stderr).slice(-300) : err.message;
            const wrapped = new Error(`ffmpeg failed: ${msg}`);
            wrapped.cause = err;
            reject(wrapped);
            return;
          }
          resolve();
        });
      })
  );
}

async function computeFileSha256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

function makeFallbackError(message) {
  const err = new Error(message);
  err.statusCode = 501;
  err.fallbackToClient = true;
  return err;
}

async function generateImageProxyWithSharp(sourcePath, maxPixelSize, qualityPercent) {
  if (!sharpModule) {
    throw makeFallbackError('sharp is not available on this server');
  }
  const metadata = await sharpModule(sourcePath).metadata();
  const longest = Math.max(metadata.width || 0, metadata.height || 0);
  let targetMax = maxPixelSize > 0 ? maxPixelSize : 1440;
  if (maxPixelSize <= 0) {
    if (longest > 4096) targetMax = 1920;
    else if (longest > 2048) targetMax = 1440;
    else if (longest > 1280) targetMax = 1024;
    else if (longest > 0) targetMax = Math.max(640, Math.round(longest * 0.75));
  } else if (longest > 0) {
    targetMax = Math.min(longest, maxPixelSize);
  }

  return sharpGate(() =>
    sharpModule(sourcePath)
      .rotate()
      .resize({
        width: targetMax,
        height: targetMax,
        fit: 'inside',
        withoutEnlargement: true,
      })
      .jpeg({
        quality: qualityPercent,
        mozjpeg: true,
      })
      .toBuffer()
  );
}

async function generateServerSideProxy({
  sourcePath,
  proxiesDir,
  masterHash,
  originalName,
  maxPixelSize = 0,
  quality = 0.72,
}) {
  const normMaster = String(masterHash || '').trim().toLowerCase();
  const qualityNum = Math.min(0.95, Math.max(0.3, Number(quality) || 0.72));
  const qualityPercent = Math.round(qualityNum * 100);
  const maxPx = Math.max(0, Number(maxPixelSize) || 0);

  await fsp.mkdir(proxiesDir, { recursive: true });

  if (isVideoFilename(originalName || sourcePath)) {
    if (!(await hasFfmpeg())) {
      throw makeFallbackError('ffmpeg is not installed on server to proxy videos');
    }

    const posterName = `${normMaster}.jpg`;
    const posterPath = path.join(proxiesDir, posterName);
    const posterTmp = `${posterPath}.tmp.jpg`;

    const videoName = `${normMaster}.mp4`;
    const videoPath = path.join(proxiesDir, videoName);
    const videoTmp = `${videoPath}.tmp.mp4`;

    try {
      // Extract a compressed 800px poster frame quickly
      try {
        await runFfmpeg([
          '-y',
          '-ss', '00:00:00.5',
          '-i', sourcePath,
          '-frames:v', '1',
          '-vf', "scale='min(800,iw)':-2",
          '-q:v', '4',
          posterTmp,
        ], 30000);
      } catch {
        // Retry at t=0 for ultra-short clips (< 0.5s)
        await runFfmpeg([
          '-y',
          '-i', sourcePath,
          '-frames:v', '1',
          '-vf', "scale='min(800,iw)':-2",
          '-q:v', '4',
          posterTmp,
        ], 30000).catch(() => {});
      }

      // Encode lightweight compressed H.264 + AAC proxy MP4 honoring user's resolution/detail preference.
      // Uses NVIDIA NVENC (`h264_nvenc`) on GPU storage nodes with automatic per-file CPU `libx264` fallback.
      const targetHeight =
        maxPx >= 2400 ? 1440 :
        maxPx >= 1800 ? 1080 :
        maxPx >= 1100 ? 720 :
        maxPx > 0 ? 480 :
        qualityNum < 0.59 ? 540 : 720;

      const useNvenc = await hasNvenc();
      if (useNvenc) {
        try {
          await runFfmpeg(
            buildVideoEncodeArgs({
              sourcePath,
              videoTmp,
              targetHeight,
              qualityNum,
              normMaster,
              useNvenc: true,
              nvencPreset: transcodeSettings.nvencPreset,
            }),
            180000
          );
        } catch (nvencErr) {
          console.warn(
            `[proxy] NVENC encode failed for ${path.basename(originalName || sourcePath)}, falling back to CPU libx264:`,
            nvencErr && nvencErr.message ? nvencErr.message.slice(0, 180) : nvencErr
          );
          await fsp.unlink(videoTmp).catch(() => {});
          await runFfmpeg(
            buildVideoEncodeArgs({
              sourcePath,
              videoTmp,
              targetHeight,
              qualityNum,
              normMaster,
              useNvenc: false,
            }),
            180000
          );
        }
      } else {
        await runFfmpeg(
          buildVideoEncodeArgs({
            sourcePath,
            videoTmp,
            targetHeight,
            qualityNum,
            normMaster,
            useNvenc: false,
          }),
          180000
        );
      }

      let proxyRelativePath = null;
      let proxySize = null;
      if (fs.existsSync(posterTmp)) {
        const posterStat = await fsp.stat(posterTmp);
        if (posterStat.size > 0) {
          await fsp.rename(posterTmp, posterPath);
          proxyRelativePath = `.proxies/${posterName}`;
          proxySize = posterStat.size;
        }
      }

      const videoStat = await fsp.stat(videoTmp);
      if (!videoStat.size) {
        throw makeFallbackError('ffmpeg generated an empty video proxy');
      }
      await fsp.rename(videoTmp, videoPath);
      const proxyHash = await computeFileSha256(videoPath);

      return {
        proxyHash,
        proxyRelativePath,
        proxySize,
        videoProxyRelativePath: `.proxies/${videoName}`,
        videoProxySize: videoStat.size,
      };
    } catch (err) {
      await fsp.unlink(posterTmp).catch(() => {});
      await fsp.unlink(videoTmp).catch(() => {});
      if (err.fallbackToClient) throw err;
      throw makeFallbackError(err.message);
    }
  }

  // Image proxy: try sharp first (fast libvips), then fallback to ffmpeg if sharp cannot decode container
  const imgName = `${normMaster}.jpg`;
  const imgPath = path.join(proxiesDir, imgName);
  const imgTmp = `${imgPath}.tmp.jpg`;

  let imgBuf = null;
  try {
    imgBuf = await generateImageProxyWithSharp(sourcePath, maxPx, qualityPercent);
  } catch (sharpErr) {
    if (await hasFfmpeg()) {
      const targetW = maxPx > 0 ? maxPx : 1440;
      try {
        await runFfmpeg([
          '-y',
          '-i', sourcePath,
          '-frames:v', '1',
          '-vf', `scale='min(${targetW},iw)':-2`,
          '-q:v', '3',
          imgTmp,
        ], 30000);
        imgBuf = await fsp.readFile(imgTmp);
      } catch (ffErr) {
        await fsp.unlink(imgTmp).catch(() => {});
        throw makeFallbackError(ffErr.message || sharpErr.message);
      }
    } else {
      throw makeFallbackError(sharpErr.message);
    }
  }

  if (!imgBuf || imgBuf.length === 0) {
    throw makeFallbackError('Server could not generate compressed image buffer');
  }

  await fsp.writeFile(imgTmp, imgBuf);
  await fsp.rename(imgTmp, imgPath);
  const proxyHash = crypto.createHash('sha256').update(imgBuf).digest('hex');

  return {
    proxyHash,
    proxyRelativePath: `.proxies/${imgName}`,
    proxySize: imgBuf.length,
  };
}

/**
 * Generates and atomically caches a tiny 360px grid thumbnail (WebP or JPEG, ~10-25 KB)
 * for blazing-fast webpage gallery browsing. Deduplicates concurrent requests per output path
 * and runs on a dedicated fast concurrency gate so heavy video/proxy jobs never block scrolling.
 */
async function generateGridThumbnail({
  sourcePath = null,
  sourceBuffer = null,
  thumbsDir,
  masterHash,
  width = 360,
  format = 'webp',
}) {
  const input =
    Buffer.isBuffer(sourceBuffer) && sourceBuffer.length > 0 ? sourceBuffer : sourcePath;
  if (!sharpModule || !input || !thumbsDir || !masterHash) return null;

  const normHash = String(masterHash).trim().toLowerCase().replace(/[^a-f0-9]/g, '');
  if (!normHash) return null;
  const targetPx = Math.min(720, Math.max(120, Math.round(Number(width) || 360)));
  const useWebp = format === 'webp';
  const ext = useWebp ? 'webp' : 'jpg';
  const suffix = targetPx === 360 ? '' : `_${targetPx}`;
  const outPath = path.join(thumbsDir, `${normHash}${suffix}.${ext}`);

  if (thumbInFlight.has(outPath)) {
    return thumbInFlight.get(outPath);
  }

  const task = (async () => {
    try {
      await fsp.mkdir(thumbsDir, { recursive: true });
      const buf = await thumbGate(() => {
        const pipeline = sharpModule(input)
          .rotate()
          .resize({
            width: targetPx,
            height: targetPx,
            fit: 'inside',
            withoutEnlargement: true,
          });
        return useWebp
          ? pipeline.webp({ quality: 74, effort: 3 }).toBuffer()
          : pipeline.jpeg({ quality: 76, mozjpeg: true }).toBuffer();
      });

      if (!buf || buf.length === 0) return null;
      const tmpPath = `${outPath}.${process.pid}.${Date.now()}.tmp`;
      try {
        await fsp.writeFile(tmpPath, buf);
        await fsp.rename(tmpPath, outPath);
      } catch {
        await fsp.unlink(tmpPath).catch(() => {});
      }
      return { buffer: buf, outPath, contentType: useWebp ? 'image/webp' : 'image/jpeg' };
    } catch {
      return null;
    } finally {
      thumbInFlight.delete(outPath);
    }
  })();

  thumbInFlight.set(outPath, task);
  return task;
}

module.exports = {
  isVideoFilename,
  configureProxyService,
  hasFfmpeg,
  hasNvenc,
  getCapabilities,
  buildVideoEncodeArgs,
  generateServerSideProxy,
  generateGridThumbnail,
};
